resource "azurerm_virtual_network" "main" {
  name                = "vnet-${local.prefix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  address_space       = ["10.42.0.0/16"]
  tags                = local.tags
}

resource "azurerm_subnet" "aca" {
  name                 = "aca"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.42.0.0/27"]

  delegation {
    name = "container-apps"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_container_app_environment" "main" {
  name                               = "cae-${local.prefix}"
  resource_group_name                = azurerm_resource_group.main.name
  location                           = var.location
  infrastructure_subnet_id           = azurerm_subnet.aca.id
  infrastructure_resource_group_name = "rg-${local.prefix}-aca-managed"
  internal_load_balancer_enabled     = false
  public_network_access              = "Enabled"
  zone_redundancy_enabled            = false
  tags                               = local.tags

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }

  # Omit logs_destination: console/system logs are streamed, without Log Analytics.
  # Azure creates the managed networking resources in its own resource group.
}
