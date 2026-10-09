resource "azurerm_mssql_server" "main" {
  name                          = "sql-${local.prefix}-${var.name_suffix}"
  resource_group_name           = azurerm_resource_group.main.name
  location                      = var.sql_location
  version                       = "12.0"
  administrator_login           = "ecomoperator"
  administrator_login_password  = var.sql_admin_password
  minimum_tls_version           = "1.2"
  public_network_access_enabled = true
  tags                          = local.tags
}

# One resource owns the database, including the Free offer. Never substitute Basic/F0.
resource "azapi_resource" "products_database" {
  type      = "Microsoft.Sql/servers/databases@2023-08-01"
  name      = "products"
  parent_id = azurerm_mssql_server.main.id
  location  = var.sql_location
  tags      = local.tags

  body = {
    sku = {
      name     = "GP_S_Gen5_2"
      tier     = "GeneralPurpose"
      family   = "Gen5"
      capacity = 2
    }
    properties = {
      useFreeLimit                     = true
      freeLimitExhaustionBehavior      = "AutoPause"
      autoPauseDelay                   = 60
      minCapacity                      = 0.5
      maxSizeBytes                     = 34359738368
      requestedBackupStorageRedundancy = "Local"
      licenseType                      = "LicenseIncluded"
      zoneRedundant                    = false
    }
  }

  response_export_values = [
    "properties.useFreeLimit",
    "properties.freeLimitExhaustionBehavior",
  ]

  lifecycle {
    postcondition {
      condition = (
        self.output.properties.useFreeLimit == true &&
        self.output.properties.freeLimitExhaustionBehavior == "AutoPause"
      )
      error_message = "Azure must confirm SQL Free with AutoPause at the limit. Inspect the database before proceeding."
    }
  }
}

resource "azurerm_mongo_cluster" "main" {
  name                   = "mongo-${local.prefix}-${var.name_suffix}"
  resource_group_name    = azurerm_resource_group.main.name
  location               = var.location
  administrator_username = "ecomoperator"
  administrator_password = var.mongo_admin_password
  authentication_methods = ["NativeAuth"]
  compute_tier           = "Free"
  high_availability_mode = "Disabled"
  shard_count            = 1
  storage_size_in_gb     = 32
  storage_type           = "PremiumSSD"
  version                = "8.0"
  public_network_access  = "Enabled"
  tags                   = local.tags
}

# Public endpoints do not mean unrestricted access. No rules exist by default.
# ACA database access will be configured when applications are deployed in step 5.
resource "azurerm_mssql_firewall_rule" "operator" {
  count            = var.operator_ipv4 == null ? 0 : 1
  name             = "local-operator"
  server_id        = azurerm_mssql_server.main.id
  start_ip_address = var.operator_ipv4
  end_ip_address   = var.operator_ipv4
}

resource "azurerm_mongo_cluster_firewall_rule" "operator" {
  count            = var.operator_ipv4 == null ? 0 : 1
  name             = "local-operator"
  mongo_cluster_id = azurerm_mongo_cluster.main.id
  start_ip_address = var.operator_ipv4
  end_ip_address   = var.operator_ipv4
}
