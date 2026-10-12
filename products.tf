locals {
  products_prepare = var.products != null
  products_run     = var.products == null ? false : var.products.stage == "run"
  products_migration_ipv4 = var.products == null ? null : (
    var.products.migration_ipv4 != null ? var.products.migration_ipv4 : var.operator_ipv4
  )
  # The workload-profile environment owns these public IPs. Read them; never
  # manage/import its platform resources. Include every allocated address,
  # rather than confusing the environment's inbound static_ip_address with egress.
  products_sql_ips = local.products_prepare ? toset([
    for ip in data.azurerm_public_ips.aca[0].public_ips : ip.ip_address
    if ip.ip_address != null && ip.ip_address != ""
  ]) : toset([])
}

# Apply the foundation first: its managed resource group must already exist so
# these addresses are known when Terraform plans the individual firewall rules.
data "azurerm_public_ips" "aca" {
  count               = local.products_prepare ? 1 : 0
  resource_group_name = azurerm_container_app_environment.main.infrastructure_resource_group_name
  allocation_type     = "Static"
  attachment_status   = "Attached"
}

resource "azurerm_mssql_firewall_rule" "products_aca" {
  for_each         = local.products_sql_ips
  name             = "products-aca-${replace(each.key, ".", "-")}"
  server_id        = azurerm_mssql_server.main.id
  start_ip_address = each.key
  end_ip_address   = each.key
}

# Local EF migrations need only SQL access. Do not open the Mongo firewall.
# Avoid duplicating the existing operator rule if the same IP is already allowed.
resource "azurerm_mssql_firewall_rule" "products_migration" {
  count = !local.products_prepare ? 0 : (
    var.products.migration_ipv4 != null && var.products.migration_ipv4 != var.operator_ipv4 ? 1 : 0
  )
  name             = "products-local-migration"
  server_id        = azurerm_mssql_server.main.id
  start_ip_address = var.products.migration_ipv4
  end_ip_address   = var.products.migration_ipv4
}

# This first disposable smoke deployment uses the existing SQL administrator.
# Replace it with a contained runtime user before a persistent/multi-app rollout.
# Quoting/escaping also supports passwords containing semicolons and quotes.
resource "azurerm_key_vault_secret" "products_sql" {
  count        = local.products_prepare ? 1 : 0
  name         = "products-sql-connection"
  key_vault_id = azurerm_key_vault.main.id
  value = format(
    "Server=tcp:%s,1433;Database=products;User ID=%s;Password=\"%s\";Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;",
    azurerm_mssql_server.main.fully_qualified_domain_name,
    azurerm_mssql_server.main.administrator_login,
    replace(var.sql_admin_password, "\"", "\"\"")
  )
  content_type = "SQL Server connection string"
  tags         = local.tags
  depends_on   = [azurerm_role_assignment.operator_secrets]

  lifecycle {
    precondition {
      condition     = length(local.products_sql_ips) > 0
      error_message = "No allocated static public IPs found in the ACA managed group. Inspect networking before granting SQL access or deploying Products."
    }
  }
}

resource "azurerm_container_app" "products" {
  count                        = local.products_run ? 1 : 0
  name                         = "ca-${local.prefix}-products"
  resource_group_name          = azurerm_resource_group.main.name
  container_app_environment_id = azurerm_container_app_environment.main.id
  workload_profile_name        = "Consumption"
  revision_mode                = "Single"
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app["products"].id]
  }

  secret {
    name                = "products-sql"
    identity            = azurerm_user_assigned_identity.app["products"].id
    key_vault_secret_id = azurerm_key_vault_secret.products_sql[0].id
  }

  ingress {
    external_enabled           = false
    allow_insecure_connections = false
    target_port                = 8080
    transport                  = "http"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    # Keep one small replica for the first smoke test, including console access.
    min_replicas = 1
    max_replicas = 1

    container {
      name   = "products"
      image  = var.products.image
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name  = "ASPNETCORE_ENVIRONMENT"
        value = "Production"
      }
      env {
        name  = "ASPNETCORE_HTTP_PORTS"
        value = "8080"
      }
      env {
        name  = "AZURE_CLIENT_ID"
        value = azurerm_user_assigned_identity.app["products"].client_id
      }
      env {
        name        = "ConnectionStrings__ProductCatalogDb"
        secret_name = "products-sql"
      }
      env {
        name  = "Database__ApplyMigrations"
        value = "false"
      }

      startup_probe {
        transport               = "HTTP"
        port                    = 8080
        path                    = "/health/live"
        interval_seconds        = 5
        timeout                 = 2
        failure_count_threshold = 60
      }
      liveness_probe {
        transport               = "HTTP"
        port                    = 8080
        path                    = "/health/live"
        interval_seconds        = 15
        timeout                 = 2
        failure_count_threshold = 3
      }
      readiness_probe {
        transport               = "HTTP"
        port                    = 8080
        path                    = "/health/ready"
        interval_seconds        = 10
        timeout                 = 6
        success_count_threshold = 1
        failure_count_threshold = 48
      }
    }
  }

  # Key Vault has already received the Products identity's read role in the
  # foundation. SQL rules are prepared before the API is created.
  depends_on = [
    azurerm_role_assignment.app_secrets,
    azurerm_mssql_firewall_rule.products_aca,
    azurerm_mssql_firewall_rule.products_migration,
  ]

}
