variable "arch_layer_name" {
  default = "spoke_t2"
  type    = string
}

variable "resource_group_prefix" {
  default = "rg_"
  type    = string
}

variable "vnet_prefix" {
  default = "vnet_"
  type    = string
}

variable "snet_prefix" {
  default = "snet_"
  type    = string
}

variable "pip_prefix" {
  default = "pip_"
  type    = string
}

variable "nsg_prefix" {
  default = "nsg_"
  type    = string
}

variable "nic_prefix" {
  default = "nic_"
  type    = string
}

variable "vm_prefix" {
  default = "v"
  type    = string
}

variable "admin_username" {
  default = "s4admin"
  type    = string
}

variable "location" {
  default = "polandcentral"
  type    = string
}

variable "ehns_prefix" {
  default = "ehns-"
  type    = string
}

variable "eh_prefix" {
  default = "eh-"
  type    = string
}

variable "ehs_prefix" {
  default = "ehstor"
  type    = string
}

variable "law_prefix" {
  default = "law-"
  type    = string
}

variable "dcre_prefix" {
  default = "dcre-"
  type    = string
}

variable "dcr_prefix" {
  default = "dcr-"
  type    = string
}

variable "sc_prefix" {
  default = "sc-"
  type    = string
}

variable "sa_prefix" {
  default = "sa"
  type    = string
}

variable "rtt_prefix" {
  default = "rtt_"
  type    = string
}

variable "peering_prefix" {
  default = "peer_"
  type    = string
}

variable "tags" {
  type = map(any)
  default = {
    environment = "dev"
  }
}

variable "part_project" {
  type        = string
  description = "XXX - Project part of the name"
  default     = "wrn"
}

variable "part_hosting_segment" {
  type        = string
  description = "HHH - Segment part of the name"
  default     = "az1"
}

variable "part_tier" {
  description = "TT - Spoke part of the name"
  default     = "t4"
  type        = string
  # dm - dmz - public services
  # hb - hub - firewall/gateway/routing hub
  # t0 - spoke tier 0 - core identity services
  # t1 - spoke tier 1 - internal services
  # t2 - spoke tier 2 - productivity and business services
  # t3 - spoke tier 3 - auxiliary internal services
  # t4 - spoke tier 4 - isolated services / dmz
}

variable "part_service" {
  description = "S - Service part of the name"
  default     = "s"
  type        = string
  # a - application
  # b - database + application
  # c - containter service
  # d - database
  # f - firewall
  # g - gpu accelerated
  # h - hypervisor
  # i - infra
  # n - network
  # s - storage
  # t - backup
  # w - web
}

variable "part_appid" {
  description = "AAA - Application part of the name"
  default     = "tst"
  type        = string
  # 3 letters identifying application as per enterprise database
}

variable "part_number" {
  description = "NN - Number part of the name"
  default     = "99"
  type        = string
  # 2 digits
}

variable "part_env" {
  description = "E - Environment part of the name"
  type        = string
  # d - dev
  # t - test
  # p - prod
  # c - cob
}

variable "subscription_id" {
  description = "The Azure Subscription ID"
  type        = string
}

variable "tenant_id" {
  description = "The Azure Tenant ID"
  type        = string
}

variable "vm_sku" {
  default = "Standard_D2s_v6"
  type    = string
}

variable "ssh_public_key" {
  type = string
}

variable "part_custom_name" {
  description = "Custom part of the name, provided by requestor"
  default     = "test1"
  type        = string
}

variable "primary_nic_ip_offset" {
  description = "Offset for the primary NIC IP address within the subnet CIDR range"
  default     = 11
  type        = number
}

variable "data_disk_size_gb" {
  description = "Size of the additional data disk in GB"
  default     = 64
  type        = number
}

variable "allocated_subnet_name" {
  description = "Name of the allocated subnet within the spoke virtual network"
  default     = "snet_spoke_demo_vms1"
  type        = string
}

variable "vm_expiry_time_in_days" {
  description = "Number of days until vm expires"
  type        = number
}
