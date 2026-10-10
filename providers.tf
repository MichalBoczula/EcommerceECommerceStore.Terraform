provider "azurerm" {
  subscription_id = var.subscription_id
  use_cli         = true

  # The operator-run bootstrap registers providers before the CI identity is used.
  resource_provider_registrations = "none"
  storage_use_azuread             = true

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
