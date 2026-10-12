mock_provider "azurerm" {
  override_during = plan
}
mock_provider "azapi" {
  override_during = plan
}

override_data {
  target = data.azurerm_client_config.current
  values = {
    subscription_id = "11111111-1111-1111-1111-111111111111"
    tenant_id       = "22222222-2222-2222-2222-222222222222"
    object_id       = "33333333-3333-3333-3333-333333333333"
  }
}

override_data {
  target = data.azurerm_public_ips.aca
  values = {
    public_ips = [
      { id = "one", name = "platform-one", ip_address = "198.51.100.1", fqdn = "", domain_name_label = "" },
      { id = "two", name = "platform-two", ip_address = "198.51.100.2", fqdn = "", domain_name_label = "" },
      { id = "duplicate", name = "platform-duplicate", ip_address = "198.51.100.1", fqdn = "", domain_name_label = "" },
      { id = "empty", name = "not-allocated", ip_address = "", fqdn = "", domain_name_label = "" },
    ]
  }
}

override_resource {
  target = azurerm_mssql_server.main
  values = {
    id                          = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-ecommerce-dev/providers/Microsoft.Sql/servers/sql-ecom-dev-mike2026"
    fully_qualified_domain_name = "sql-ecom-dev-mike2026.database.windows.net"
  }
}

override_resource {
  target = azurerm_key_vault.main
  values = {
    id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-ecommerce-dev/providers/Microsoft.KeyVault/vaults/kv-ec-dev-mike2026"
  }
}

override_resource {
  target = azurerm_container_app_environment.main
  values = {
    id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-ecommerce-dev/providers/Microsoft.App/managedEnvironments/cae-ecom-dev"
  }
}

override_resource {
  target = azurerm_user_assigned_identity.app["products"]
  values = {
    id        = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-ecommerce-dev/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-ecom-dev-products"
    client_id = "44444444-4444-4444-4444-444444444444"
  }
}

override_resource {
  target = azurerm_key_vault_secret.products_sql
  values = {
    id = "https://kv-ec-dev-mike2026.vault.azure.net/secrets/products-sql-connection/0123456789abcdef0123456789abcdef"
  }
}

override_resource {
  target = azapi_resource.products_database
  values = {
    output = { properties = { useFreeLimit = true, freeLimitExhaustionBehavior = "AutoPause" } }
  }
}

variables {
  subscription_id      = "11111111-1111-1111-1111-111111111111"
  sql_admin_password   = "TestOnly-Sql;\"123456!"
  mongo_admin_password = "TestOnly-Mongo-123456!"
  environment          = "dev"
  name_suffix          = "mike2026"
  resource_group_name  = null
  operator_ipv4        = null
  products = {
    stage          = "prepare"
    image          = "mb0101/product-catalog-api@sha256:8ebff9865f56bf4c073417fa1ebdc3d0748b8a9a565f30f3f9afbf4705fa90fc"
    source_commit  = "5fa6966327dbc7894ce8156cf222b28a0cdf52f5"
    migration_ipv4 = "203.0.113.10"
  }
}

run "prepare_before_rollout" {
  command = plan

  assert {
    condition = (
      length(azurerm_container_app.products) == 0 &&
      length(azurerm_key_vault_secret.products_sql) == 1 &&
      length(azurerm_mssql_firewall_rule.products_aca) == 2 &&
      alltrue([for rule in azurerm_mssql_firewall_rule.products_aca : rule.start_ip_address == rule.end_ip_address]) &&
      length(azurerm_mssql_firewall_rule.products_migration) == 1 &&
      length(azurerm_mongo_cluster_firewall_rule.operator) == 0
    )
    error_message = "Preparation must create SQL-only access, include all allocated platform IPs once, and avoid starting an unmigrated API."
  }

  assert {
    condition = (
      strcontains(azurerm_key_vault_secret.products_sql[0].value, "Password=\"TestOnly-Sql;\"\"123456!\";") &&
      strcontains(azurerm_key_vault_secret.products_sql[0].value, "Encrypt=True;TrustServerCertificate=False;")
    )
    error_message = "SQL credentials must be quoted correctly, with encryption and certificate validation enabled."
  }
}

run "internal_api_after_migrations" {
  command = plan

  variables {
    products = {
      stage         = "run"
      image         = "mb0101/product-catalog-api@sha256:8ebff9865f56bf4c073417fa1ebdc3d0748b8a9a565f30f3f9afbf4705fa90fc"
      source_commit = "5fa6966327dbc7894ce8156cf222b28a0cdf52f5"
    }
  }

  assert {
    condition = (
      length(azurerm_container_app.products) == 1 &&
      !azurerm_container_app.products[0].ingress[0].external_enabled &&
      !azurerm_container_app.products[0].ingress[0].allow_insecure_connections &&
      azurerm_container_app.products[0].ingress[0].target_port == 8080 &&
      azurerm_container_app.products[0].template[0].min_replicas == 1 &&
      azurerm_container_app.products[0].template[0].max_replicas == 1 &&
      length(azurerm_mssql_firewall_rule.products_migration) == 0
    )
    error_message = "The smoke API must keep one internal replica and permit removal of the laptop's migration rule."
  }

  assert {
    condition = (
      one([for env in azurerm_container_app.products[0].template[0].container[0].env : env.value if env.name == "Database__ApplyMigrations"]) == "false" &&
      one([for env in azurerm_container_app.products[0].template[0].container[0].env : env.secret_name if env.name == "ConnectionStrings__ProductCatalogDb"]) == "products-sql" &&
      one(azurerm_container_app.products[0].template[0].container[0].liveness_probe).path == "/health/live" &&
      one(azurerm_container_app.products[0].template[0].container[0].readiness_probe).path == "/health/ready" &&
      one(azurerm_container_app.products[0].secret).identity == azurerm_user_assigned_identity.app["products"].id &&
      one(azurerm_container_app.products[0].secret).key_vault_secret_id == azurerm_key_vault_secret.products_sql[0].id
    )
    error_message = "The API must read its Key Vault secret through Products identity, disable runtime migrations, and distinguish process health from SQL readiness."
  }
}

run "reject_floating_image" {
  command = plan
  variables {
    products = {
      stage          = "prepare"
      image          = "mb0101/product-catalog-api:latest"
      source_commit  = "5fa6966327dbc7894ce8156cf222b28a0cdf52f5"
      migration_ipv4 = "203.0.113.10"
    }
  }
  expect_failures = [var.products]
}

run "reject_azure_wide_sql_rule" {
  command = plan
  variables {
    products = {
      stage          = "prepare"
      image          = "mb0101/product-catalog-api@sha256:8ebff9865f56bf4c073417fa1ebdc3d0748b8a9a565f30f3f9afbf4705fa90fc"
      source_commit  = "5fa6966327dbc7894ce8156cf222b28a0cdf52f5"
      migration_ipv4 = "0.0.0.0"
    }
  }
  expect_failures = [var.products]
}

run "reject_preparation_without_local_sql_access" {
  command = plan
  variables {
    products = {
      stage         = "prepare"
      image         = "mb0101/product-catalog-api@sha256:8ebff9865f56bf4c073417fa1ebdc3d0748b8a9a565f30f3f9afbf4705fa90fc"
      source_commit = "5fa6966327dbc7894ce8156cf222b28a0cdf52f5"
    }
  }
  expect_failures = [var.products]
}

run "reject_empty_platform_addresses" {
  command = plan
  override_data {
    target = data.azurerm_public_ips.aca
    values = { public_ips = [] }
  }
  expect_failures = [azurerm_key_vault_secret.products_sql]
}
