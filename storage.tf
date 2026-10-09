resource "azurerm_storage_account" "main" {
  name                            = "stecom${var.environment}${var.name_suffix}"
  resource_group_name             = azurerm_resource_group.main.name
  location                        = var.location
  account_kind                    = "StorageV2"
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  access_tier                     = "Hot"
  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  allow_nested_items_to_be_public = false
  public_network_access           = "Enabled"
  tags                            = local.tags

  # Authenticated HTTPS endpoint. Containers are private; access requires Entra RBAC.
  # Step 1 uses disposable demo files, without retained versions after destruction.
  blob_properties {
    versioning_enabled = false
  }
}

resource "azurerm_storage_container" "main" {
  for_each              = toset(["photos", "invoices", "livedocs"])
  name                  = each.key
  storage_account_id    = azurerm_storage_account.main.id
  container_access_type = "private"
}
