terraform {
  backend "azurerm" {
    use_cli              = true
    use_azuread_auth     = true
    storage_account_name = "stecomtfstatemb261011"
    container_name       = "tfstate"
    key                  = "development.terraform.tfstate"
  }
}
