terraform {
  required_version = ">= 1.16.0, < 1.17.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "= 5.8.0"
    }
  }
  # Bootstrap is operator-managed with a separate, retained local state.
}

provider "azurerm" {
  subscription_id                 = var.subscription_id
  use_cli                         = true
  storage_use_azuread             = true
  resource_provider_registrations = "none"
  resource_providers_to_register = [
    "Microsoft.App", "Microsoft.DocumentDB", "Microsoft.KeyVault",
    "Microsoft.ManagedIdentity", "Microsoft.Network", "Microsoft.Sql",
    "Microsoft.Storage", "Microsoft.Web",
  ]
  features {}
}

data "azurerm_client_config" "current" {}

locals {
  group_name  = coalesce(var.resource_group_name, "rg-ecommerce-${var.environment}")
  operator_id = coalesce(var.operator_object_id, data.azurerm_client_config.current.object_id)
  tags = {
    project     = "ECommerceStore"
    environment = var.environment
    managed_by  = "Terraform"
  }
}

resource "azurerm_resource_group" "main" {
  name     = local.group_name
  location = var.location
  tags     = local.tags
  lifecycle {
    prevent_destroy = true
  }
}

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
  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_role_assignment" "operator_files" {
  scope                = azurerm_storage_account.main.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = local.operator_id
}

resource "azurerm_storage_container" "control" {
  for_each              = toset(["tfstate", "tfplans"])
  name                  = each.key
  storage_account_id    = azurerm_storage_account.main.id
  container_access_type = "private"
  depends_on            = [azurerm_role_assignment.operator_files]
}

resource "azurerm_user_assigned_identity" "ci" {
  name                = "id-ecom-${var.environment}-terraform"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "github" {
  name                = "github-development"
  resource_group_name = azurerm_resource_group.main.name
  parent_id           = azurerm_user_assigned_identity.ci.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = "https://token.actions.githubusercontent.com"
  subject             = "repo:${var.github_repository}:environment:development"
}

resource "azurerm_role_assignment" "ci_infrastructure" {
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.ci.principal_id
}

resource "azurerm_role_assignment" "ci_roles" {
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = azurerm_user_assigned_identity.ci.principal_id
}

resource "azurerm_role_assignment" "ci_files" {
  scope                = azurerm_storage_account.main.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.ci.principal_id
}

# Purge addresses are subscription-level deleted-vault endpoints, outside the RG.
resource "azurerm_role_assignment" "ci_vault_purge" {
  scope                = "/subscriptions/${var.subscription_id}"
  role_definition_name = "Key Vault Purge Operator"
  principal_id         = azurerm_user_assigned_identity.ci.principal_id
}

output "setup" {
  value = {
    subscription_id     = var.subscription_id
    tenant_id           = data.azurerm_client_config.current.tenant_id
    client_id           = azurerm_user_assigned_identity.ci.client_id
    operator_object_id  = local.operator_id
    resource_group_name = azurerm_resource_group.main.name
    storage_account     = azurerm_storage_account.main.name
    state_container     = azurerm_storage_container.control["tfstate"].name
    plans_container     = azurerm_storage_container.control["tfplans"].name
    state_key           = "development.terraform.tfstate"
  }
}
