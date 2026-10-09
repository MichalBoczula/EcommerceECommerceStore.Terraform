provider "azurerm" {
  subscription_id = var.subscription_id
  use_cli         = true

  # Register only the services this root uses, including Microsoft.App.
  resource_provider_registrations = "none"
  resource_providers_to_register = [
    "Microsoft.App",
    "Microsoft.DocumentDB",
    "Microsoft.KeyVault",
    "Microsoft.ManagedIdentity",
    "Microsoft.Network",
    "Microsoft.Sql",
    "Microsoft.Storage",
    "Microsoft.Web",
  ]
  storage_use_azuread = true

  features {
    key_vault {
      # This vault is disposable. Purging it permits recreation with the same name.
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = false
    }
  }
}

provider "azapi" {
  subscription_id = var.subscription_id
  use_cli         = true
}

data "azurerm_client_config" "current" {}
