data "azurerm_resource_group" "spoke_demo_vms_rg" {
  name = "rg_spoke_demo_vms"
}

data "azurerm_subnet" "spoke_demo_vms_snet" {
  name                 = var.allocated_subnet_name
  virtual_network_name = "vnet_spoke_demo_vms"
  resource_group_name  = data.azurerm_resource_group.spoke_demo_vms_rg.name
}

locals {
  hostname = "${var.vm_prefix}${var.part_project}${var.part_hosting_segment}${var.part_tier}${var.part_custom_name}${var.part_number}${var.part_env}"
  expiry_date = (
    try(length(var.vm_expiry_time_in_days), 0) > 0 ?
    formatdate("YYYY-MM-DD", timeadd(timestamp(), "${tostring(var.vm_expiry_time_in_days * 24)}h")) :
    "9999-12-31"
  )
}

resource "random_id" "diag" {
  byte_length = 4
  keepers = {
    resource_group = azurerm_resource_group.svc_rg.name
  }
}

resource "random_password" "admin" {
  length           = 20
  special          = true
  override_special = "!#%-_=+[]{}<>:?"
}

resource "azurerm_storage_account" "svc_storage_account_diag" {
  name                            = "${var.sa_prefix}diag${random_id.diag.hex}"
  location                        = azurerm_resource_group.svc_rg.location
  resource_group_name             = azurerm_resource_group.svc_rg.name
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  tags                            = merge(var.tags, { "expiry_date" = local.expiry_date })
  public_network_access_enabled   = true
  default_to_oauth_authentication = true
}

resource "azurerm_resource_group" "svc_rg" {
  name     = "${var.resource_group_prefix}${var.arch_layer_name}_${local.hostname}"
  location = var.location
}

### VM ###
resource "azurerm_network_interface" "svc_nic" {
  name                  = "${var.nic_prefix}${var.arch_layer_name}_${local.hostname}"
  location              = azurerm_resource_group.svc_rg.location
  resource_group_name   = azurerm_resource_group.svc_rg.name
  tags                  = merge(var.tags, { "expiry_date" = local.expiry_date })
  ip_forwarding_enabled = false

  ip_configuration {
    name                          = "svc_nic_ip"
    subnet_id                     = data.azurerm_subnet.spoke_demo_vms_snet.id
    private_ip_address_allocation = "Static"
    private_ip_address            = cidrhost(data.azurerm_subnet.spoke_demo_vms_snet.address_prefixes[0], var.primary_nic_ip_offset)
  }
}

resource "azurerm_linux_virtual_machine" "svc_vm" {
  name                            = local.hostname
  resource_group_name             = azurerm_resource_group.svc_rg.name
  location                        = azurerm_resource_group.svc_rg.location
  size                            = var.vm_sku
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids = [
    azurerm_network_interface.svc_nic.id,
  ]

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    name                 = "${local.hostname}_disk0"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 32
  }

  source_image_reference {
    publisher = "debian"
    offer     = "debian-13"
    sku       = "13-gen2"
    version   = "latest"
  }

  boot_diagnostics {
    storage_account_uri = azurerm_storage_account.svc_storage_account_diag.primary_blob_endpoint
  }

  lifecycle {
    ignore_changes = [
      identity["identity_ids"],
      identity["principal_id"],
      identity["tenant_id"],
      identity["type"],
    ]
  }

  tags = merge(var.tags, { "expiry_date" = local.expiry_date })
}

resource "azurerm_managed_disk" "svc_vm" {
  name                 = "${local.hostname}_disk1"
  location             = azurerm_resource_group.svc_rg.location
  resource_group_name  = azurerm_resource_group.svc_rg.name
  storage_account_type = "StandardSSD_LRS"
  create_option        = "Empty"
  disk_size_gb         = var.data_disk_size_gb

  tags = merge(var.tags, { "expiry_date" = local.expiry_date })

  # lifecycle {
  #   prevent_destroy = true
  # }
}

resource "azurerm_virtual_machine_data_disk_attachment" "svc_vm" {
  managed_disk_id    = azurerm_managed_disk.svc_vm.id
  virtual_machine_id = azurerm_linux_virtual_machine.svc_vm.id
  lun                = 10
  caching            = "ReadWrite"
}
