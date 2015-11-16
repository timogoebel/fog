module Fog
  module Compute
    class Vsphere
      class Real
        def create_vm attributes = { }
          # build up vm configuration

          vm_cfg        = {
            :name         => attributes[:name],
            :guestId      => attributes[:guest_id],
            :version      => attributes[:hardware_version],
            :files        => { :vmPathName => vm_path_name(attributes) },
            :numCPUs      => attributes[:cpus],
            :numCoresPerSocket => attributes[:corespersocket],
            :memoryMB     => attributes[:memory_mb],
            :deviceChange => device_change(attributes),
            :extraConfig  => extra_config(attributes),
          }
          vm_cfg[:cpuHotAddEnabled] = attributes[:cpuHotAddEnabled] if attributes.key?(:cpuHotAddEnabled)
          vm_cfg[:memoryHotAddEnabled] = attributes[:memoryHotAddEnabled] if attributes.key?(:memoryHotAddEnabled)
          vm_cfg[:firmware] = attributes[:firmware] if attributes.key?(:firmware)
          resource_pool = if attributes[:resource_pool]
                            get_raw_resource_pool(attributes[:resource_pool], attributes[:cluster], attributes[:datacenter])
                          else
                            get_raw_cluster(attributes[:cluster], attributes[:datacenter]).resourcePool
                          end
          vmFolder      = get_raw_vmfolder(attributes[:path], attributes[:datacenter])
          # if any volume has a storage_pod set, we deploy the vm on a storage pod instead of the defined datastores
          if pool = get_storage_pod(attributes)
            vm = create_vm_on_storage_pod(pool, vm_cfg, vmFolder, resource_pool, attributes[:datacenter])
          else
            vm = create_vm_on_datastore(vm_cfg, vmFolder, resource_pool)
          end
          vm.config.instanceUuid
        rescue => e
          raise e, "failed to create vm: #{e}"
        end

        private

        def create_vm_on_datastore(vm_cfg, vmFolder, resource_pool)
          vm = vmFolder.CreateVM_Task(:config => vm_cfg, :pool => resource_pool).wait_for_completion
        end

        def create_vm_on_storage_pod(storage_pod, vm_cfg, vmFolder, resource_pool, datacenter)
          pod_spec     = RbVmomi::VIM::StorageDrsPodSelectionSpec.new(
            :storagePod => get_raw_storage_pod(storage_pod, datacenter),
          )
          storage_spec = RbVmomi::VIM::StoragePlacementSpec.new(
            :type => 'create',
            :folder => vmFolder,
            :resourcePool => resource_pool,
            :podSelectionSpec => pod_spec,
            :configSpec => vm_cfg,
          )
          srm = @connection.serviceContent.storageResourceManager
          result = srm.RecommendDatastores(:storageSpec => storage_spec)

          # if result array contains recommendation, we can apply it
          if key = result.recommendations.first.key
            result = srm.ApplyStorageDrsRecommendation_Task(:key => [key]).wait_for_completion
            vm = result.vm
          else
            raise "Could not create vm on storage pool, did not get a storage recommendation"
          end
          vm
        end

        # check if a storage pool is set on any of the volumes and return the first result found or nil
        # return early if vsphere revision is lower than 5 as this is not supported
        def get_storage_pod attributes
          return unless @vsphere_rev.to_f >= 5
          volume = attributes[:volumes].detect {|volume| volume.storage_pod}
          volume.storage_pod if volume
        end

        # this methods defines where the vm config files would be located,
        # by default we prefer to keep it at the same place the (first) vmdk is located
        # if we deploy the vm on a storage pool, we have to set an empty string
        def vm_path_name attributes
          return '' if get_storage_pod(attributes)
          datastore = attributes[:volumes].first.datastore unless attributes[:volumes].empty?
          datastore ||= 'datastore1'
          "[#{datastore}]"
        end

        def device_change attributes
          devices = []
          if (nics = attributes[:interfaces])
            devices << nics.map { |nic| create_interface(nic, nics.index(nic), :add, attributes) }
          end

          if (disks = attributes[:volumes])
            devices << create_controller(attributes[:scsi_controller]||attributes["scsi_controller"]||{})
            devices << disks.map { |disk| create_disk(disk, disks.index(disk), :add, 1000, get_storage_pod(attributes)) }
          end
          devices.flatten
        end

        def create_nic_backing nic, attributes
          raw_network = get_raw_network(nic.network, attributes[:datacenter], if nic.virtualswitch then nic.virtualswitch end)

          if raw_network.kind_of? RbVmomi::VIM::DistributedVirtualPortgroup
            RbVmomi::VIM.VirtualEthernetCardDistributedVirtualPortBackingInfo(
              :port => RbVmomi::VIM.DistributedVirtualSwitchPortConnection(
                :portgroupKey => raw_network.key,
                :switchUuid   => raw_network.config.distributedVirtualSwitch.uuid
              )
            )
          else
            RbVmomi::VIM.VirtualEthernetCardNetworkBackingInfo(:deviceName => nic.network)
          end
        end

        def create_interface nic, index = 0, operation = :add, attributes = {}
          {
            :operation => operation,
            :device    => nic.type.new(
              :key         => index,
              :deviceInfo  =>
                {
                  :label   => nic.name,
                  :summary => nic.summary,
                },
              :backing     => create_nic_backing(nic, attributes),
              :addressType => 'generated')
          }
        end

        def create_controller options=nil
          options=if options
                    controller_default_options.merge(Hash[options.map{|k,v| [k.to_sym,v] }])
                  else
                    controller_default_options
                  end
          controller_class=if options[:type].is_a? String then
                             Fog::Vsphere.class_from_string options[:type], "RbVmomi::VIM"
                           else
                             options[:type]
                           end
          {
            :operation => options[:operation],
            :device    => controller_class.new({
              :key       => options[:key],
              :busNumber => options[:bus_id],
              :sharedBus => controller_get_shared_from_options(options),
            })
          }
        end

        def controller_default_options
          {:operation => "add", :type => RbVmomi::VIM.VirtualLsiLogicController.class, :key => 1000, :bus_id => 0, :shared => false }
        end

        def controller_get_shared_from_options options
          if (options.key? :shared and options[:shared]==false) or not options.key? :shared then
            :noSharing
          elsif options[:shared]==true then
            :virtualSharing
          elsif options[:shared].is_a? String
            options[:shared]
          else
            :noSharing
          end
        end

        def create_disk disk, index = 0, operation = :add, controller_key = 1000, storage_pod_selected = nil
          if (index > 6) then
            _index = index + 1
          else
            _index = index
          end
          # If we deploy the vm on a storage pool, datastore has to be an empty string
          datastore = ''
          datastore = "[#{disk.datastore}]" unless storage_pod_selected
          payload = {
            :operation     => operation,
            :fileOperation => operation == :add ? :create : :destroy,
            :device        => RbVmomi::VIM.VirtualDisk(
              :key           => disk.key || _index,
              :backing       => RbVmomi::VIM.VirtualDiskFlatVer2BackingInfo(
                :fileName        => datastore,
                :diskMode        => disk.mode.to_sym,
                :thinProvisioned => disk.thin
              ),
              :controllerKey => controller_key,
              :unitNumber    => _index,
              :capacityInKB  => disk.size
            )
          }

          if operation == :add && disk.thin == 'false' && disk.eager_zero == 'true'
            payload[:device][:backing][:eagerlyScrub] = disk.eager_zero
          end

          payload
        end

        def extra_config attributes
          [
            {
              :key   => 'bios.bootOrder',
              :value => 'ethernet0'
            }
          ]
        end
      end

      class Mock
        def create_vm attributes = { }
        end
      end
    end
  end
end
