mock_provider "azurerm" {}
mock_provider "azapi" {}

override_data {
  target = data.azurerm_client_config.current
  values = {
    subscription_id = "11111111-1111-1111-1111-111111111111"
    tenant_id       = "22222222-2222-2222-2222-222222222222"
    object_id       = "33333333-3333-3333-3333-333333333333"
  }
}

variables {
  subscription_id      = "11111111-1111-1111-1111-111111111111"
  sql_admin_password   = "TestOnly-Sql-123456!"
  mongo_admin_password = "TestOnly-Mongo-123456!"
}

run "free_foundation" {
  command = plan

  assert {
    condition = contains(
      ["centralus", "eastus2", "westus2", "westeurope", "eastasia"],
      azurerm_static_web_app.main.location
    )
    error_message = "Static Web Apps must use one of its supported regions, independently of the ACA region."
  }

  assert {
    condition = (
      azapi_resource.products_database.body.properties.useFreeLimit == true &&
      azapi_resource.products_database.body.properties.freeLimitExhaustionBehavior == "AutoPause" &&
      azapi_resource.products_database.body.properties.requestedBackupStorageRedundancy == "Local" &&
      azapi_resource.products_database.body.properties.maxSizeBytes == 34359738368 &&
      azurerm_mongo_cluster.main.compute_tier == "Free" &&
      azurerm_static_web_app.main.sku_tier == "Free"
    )
    error_message = "Database and frontend resources must retain the Free offers and SQL pause-at-limit."
  }

  assert {
    condition = (
      length(azurerm_container_app_environment.main.workload_profile) == 1 &&
      one(azurerm_container_app_environment.main.workload_profile).workload_profile_type == "Consumption" &&
      contains([null, ""], azurerm_container_app_environment.main.logs_destination)
    )
    error_message = "The ACA foundation must use Consumption only, with no paid log destination."
  }

  assert {
    condition = (
      !azurerm_storage_account.main.shared_access_key_enabled &&
      !azurerm_storage_account.main.allow_nested_items_to_be_public &&
      azurerm_storage_account.main.account_replication_type == "LRS" &&
      alltrue([for container in azurerm_storage_container.main : container.container_access_type == "private"])
    )
    error_message = "Business files must remain private and use Entra authentication on Standard LRS storage."
  }

  assert {
    condition = (
      length(azurerm_mssql_firewall_rule.operator) == 0 &&
      length(azurerm_mongo_cluster_firewall_rule.operator) == 0 &&
      azurerm_role_assignment.app_files["livedocs"].role_definition_name == "Storage Blob Data Reader" &&
      !contains(keys(azurerm_role_assignment.app_secrets), "livedocs") &&
      !contains(keys(azurerm_role_assignment.app_secrets), "bff")
    )
    error_message = "Default database access must be closed; LiveDocs and BFF must not gain business secret access."
  }
}

run "explicit_operator_address" {
  command = plan

  variables {
    operator_ipv4 = "203.0.113.10"
  }

  assert {
    condition = (
      length(azurerm_mssql_firewall_rule.operator) == 1 &&
      length(azurerm_mongo_cluster_firewall_rule.operator) == 1 &&
      azurerm_mssql_firewall_rule.operator[0].start_ip_address == "203.0.113.10" &&
      azurerm_mssql_firewall_rule.operator[0].end_ip_address == "203.0.113.10" &&
      azurerm_mongo_cluster_firewall_rule.operator[0].start_ip_address == "203.0.113.10" &&
      azurerm_mongo_cluster_firewall_rule.operator[0].end_ip_address == "203.0.113.10"
    )
    error_message = "Opting into local database access must allow only the supplied IPv4 in both databases."
  }
}

run "reject_azure_wide_operator_rule" {
  command = plan

  variables {
    operator_ipv4 = "0.0.0.0"
  }

  expect_failures = [var.operator_ipv4]
}

run "portfolio_names_fit_azure_limits" {
  command = plan

  variables {
    environment = "portfolio"
    name_suffix = "mike2026"
  }

  assert {
    condition = (
      length(azurerm_storage_account.main.name) <= 24 &&
      length(azurerm_key_vault.main.name) <= 24 &&
      azurerm_resource_group.main.name == "rg-ecommerce-portfolio"
    )
    error_message = "Both supported environment names must fit Azure naming limits."
  }
}
