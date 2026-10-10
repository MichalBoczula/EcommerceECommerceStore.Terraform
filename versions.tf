terraform {
  required_version = ">= 1.16.0, < 1.17.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "= 5.8.0"
    }
    # AzureRM 5.8.0 does not expose the SQL Free offer settings.
    azapi = {
      source  = "Azure/azapi"
      version = "= 2.13.0"
    }
  }

  # Connection settings are supplied during init; credentials stay in the environment.
  backend "azurerm" {
    use_azuread_auth = true
  }
}
