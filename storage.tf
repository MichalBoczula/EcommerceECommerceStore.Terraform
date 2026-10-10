# Bootstrap retains the shared business/state account across foundation destroys.
data "azurerm_storage_account" "main" {
  name                = "stecom${var.environment}${var.name_suffix}"
  resource_group_name = data.azurerm_resource_group.main.name
}

resource "azurerm_storage_container" "main" {
  for_each              = toset(["photos", "invoices", "livedocs"])
  name                  = each.key
  storage_account_id    = data.azurerm_storage_account.main.id
  container_access_type = "private"
}
