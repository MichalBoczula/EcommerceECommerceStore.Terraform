resource "azurerm_static_web_app" "main" {
  name                = "swa-${local.prefix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  sku_tier            = "Free"
  sku_size            = "Free"
  tags                = local.tags

  # Angular deployment and browser/BFF configuration arrive in step 5.
}
