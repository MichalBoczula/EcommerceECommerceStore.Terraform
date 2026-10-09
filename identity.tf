resource "azurerm_key_vault" "main" {
  name                          = "kv-ec-${var.environment}-${var.name_suffix}"
  resource_group_name           = azurerm_resource_group.main.name
  location                      = var.location
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true
  public_network_access_enabled = true
  soft_delete_retention_days    = 7
  purge_protection_enabled      = false
  tags                          = local.tags

  # Authenticated HTTPS endpoint; no secrets are populated by this foundation.
}

resource "azurerm_user_assigned_identity" "app" {
  for_each            = toset(["products", "users", "invoice", "payments", "bff", "livedocs"])
  name                = "id-${local.prefix}-${each.key}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  tags                = local.tags
}

resource "azurerm_role_assignment" "app_secrets" {
  for_each             = toset(["products", "users", "invoice", "payments"])
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.app[each.key].principal_id
}

resource "azurerm_role_assignment" "app_files" {
  for_each = {
    products = { container = "photos", role = "Storage Blob Data Contributor" }
    invoice  = { container = "invoices", role = "Storage Blob Data Contributor" }
    livedocs = { container = "livedocs", role = "Storage Blob Data Reader" }
  }
  scope                = azurerm_storage_container.main[each.value.container].id
  role_definition_name = each.value.role
  principal_id         = azurerm_user_assigned_identity.app[each.key].principal_id
}

resource "azurerm_role_assignment" "operator_secrets" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "operator_files" {
  scope                = azurerm_storage_account.main.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}
