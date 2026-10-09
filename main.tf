locals {
  prefix              = "ecom-${var.environment}"
  resource_group_name = coalesce(var.resource_group_name, "rg-ecommerce-${var.environment}")
  tags = {
    project     = "ECommerceStore"
    environment = var.environment
    managed_by  = "Terraform"
  }
}

resource "azurerm_resource_group" "main" {
  name     = local.resource_group_name
  location = var.location
  tags     = local.tags
}
