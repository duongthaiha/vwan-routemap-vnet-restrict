locals {
  vpn_endpoints = {
    primary   = 0
    secondary = 1
  }

  # With BGP disabled either public IP can be used for either local gateway.
  hub_vpn_public_ips = sort([
    for config in data.azurerm_vpn_gateway.hub_a.ip_configuration : config.public_ip_address
  ])
}

data "azurerm_vpn_gateway" "hub_a" {
  name                = "vpng-hub-a"
  resource_group_name = azurerm_resource_group.poc.name

  depends_on = [module.vwan]
}

resource "azurerm_public_ip" "simulator_gateway" {
  for_each = local.vpn_endpoints

  name                = "pip-oci-gateway-${each.key}"
  location            = azurerm_resource_group.poc.location
  resource_group_name = azurerm_resource_group.poc.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = local.tags

  # Azure Policy can append IP tags; preserve them without replacing gateway IPs.
  lifecycle {
    ignore_changes = [ip_tags]
  }
}

resource "azurerm_virtual_network_gateway" "simulator" {
  name                        = "vng-oci-simulator"
  location                    = azurerm_resource_group.poc.location
  resource_group_name         = azurerm_resource_group.poc.name
  type                        = "Vpn"
  vpn_type                    = "RouteBased"
  sku                         = "VpnGw1AZ"
  generation                  = "Generation1"
  active_active               = true
  bgp_enabled                 = false
  virtual_wan_traffic_enabled = true
  tags                        = local.tags

  dynamic "ip_configuration" {
    for_each = local.vpn_endpoints

    content {
      name                          = "gateway-${ip_configuration.key}"
      public_ip_address_id          = azurerm_public_ip.simulator_gateway[ip_configuration.key].id
      private_ip_address_allocation = "Dynamic"
      subnet_id                     = azurerm_subnet.simulator_gateway.id
    }
  }

  # Azure rejects workload subnet updates while the gateway is provisioning.
  depends_on = [
    azurerm_network_interface.workload["oci"],
    azurerm_subnet_network_security_group_association.workload["oci"],
  ]
}

resource "azurerm_vpn_site" "simulator" {
  for_each = local.vpn_endpoints

  name                = "site-oci-${each.key}"
  location            = azurerm_resource_group.poc.location
  resource_group_name = azurerm_resource_group.poc.name
  virtual_wan_id      = module.vwan.resource_id
  address_cidrs       = [var.simulator_prefix]
  device_vendor       = "Azure"
  device_model        = "VPN Gateway simulator"
  tags                = local.tags

  link {
    name          = "link-${each.key}"
    ip_address    = azurerm_public_ip.simulator_gateway[each.key].ip_address
    speed_in_mbps = 100
  }

  depends_on = [azurerm_virtual_network_gateway.simulator]
}

resource "azurerm_vpn_gateway_connection" "to_simulator" {
  for_each = local.vpn_endpoints

  name                      = "connection-oci-${each.key}"
  vpn_gateway_id            = module.vwan.vpn_gateway_resource_ids["hub_a"]
  remote_vpn_site_id        = azurerm_vpn_site.simulator[each.key].id
  internet_security_enabled = false

  routing {
    associated_route_table = "${module.vwan.virtual_hub_resource_ids["a"]}/hubRouteTables/defaultRouteTable"

    propagated_route_table {
      labels          = ["hub-a-oci"]
      route_table_ids = [azurerm_virtual_hub_route_table.oci_a.id]
    }
  }

  vpn_link {
    name             = "link-${each.key}"
    vpn_site_link_id = azurerm_vpn_site.simulator[each.key].link[0].id
    bgp_enabled      = false
    protocol         = "IKEv2"
    shared_key       = var.vpn_psk

    ipsec_policy {
      dh_group                 = "ECP384"
      ike_encryption_algorithm = "AES256"
      ike_integrity_algorithm  = "SHA384"
      encryption_algorithm     = "GCMAES256"
      integrity_algorithm      = "GCMAES256"
      pfs_group                = "ECP384"
      sa_data_size_kb          = 102400000
      sa_lifetime_sec          = 3600
    }
  }

  # Azure omits this key on reads, which otherwise causes plan drift.
  lifecycle {
    ignore_changes = [vpn_link[0].shared_key]
  }
}

resource "azurerm_local_network_gateway" "hub" {
  for_each = local.vpn_endpoints

  name                = "lng-hub-a-${each.key}"
  location            = azurerm_resource_group.poc.location
  resource_group_name = azurerm_resource_group.poc.name
  gateway_address     = local.hub_vpn_public_ips[each.value]
  address_space       = [var.vnet_a_prefix]
  tags                = local.tags
}

resource "azurerm_virtual_network_gateway_connection" "to_hub" {
  for_each = local.vpn_endpoints

  name                       = "connection-hub-a-${each.key}"
  location                   = azurerm_resource_group.poc.location
  resource_group_name        = azurerm_resource_group.poc.name
  type                       = "IPsec"
  virtual_network_gateway_id = azurerm_virtual_network_gateway.simulator.id
  local_network_gateway_id   = azurerm_local_network_gateway.hub[each.key].id
  connection_protocol        = "IKEv2"
  bgp_enabled                = false
  shared_key                 = var.vpn_psk
  tags                       = local.tags

  ipsec_policy {
    dh_group         = "ECP384"
    ike_encryption   = "AES256"
    ike_integrity    = "SHA384"
    ipsec_encryption = "GCMAES256"
    ipsec_integrity  = "GCMAES256"
    pfs_group        = "ECP384"
    sa_datasize      = 102400000
    sa_lifetime      = 3600
  }
}
