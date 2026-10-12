output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "container_apps" {
  description = "Environment for the six applications added in step 5."
  value = {
    environment_id              = azurerm_container_app_environment.main.id
    environment_name            = azurerm_container_app_environment.main.name
    managed_resource_group_name = azurerm_container_app_environment.main.infrastructure_resource_group_name
    subnet_id                   = azurerm_subnet.aca.id
    default_domain              = azurerm_container_app_environment.main.default_domain
  }
}

output "databases" {
  description = "Names/endpoints and ARM SQL Free readback; no passwords or connection strings."
  value = {
    sql_server              = azurerm_mssql_server.main.name
    sql_fqdn                = azurerm_mssql_server.main.fully_qualified_domain_name
    sql_database            = azapi_resource.products_database.name
    sql_location            = var.sql_location
    sql_free_offer_readback = azapi_resource.products_database.output
    mongo_cluster           = azurerm_mongo_cluster.main.name
    mongo_cluster_id        = azurerm_mongo_cluster.main.id
    mongo_location          = var.location
  }
}

output "storage" {
  value = {
    account_name  = azurerm_storage_account.main.name
    blob_endpoint = azurerm_storage_account.main.primary_blob_endpoint
    containers    = { for name, container in azurerm_storage_container.main : name => container.id }
  }
}

output "key_vault" {
  value = {
    name = azurerm_key_vault.main.name
    uri  = azurerm_key_vault.main.vault_uri
  }
}

output "managed_identities" {
  value = {
    for name, identity in azurerm_user_assigned_identity.app : name => {
      id           = identity.id
      client_id    = identity.client_id
      principal_id = identity.principal_id
    }
  }
}

output "frontend_url" {
  description = "Empty SWA hosting resource until the Angular deployment in step 5."
  value       = "https://${azurerm_static_web_app.main.default_host_name}"
}

output "products_deployment" {
  description = "Products stage, pinned release and verification details; contains no credentials. The URL is internal to ACA."
  value = var.products == null ? null : {
    stage                    = var.products.stage
    subscription_id          = var.subscription_id
    resource_group_name      = azurerm_resource_group.main.name
    container_app_name       = "ca-${local.prefix}-products"
    image                    = var.products.image
    source_commit            = var.products.source_commit
    sql_connection_secret_id = azurerm_key_vault_secret.products_sql[0].id
    sql_allowed_platform_ips = sort(tolist(local.products_sql_ips))
    migration_ipv4           = local.products_migration_ipv4
    url                      = try("https://${azurerm_container_app.products[0].ingress[0].fqdn}", null)
  }
}
