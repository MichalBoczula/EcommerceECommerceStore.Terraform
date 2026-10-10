resource "azurerm_static_web_app" "main" {
  # Static Web Apps supports a different set of regions than the ACA foundation.
  name                = "swa-${local.prefix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.static_web_app_location
  sku_tier            = "Free"
  sku_size            = "Free"
  tags                = local.tags

  # Angular deployment and browser/BFF configuration arrive in step 5.
}
