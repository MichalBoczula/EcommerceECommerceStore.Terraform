# ECommerceStore Terraform

Provision and remove the Azure foundation locally with ordinary Terraform commands. Application state is stored in an independent Azure Storage account through your Azure CLI session.

This is a fresh implementation. The deprecated Infrastructure repository is not a dependency.

## What it creates

| Resource | Configuration |
| --- | --- |
| Resource group | `rg-ecommerce-dev` by default; Terraform owns its lifecycle |
| Network | One VNet and one `/27` subnet delegated to Container Apps |
| Container Apps environment | External ingress supported; only the Consumption workload profile |
| Products database | Azure SQL Free, 32 GiB, pauses when the monthly free limit is reached |
| Users / Invoice / Payments database server | One Azure DocumentDB Mongo-compatible **Free** cluster, 32 GiB, native authentication |
| File storage | Standard Hot LRS; private `photos`, `invoices`, `livedocs` containers; Entra authentication |
| Key Vault | Standard, RBAC authorization; empty until application configuration |
| Managed identities | Products, Users, Invoice, Payments, BFF and LiveDocs |
| Permissions | Business API secret reads; Products writes photos; Invoice writes invoices; LiveDocs reads reports |
| Frontend hosting | Static Web Apps Free; East US 2 by default; Angular is not deployed yet |
| Optional Products smoke deployment | Pinned public image, internal ACA ingress, Key Vault SQL secret, and SQL-only access; see [the deployment guide](docs/products-smoke-deployment.md) |

The signed-in operator receives Blob Data Contributor and Key Vault Secrets Officer so they can upload demo files and populate secrets later. Use the same Azure identity for the first lifecycle checks.

Storage and Key Vault use authenticated public HTTPS endpoints. Private Blob containers do not permit anonymous reads. The databases also use public endpoints, but have **no firewall rules by default**. An optional `operator_ipv4` adds exactly one address to each database for local connections. Opting into Products prepares separate SQL rules for the ACA platform and, optionally, the migration laptop without opening Mongo access.

The default foundation creates no business Container Apps. The optional Products rollout deploys only Products and includes a local EF migration helper. There are no verification jobs, scheduled workers, Docker builds, GitHub workflows, NAT gateways, private endpoints, dedicated compute profiles or Log Analytics workspaces. Database driver/transaction compatibility still requires live Azure verification.

## Prerequisites

- Terraform **1.16.x**; development uses **1.16.5**. `.terraform-version` is a version-manager hint, not an installer.
- Azure CLI on PATH, signed in to the intended subscription.
- Independent state account `stecomtfstatemb261011` with a private `tfstate` container. Your CLI user needs **Storage Blob Data Contributor** on that account; subscription Owner alone does not grant Blob data access. Create and retain it outside this Terraform root.
- Permissions to create resources, register the required Azure services, assign roles and purge the disposable Key Vault. Subscription **Owner** is sufficient for this local development setup.
- SQL Free availability in **France Central**, as admitted for this subscription previously. Deleting a resource group does not reset the subscription's SQL Free region selection.
- No other DocumentDB Free cluster in this subscription: only one is allowed. Run dev and portfolio one at a time.

Terraform registers only the eight Azure resource-provider namespaces this configuration uses. Registration changes subscription metadata; destruction removes the deployed resources, not those registrations.

## Local setup (PowerShell)

For an existing checkout, follow **State and the next steps** below before initialization. Do not overwrite your existing `terraform.tfvars`, delete state, or reuse a saved plan from before the backend change.

```powershell
git clone https://github.com/MichalBoczula/EcommerceECommerceStore.Terraform.git
if ($LASTEXITCODE -ne 0) { throw 'Git clone failed' }
Set-Location EcommerceECommerceStore.Terraform

az login
if ($LASTEXITCODE -ne 0) { throw 'Azure login failed' }

az account set --subscription '<your-subscription-id>'
if ($LASTEXITCODE -ne 0) { throw 'Azure subscription selection failed' }

$env:TF_VAR_subscription_id = az account show --query id --output tsv
if ($LASTEXITCODE -ne 0) { throw 'Azure account read failed' }

Copy-Item terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars if you need a different unique name_suffix.

$env:TF_VAR_sql_admin_password = [System.Net.NetworkCredential]::new(
    '', (Read-Host 'SQL administrator password' -AsSecureString)
).Password
$env:TF_VAR_mongo_admin_password = [System.Net.NetworkCredential]::new(
    '', (Read-Host 'Mongo administrator password' -AsSecureString)
).Password

terraform init
if ($LASTEXITCODE -ne 0) { throw 'Terraform init failed' }

terraform fmt -check
if ($LASTEXITCODE -ne 0) { throw 'Terraform formatting failed' }

terraform validate
if ($LASTEXITCODE -ne 0) { throw 'Terraform validation failed' }
```

Use two different passwords, 16-64 characters each, including uppercase, lowercase, a digit and a symbol. Keep them in your password manager and reuse them while managing this state. Re-enter the environment variables when opening a new PowerShell session; do not replace credentials merely to recover from a failed command.

An optional `operator_ipv4` must be your actual public IPv4. The commented documentation address in the example is not a working address.

### If your empty resource group already exists

After setup, import it once before planning. For the default dev name:

```powershell
terraform import azurerm_resource_group.main "/subscriptions/$env:TF_VAR_subscription_id/resourceGroups/rg-ecommerce-dev"
if ($LASTEXITCODE -ne 0) { throw 'Resource group import failed' }
```

Use the group name from your configuration if overridden. This root owns and destroys the imported group: it must contain only this disposable environment's resources.

## Plan and apply

```powershell
terraform plan '-out=deploy.tfplan'
if ($LASTEXITCODE -ne 0) { throw 'Terraform plan failed; no apply attempted' }

# Read the plan. The default configuration declares 28 managed resources.
# operator_ipv4 adds two firewall rules. The count differs if the group was imported.
terraform apply 'deploy.tfplan'
if ($LASTEXITCODE -ne 0) { throw 'Terraform apply failed; keep the state and inspect the Azure error' }

terraform output
```

Applying a saved plan executes it immediately; review the plan before the `apply` command. Passwords, connection strings and the Static Web Apps deployment token are not exported as outputs.

The SQL resource checks Azure's returned `useFreeLimit` and `freeLimitExhaustionBehavior`. Azure must confirm `true` and `AutoPause`. There is no automatic paid fallback. The output `databases.sql_free_offer_readback` shows those returned settings.

The SQL ARM body uses `sku.name = "GP_S_Gen5"` with `capacity = 2`, matching Azure's observed readback. A capacity-suffixed name such as `GP_S_Gen5_2` is normalized by Azure and can cause a repeated update on every plan. If this is the only remaining diff, update the configuration and run a fresh plan; another apply is not needed when the plan reports no changes.

Static Web Apps uses **East US 2** by default, independently of the foundation's **North Europe** and SQL's **France Central**. Set `static_web_app_location` in your local `terraform.tfvars` to choose another supported region. Its supported provisioning regions differ from the other services, and Azure can still reject a supported region for your subscription during apply. Static assets are globally distributed; this setting does not move the BFF or databases.

If Azure returns `RequestDisallowedByAzure` with `locationineligible`, follow [Microsoft's region-access guidance](https://learn.microsoft.com/en-us/azure/azure-resource-manager/troubleshooting/error-region-access-policy). West Europe currently restricts new customers. For a missing frontend, try `static_web_app_location = "eastus2"` in your existing local `terraform.tfvars`, then generate a fresh plan. Keep the chosen setting after a successful deployment: changing it for an existing Static Web App requires replacement. Do not change `location` or `sql_location` to recover from this frontend error.

If an apply fails after creating some resources, keep the same directory, state and passwords. Correct the configuration, generate a **new** saved plan and apply that plan. Terraform refreshes the resources already created and plans the remaining work; do not reuse the pre-failure saved plan. For a failure limited to frontend creation, expect a plan that creates the missing Static Web App with no replacements or destroys.

## Verify no changes

Run this after the first successful apply with the same configuration and credentials:

```powershell
terraform plan -detailed-exitcode
$planExit = $LASTEXITCODE
if ($planExit -eq 1) { throw 'Terraform plan failed' }
if ($planExit -eq 2) { throw 'Terraform still proposes changes; inspect them before continuing' }
if ($planExit -ne 0) { throw "Unexpected Terraform exit code: $planExit" }
```

Exit code `0` means the refreshed state matches the configuration. This Azure check must be performed locally; offline tests do not prove Azure deployment or application compatibility.

## Destroy and recreate

Destroy this disposable environment when the development session ends. It deletes databases, demo files, LiveDocs files, identities, frontend hosting and the vault. The vault is purged to allow reuse of its name. A persistent LiveDocs archive must be separated before storing reports you intend to retain.

```powershell
terraform plan -destroy '-out=destroy.tfplan'
if ($LASTEXITCODE -ne 0) { throw 'Destroy plan failed; no deletion attempted' }

# Read the destroy plan, then execute it.
terraform apply 'destroy.tfplan'
if ($LASTEXITCODE -ne 0) { throw 'Destroy failed; keep state and credentials, then inspect the Azure error' }

terraform state list
if ($LASTEXITCODE -ne 0) { throw 'State inspection failed' }
# No managed resource addresses should remain. Data source entries can remain.

# In the same directory, with the same settings/passwords:
terraform plan '-out=deploy.tfplan'
if ($LASTEXITCODE -ne 0) { throw 'Recreation plan failed' }
terraform apply 'deploy.tfplan'
if ($LASTEXITCODE -ne 0) { throw 'Recreation failed; keep the state' }
```

If Azure returns a transient deletion error, keep the state and rerun the destroy plan/apply after checking the error. Terraform refreshes what actually remains. Do not delete state files or remove resources from state to hide failed deletion. ACA's platform-managed resource group may take additional time to disappear; Azure owns its lifecycle.

## State and the next steps

`backend.tf` stores application state in the private Blob `tfstate/development.terraform.tfstate` in `stecomtfstatemb261011`. Here, `key` is the **Blob filename**, not a Storage account access key. Terraform authenticates through your local `az login` session using Microsoft Entra ID; no GitHub identity settings or account keys are required.

Create the state account manually in `rg-ecommerce-tfstate`. Standard StorageV2, LRS and Hot are suitable; Poland Central is independent of the application's region. Disable anonymous Blob access and Shared Key access, enable default Entra authorization in the portal, and assign your operator Blob Data Contributor. Blob versioning and seven-day Blob/container soft delete provide recovery options. This root does not create, import or destroy the state account, its resource group, container or permissions. Never import them into this application state.

Terraform reads and locks remote state during operations and persists changes automatically. Do not download, upload or import state before each plan/apply. Ordinary root destroy updates the remote state while retaining the independent state account. State and saved plans can contain passwords/tokens; keep them outside Git. Commit `.terraform.lock.hcl` to keep providers consistent on Windows and Linux.

### First connection from an existing checkout

Keep the same application directory and passwords. Back up any local application state before changing the backend. Do not migrate `bootstrap/terraform.tfstate`; it belonged to the reverted CI bootstrap, not the application foundation.

- **First deployment or fresh checkout:** use `terraform init` from the setup above.
- **Existing local application state:** back it up outside Git, then run `terraform init -migrate-state`. Review the source/destination and confirm the one-time copy to the new account.
- **Already connected to this exact account/container/key:** run ordinary `terraform init`; migration is unnecessary.
- **Still connected to the old CI backend or the old account was deleted:** stop and recover/inspect the application's authoritative state before switching. If the old backend is accessible, use `terraform init -migrate-state` to transfer its state. Do not use `-reconfigure` to silently start an empty state while application resources still exist.

After cleanup performed outside Terraform, retain the old state: a fresh plan normally refreshes the state and recognizes deleted resources. Inspect that plan before applying. If the old backend is inaccessible, preserve local state/backups and establish what remains in Azure before recovery. Do not discard state to hide a failed deletion.

```powershell
# Only when migrating valid local application state:
terraform init -migrate-state
if ($LASTEXITCODE -ne 0) { throw 'Backend migration failed; retain state and backups' }

terraform state list
if ($LASTEXITCODE -ne 0) { throw 'State inspection failed' }

# Review a fresh plan after migration; do not apply an old saved plan.
terraform plan '-out=deploy.tfplan'
if ($LASTEXITCODE -ne 0) { throw 'Planning failed; no apply attempted' }
```

For an existing live deployment, backend migration alone should not change Azure resources. A clean recreated environment will instead show the expected creates. Future sessions use the same backend and the ordinary local plan/apply/destroy commands above.

The earlier GitHub infrastructure CI/CD implementation was reverted. Deployment remains local with independent remote state. The first opt-in application rollout is [Products with the existing SQL database](docs/products-smoke-deployment.md); infrastructure automation and the remaining applications are deferred.

Terraform owns the Products image reference when its rollout is enabled. BFF and LiveDocs will have public HTTPS ingress; Products, Users, Invoice and Payments have or will have internal ingress. Stripe will call the BFF webhook, not a database endpoint.

## Local configuration tests

These use Terraform's mock providers and make no Azure calls:

```powershell
terraform test
if ($LASTEXITCODE -ne 0) { throw 'Terraform tests failed' }
```

They check the free cost settings, private storage, scoped application permissions, opt-in Products stages and explicit database firewall addresses. The migration helper has separate offline checks:

```powershell
powershell -NoProfile -File tests/Test-InitializeProductsDatabase.ps1
```

The live lifecycle and Products smoke checks remain the acceptance criteria; mocks do not prove Azure connectivity.

## Cost

One custom-VNet external ACA environment creates managed public IP/load-balancer resources billed even with zero application replicas. The estimate is about **EUR 1.85 for 60 deployed hours** or **EUR 22.48 for 730 hours**, before VAT and traffic. Storage and Key Vault operations add small usage charges. The free database/frontend configurations are fixed in the resource definitions; changing a tier requires a reviewed code change. The default foundation has no application compute. The optional Products smoke stage keeps one 0.25-vCPU / 0.5-GiB replica running; Consumption compute and SQL usage remain subject to their free allowances and billing limits.

## References

- [Terraform Azure backend and state locking](https://developer.hashicorp.com/terraform/language/backend/azurerm)
- [Applying a saved plan](https://developer.hashicorp.com/terraform/cli/commands/apply)
- [Migrating backend state](https://developer.hashicorp.com/terraform/cli/commands/init)
- [Azure SQL Free offer and pause-at-limit behavior](https://learn.microsoft.com/en-us/azure/azure-sql/database/free-offer)
- [SQL Free settings in the ARM API](https://learn.microsoft.com/en-us/azure/templates/microsoft.sql/2023-08-01/servers/databases)
- [DocumentDB Free restrictions](https://learn.microsoft.com/en-us/azure/documentdb/free-tier)
- [ACA custom-VNet managed resources and costs](https://learn.microsoft.com/en-us/azure/container-apps/custom-virtual-networks)
