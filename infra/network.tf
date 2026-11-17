locals {
  networks = {
    a = {
      address_space   = var.vnet_a_prefix
      workload_subnet = var.vnet_a_prefix
    }
    b = {
      address_space   = var.vnet_b_prefix
      workload_subnet = var.vnet_b_prefix
    }
    oci = {
      address_space   = var.simulator_prefix
      workload_subnet = var.simulator_workload_prefix
    }
  }
}

resource "azurerm_virtual_network" "workload" {
  for_each = local.networks

  name                = "vnet-${each.key}"
  location            = azurerm_resource_group.poc.location
  resource_group_name = azurerm_resource_group.poc.name
  address_space       = [each.value.address_space]
  tags                = local.tags
}

resource "azurerm_subnet" "workload" {
  for_each = local.networks

  name                 = "workload"
  resource_group_name  = azurerm_resource_group.poc.name
  virtual_network_name = azurerm_virtual_network.workload[each.key].name
  address_prefixes     = [each.value.workload_subnet]
}

resource "azurerm_subnet" "simulator_gateway" {
  name                 = "GatewaySubnet"
  resource_group_name  = azurerm_resource_group.poc.name
  virtual_network_name = azurerm_virtual_network.workload["oci"].name
  address_prefixes     = [var.simulator_gateway_prefix]
}

resource "azurerm_network_security_group" "workload" {
  for_each = local.networks

  name                = "nsg-${each.key}"
  location            = azurerm_resource_group.poc.location
  resource_group_name = azurerm_resource_group.poc.name
  tags                = local.tags
}

resource "azurerm_subnet_network_security_group_association" "workload" {
  for_each = local.networks

  subnet_id                 = azurerm_subnet.workload[each.key].id
  network_security_group_id = azurerm_network_security_group.workload[each.key].id
}

resource "azurerm_network_security_rule" "approved_inbound" {
  for_each = {
    a   = var.simulator_prefix
    oci = var.vnet_a_prefix
  }

  name                        = "allow-approved-test-ports"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_ranges     = ["22", "30289"]
  source_address_prefix       = each.value
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.poc.name
  network_security_group_name = azurerm_network_security_group.workload[each.key].name
}

resource "azurerm_network_security_rule" "deny_other_test_inbound" {
  for_each = toset(["a", "oci"])

  name                        = "deny-other-test-ports"
  priority                    = 200
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_ranges     = ["22", "30289"]
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.poc.name
  network_security_group_name = azurerm_network_security_group.workload[each.key].name
}

resource "azurerm_network_security_rule" "deny_b_oci" {
  for_each = {
    b_in = {
      group     = "b"
      direction = "Inbound"
      source    = var.simulator_prefix
      dest      = "*"
    }
    b_out = {
      group     = "b"
      direction = "Outbound"
      source    = "*"
      dest      = var.simulator_prefix
    }
    oci_in = {
      group     = "oci"
      direction = "Inbound"
      source    = var.vnet_b_prefix
      dest      = "*"
    }
    oci_out = {
      group     = "oci"
      direction = "Outbound"
      source    = "*"
      dest      = var.vnet_b_prefix
    }
  }

  name                        = "deny-b-oci-${lower(each.value.direction)}"
  priority                    = 110
  direction                   = each.value.direction
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = each.value.source
  destination_address_prefix  = each.value.dest
  resource_group_name         = azurerm_resource_group.poc.name
  network_security_group_name = azurerm_network_security_group.workload[each.value.group].name
}

resource "azurerm_network_interface" "workload" {
  for_each = local.networks

  name                = "nic-${each.key}"
  location            = azurerm_resource_group.poc.location
  resource_group_name = azurerm_resource_group.poc.name
  tags                = local.tags

  ip_configuration {
    name                          = "private"
    subnet_id                     = azurerm_subnet.workload[each.key].id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "workload" {
  for_each = local.networks

  name                            = "vm-${each.key}"
  location                        = azurerm_resource_group.poc.location
  resource_group_name             = azurerm_resource_group.poc.name
  size                            = var.vm_size
  admin_username                  = "azureuser"
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.workload[each.key].id]
  custom_data                     = filebase64("${path.module}/cloud-init.yaml")
  tags                            = local.tags

  admin_ssh_key {
    username   = "azureuser"
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}
