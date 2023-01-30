data "vsphere_datacenter" "dc" {
  name = var.dc
}

data "vsphere_datastore_cluster" "datastore_cluster" {
  count         = var.datastore_cluster != "" ? 1 : 0
  name          = var.datastore_cluster
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_datastore" "datastore" {
  count         = var.datastore != "" && var.datastore_cluster == "" ? 1 : 0
  name          = var.datastore
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_datastore" "disk_datastore" {
  count         = var.disk_datastore != "" ? 1 : 0
  name          = var.disk_datastore
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_resource_pool" "pool" {
  name          = var.vmrp
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_network" "network" {
  count         = length(var.network)
  name          = keys(var.network)[count.index]
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_virtual_machine" "template" {
  name          = var.vmtemp
  datacenter_id = data.vsphere_datacenter.dc.id
}

locals {
  interface_count     = length(var.ipv4submask) #Used for Subnet handeling
  template_disk_count = length(data.vsphere_virtual_machine.template.disks)
}

// Cloning a Linux VM from a given template. Note: This is the default option!!
resource "vsphere_virtual_machine" "Linux" {
  depends_on = [var.vm_depends_on]
  name       = var.vmname

  resource_pool_id        = data.vsphere_resource_pool.pool.id
  folder                  = var.vmfolder
  tags                    = var.tag_ids
  custom_attributes       = var.custom_attributes
  annotation              = var.annotation
  extra_config            = var.extra_config
  firmware                = var.firmware
  efi_secure_boot_enabled = var.efi_secure_boot
  enable_disk_uuid        = var.enable_disk_uuid
  storage_policy_id       = var.storage_policy_id

  datastore_cluster_id = var.datastore_cluster != "" ? data.vsphere_datastore_cluster.datastore_cluster[0].id : null
  datastore_id         = var.datastore != "" ? data.vsphere_datastore.datastore[0].id : null

  num_cpus               = var.cpu_number
  num_cores_per_socket   = var.num_cores_per_socket
  cpu_hot_add_enabled    = var.cpu_hot_add_enabled
  cpu_hot_remove_enabled = var.cpu_hot_remove_enabled
  cpu_reservation        = var.cpu_reservation
  memory_reservation     = var.memory_reservation
  memory                 = var.ram_size
  memory_hot_add_enabled = var.memory_hot_add_enabled
  guest_id               = data.vsphere_virtual_machine.template.guest_id
  scsi_bus_sharing       = var.scsi_bus_sharing
  scsi_type              = var.scsi_type != "" ? var.scsi_type : data.vsphere_virtual_machine.template.scsi_type
  scsi_controller_count = max(max(0, flatten([
    for item in values(var.data_disk) : [
      for elem, val in item :
      "${elem}" == "data_disk_scsi_controller" ? val : 0
    ]
  ])...) + 1, var.scsi_controller)
  wait_for_guest_net_routable = var.wait_for_guest_net_routable
  wait_for_guest_ip_timeout   = var.wait_for_guest_ip_timeout
  wait_for_guest_net_timeout  = var.wait_for_guest_net_timeout

  ignored_guest_ips = var.ignored_guest_ips

  dynamic "network_interface" {
    for_each = keys(var.network) #data.vsphere_network.network[*].id #other option
    content {
      network_id   = data.vsphere_network.network[network_interface.key].id
      adapter_type = var.network_type != null ? var.network_type : data.vsphere_virtual_machine.template.network_interface_types[0]
    }
  }
  // Disks defined in the original template
  dynamic "disk" {
    for_each = data.vsphere_virtual_machine.template.disks
    iterator = template_disks
    content {
      label            = length(var.disk_label) > 0 ? var.disk_label[template_disks.key] : "disk${template_disks.key}"
      size             = var.disk_size_gb != null ? var.disk_size_gb[template_disks.key] : data.vsphere_virtual_machine.template.disks[template_disks.key].size
      #unit_number      = var.scsi_controller != null ? var.scsi_controller * 15 + template_disks.key : template_disks.key
      thin_provisioned = data.vsphere_virtual_machine.template.disks[template_disks.key].thin_provisioned
      #eagerly_scrub    = data.vsphere_virtual_machine.template.disks[template_disks.key].eagerly_scrub
      datastore_id     = var.disk_datastore != "" ? data.vsphere_datastore.disk_datastore[0].id : null
    }
  }
  // Additional disks defined by Terraform config
  dynamic "disk" {
    for_each = var.data_disk
    iterator = terraform_disks
    content {
      label            = terraform_disks.key
      size             = lookup(terraform_disks.value, "size_gb", null)
      unit_number      = lookup(terraform_disks.value, "data_disk_scsi_controller", 0) ? terraform_disks.value.data_disk_scsi_controller * 15 + index(keys(var.data_disk), terraform_disks.key) + (var.scsi_controller == tonumber(terraform_disks.value["data_disk_scsi_controller"]) ? local.template_disk_count : 0) : index(keys(var.data_disk), terraform_disks.key) + local.template_disk_count
      thin_provisioned = lookup(terraform_disks.value, "thin_provisioned", "true")
      eagerly_scrub    = lookup(terraform_disks.value, "eagerly_scrub", "false")
      datastore_id     = lookup(terraform_disks.value, "datastore_id", null)
    }
  }
  clone {
    template_uuid = data.vsphere_virtual_machine.template.id
    linked_clone  = var.linked_clone
    timeout       = var.timeout

//    customize {
//      timeout = 1
//      linux_options {
//        host_name    = var.vmname
//        domain       = var.vmdomain
////        hw_clock_utc = var.hw_clock_utc
//      }
//      # hardware VMWare OS customization exp
//      # TODO: fig this mess out
//      network_interface {}
////      dynamic "network_interface" {
////        for_each = keys(var.network)
////        content {
////          ipv4_address = lookup(var.network, network_interface.key, "")
////          ipv4_netmask = "%{if length(var.ipv4submask) == 1}${var.ipv4submask[0]}%{else}${var.ipv4submask[network_interface.key]}%{endif}"
////        }
////      }
////      dns_server_list = var.vmdns
////      dns_suffix_list = var.dns_suffix_list
////      ipv4_gateway    = var.vmgateway
//    }
  }

  // Advanced options
  hv_mode                          = var.hv_mode
  ept_rvi_mode                     = var.ept_rvi_mode
  nested_hv_enabled                = var.nested_hv_enabled
  enable_logging                   = var.enable_logging
  cpu_performance_counters_enabled = var.cpu_performance_counters_enabled
  swap_placement_policy            = var.swap_placement_policy
  latency_sensitivity              = var.latency_sensitivity

  shutdown_wait_timeout = var.shutdown_wait_timeout
  force_power_off       = var.force_power_off

  provisioner "remote-exec" {
    //Some dummy install to delay execution of local-exec
    inline = [var.remote_exec_command]

    connection {
      type = "ssh"
      host = self.default_ip_address
      user = var.remote_exec_user
      private_key = file(var.remote_exec_ssh_key_file)
      timeout = var.remote_exec_timeout
    }
  }

  provisioner "local-exec" {
    command = "ansible-playbook -u ${var.local_exec_user} -i '${self.default_ip_address},' --private-key ${var.local_exec_ssh_key_file} ${var.path_to_ansible} ${var.ansible_args} "
  }

}
