mock_provider "azurerm" {}

override_data {
  target = data.azurerm_client_config.current
  values = {
    subscription_id = "11111111-1111-1111-1111-111111111111"
    tenant_id       = "22222222-2222-2222-2222-222222222222"
    object_id       = "33333333-3333-3333-3333-333333333333"
  }
}

variables {
  subscription_id = "11111111-1111-1111-1111-111111111111"
}

run "persistent_shared_storage_and_federation" {
  command = plan

  assert {
    condition = (
      azurerm_storage_account.main.name == "stecomdevmike2026" &&
      azurerm_storage_account.main.account_replication_type == "LRS" &&
      !azurerm_storage_account.main.shared_access_key_enabled &&
      !azurerm_storage_account.main.allow_nested_items_to_be_public &&
      alltrue([for container in azurerm_storage_container.control : container.container_access_type == "private"]) &&
      toset(keys(azurerm_storage_container.control)) == toset(["tfstate", "tfplans"])
    )
    error_message = "State and saved plans must share the private Entra-only business Storage account."
  }

  assert {
    condition = (
      azurerm_federated_identity_credential.github.subject == "repo:MichalBoczula/EcommerceECommerceStore.Terraform:environment:development" &&
      azurerm_role_assignment.ci_infrastructure.scope == azurerm_resource_group.main.id &&
      azurerm_role_assignment.ci_roles.scope == azurerm_resource_group.main.id &&
      azurerm_role_assignment.operator_files.principal_id == "33333333-3333-3333-3333-333333333333"
    )
    error_message = "CI federation must be environment-bound, with resource administration confined to this group and a stable human operator."
  }
}
