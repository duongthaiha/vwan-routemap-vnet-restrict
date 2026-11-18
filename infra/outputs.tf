output "AZURE_RESOURCE_GROUP" {
  description = "Resource group containing the PoC."
  value       = azurerm_resource_group.poc.name
}

output "VM_PRIVATE_IPS" {
  description = "Private IP addresses for the A, restricted Hub A, B and simulated OCI test VMs."
  value       = { for name, nic in azurerm_network_interface.workload : name => nic.private_ip_address }
}

output "HUB_IDS" {
  description = "Resource IDs of the two Virtual WAN hubs."
  value       = module.vwan.virtual_hub_resource_ids
}

output "HUB_B_ROUTE_MAP_ID" {
  description = "ID of the route map used on the VNet B connection."
  value       = azurerm_route_map.drop_oci.id
}
