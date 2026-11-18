locals {
  tags = {
    "azd-env-name" = var.environment_name
    owner          = var.owner
    expires-on     = var.expires_on
    purpose        = "vwan-oci-routemap-poc"
  }
}

resource "azurerm_resource_group" "poc" {
  name     = "rg-${var.environment_name}"
  location = var.location
  tags     = local.tags
}

module "vwan" {
  source  = "Azure/avm-ptn-alz-connectivity-virtual-wan/azurerm//modules/virtual-wan"
  version = "0.18.2"

  location            = azurerm_resource_group.poc.location
  resource_group_name = azurerm_resource_group.poc.name
  virtual_wan_name    = "vwan-poc"
  type                = "Standard"
  enable_telemetry    = false
  tags                = local.tags

  virtual_hubs = {
    a = {
      name                = "hub-a"
      location            = var.location
      resource_group_name = azurerm_resource_group.poc.name
      address_prefix      = var.hub_a_prefix
      sku                 = "Standard"
    }
    b = {
      name                = "hub-b"
      location            = var.location
      resource_group_name = azurerm_resource_group.poc.name
      address_prefix      = var.hub_b_prefix
      sku                 = "Standard"
    }
  }

  vpn_gateways = {
    hub_a = {
      name            = "vpng-hub-a"
      virtual_hub_key = "a"
      scale_unit      = 1
    }
  }
}

resource "azurerm_route_map" "drop_oci" {
  name           = "RM-DROP-OCI"
  virtual_hub_id = module.vwan.virtual_hub_resource_ids["b"]

  rule {
    name                 = "drop-simulator-prefix"
    next_step_if_matched = "Terminate"

    match_criterion {
      match_condition = "Contains"
      route_prefix    = [var.simulator_prefix]
    }

    action {
      type = "Drop"
    }
  }
}

resource "azurerm_route_map" "drop_oci_hub_a" {
  name           = "RM-DROP-OCI"
  virtual_hub_id = module.vwan.virtual_hub_resource_ids["a"]

  rule {
    name                 = "drop-simulator-prefix"
    next_step_if_matched = "Terminate"

    match_criterion {
      match_condition = "Contains"
      route_prefix    = [var.simulator_prefix]
    }

    action {
      type = "Drop"
    }
  }
}

resource "azurerm_virtual_hub_route_table" "oci_a" {
  name           = "rt-oci-a"
  virtual_hub_id = module.vwan.virtual_hub_resource_ids["a"]
  labels         = ["hub-a-oci"]
}

resource "azurerm_virtual_hub_connection" "a" {
  name                      = "connection-vnet-a"
  virtual_hub_id            = module.vwan.virtual_hub_resource_ids["a"]
  remote_virtual_network_id = azurerm_virtual_network.workload["a"].id
  internet_security_enabled = false

  routing {
    associated_route_table_id = azurerm_virtual_hub_route_table.oci_a.id

    propagated_route_table {
      labels          = ["default"]
      route_table_ids = ["${module.vwan.virtual_hub_resource_ids["a"]}/hubRouteTables/defaultRouteTable"]
    }
  }
}

resource "azurerm_virtual_hub_connection" "a_no_oci" {
  name                      = "connection-vnet-a-no-oci"
  virtual_hub_id            = module.vwan.virtual_hub_resource_ids["a"]
  remote_virtual_network_id = azurerm_virtual_network.workload["a-no-oci"].id
  internet_security_enabled = false

  routing {
    associated_route_table_id = "${module.vwan.virtual_hub_resource_ids["a"]}/hubRouteTables/defaultRouteTable"
    outbound_route_map_id     = azurerm_route_map.drop_oci_hub_a.id

    propagated_route_table {
      labels          = ["hub-a-oci"]
      route_table_ids = [azurerm_virtual_hub_route_table.oci_a.id]
    }
  }
}

resource "azurerm_virtual_hub_connection" "b" {
  name                      = "connection-vnet-b"
  virtual_hub_id            = module.vwan.virtual_hub_resource_ids["b"]
  remote_virtual_network_id = azurerm_virtual_network.workload["b"].id
  internet_security_enabled = false

  routing {
    associated_route_table_id = "${module.vwan.virtual_hub_resource_ids["b"]}/hubRouteTables/defaultRouteTable"
    outbound_route_map_id     = var.enable_b_route_map ? azurerm_route_map.drop_oci.id : null

    propagated_route_table {
      labels          = ["default"]
      route_table_ids = ["${module.vwan.virtual_hub_resource_ids["b"]}/hubRouteTables/defaultRouteTable"]
    }
  }
}
