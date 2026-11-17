variable "environment_name" {
  description = "AZD environment name; also used in the resource group name."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9-]{0,40}$", var.environment_name))
    error_message = "Use 1-41 letters, digits, or hyphens, beginning with a letter or digit."
  }
}

variable "subscription_id" {
  description = "Azure subscription for this isolated lab."
  type        = string
}

variable "location" {
  description = "Azure region for the lab."
  type        = string
}

variable "owner" {
  description = "Owner tag for the lab."
  type        = string

  validation {
    condition     = length(trimspace(var.owner)) > 0
    error_message = "An owner is required."
  }
}

variable "expires_on" {
  description = "Review or cleanup date for the lab, in YYYY-MM-DD format; no automatic deletion is configured."
  type        = string

  validation {
    condition     = can(regex("^\\d{4}-\\d{2}-\\d{2}$", var.expires_on))
    error_message = "Use YYYY-MM-DD for the expiry date."
  }
}

variable "ssh_public_key" {
  description = "RSA SSH public key for the private Linux test VMs."
  type        = string

  validation {
    condition     = startswith(trimspace(var.ssh_public_key), "ssh-rsa ")
    error_message = "Provide an RSA SSH public key beginning with ssh-rsa."
  }
}

variable "vpn_psk" {
  description = "Pre-shared key used by both sides of the simulated OCI IPsec VPN."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.vpn_psk) >= 32 && length(var.vpn_psk) <= 128
    error_message = "The VPN pre-shared key must contain 32-128 characters."
  }
}

variable "enable_b_route_map" {
  description = "Apply the outbound OCI drop map to VNet B; disable only to collect a protected baseline."
  type        = bool
  default     = true
}

variable "hub_a_prefix" {
  description = "Hub A address prefix."
  type        = string
  default     = "10.100.0.0/23"
}

variable "hub_b_prefix" {
  description = "Hub B address prefix."
  type        = string
  default     = "10.100.2.0/23"
}

variable "vnet_a_prefix" {
  description = "Approved VNet A address prefix."
  type        = string
  default     = "10.110.0.0/24"
}

variable "vnet_b_prefix" {
  description = "Restricted VNet B address prefix."
  type        = string
  default     = "10.130.0.0/24"
}

variable "simulator_prefix" {
  description = "Azure VNet address prefix simulating the OCI network."
  type        = string
  default     = "10.29.0.0/22"
}

variable "simulator_workload_prefix" {
  description = "Workload subnet within the simulated OCI VNet."
  type        = string
  default     = "10.29.0.0/24"
}

variable "simulator_gateway_prefix" {
  description = "GatewaySubnet within the simulated OCI VNet."
  type        = string
  default     = "10.29.3.0/26"
}

variable "vm_size" {
  description = "Size of each private test VM."
  type        = string
  default     = "Standard_D2as_v7"
}
