# ECommerceStore Terraform

Step 1: provision and remove the Azure foundation locally with ordinary Terraform commands.

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

The signed-in operator receives Blob Data Contributor and Key Vault Secrets Officer so they can upload demo files and populate secrets later. Use the same Azure identity for the first lifecycle checks.

Storage and Key Vault use authenticated public HTTPS endpoints. Private Blob containers do not permit anonymous reads. The databases also use public endpoints, but have **no firewall rules by default**. An optional `operator_ipv4` adds exactly one address to each database for local connections. ACA database access is part of step 5, when applications are deployed.

There are no business Container Apps, verification jobs, scheduled workers, Docker builds, deployment scripts, GitHub workflows, NAT gateways, private endpoints, dedicated compute profiles or Log Analytics workspaces in this step. Database driver/transaction compatibility is still unverified in Azure.

## Prerequisites

- Terraform **1.16.x**; development uses **1.16.5**. `.terraform-version` is a version-manager hint, not an installer.
- Azure CLI on PATH, signed in to the intended subscription.
- Permissions to create resources, register the required Azure services, assign roles and purge the disposable Key Vault. Subscription **Owner** is sufficient for this local development setup.
- SQL Free availability in **France Central**, as admitted for this subscription previously. Deleting a resource group does not reset the subscription's SQL Free region selection.
- No other DocumentDB Free cluster in this subscription: only one is allowed. Run dev and portfolio one at a time.

Terraform registers only the eight Azure resource-provider namespaces this configuration uses. Registration changes subscription metadata; destruction removes the deployed resources, not those registrations.

## Local setup (PowerShell)

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

If Azure returns a transient deletion error, keep the local state and rerun the destroy plan/apply after checking the error. Terraform refreshes what actually remains. Do not delete state files or remove resources from state to hide failed deletion. ACA's platform-managed resource group may take additional time to disappear; Azure owns its lifecycle.

## State and the next steps

Step 1 stores state in **local `terraform.tfstate`**, which survives `terraform destroy`. State and saved plans can contain passwords and tokens; keep them outside Git. `.gitignore` excludes them and personal `.tfvars` files. Commit `.terraform.lock.hcl` so provider versions/checksums stay consistent on Windows and Linux.

Before step 2, move the current state to Azure Blob Storage with `terraform init -migrate-state`. If the backend shares the business Storage account temporarily, first separate that account, its state container, resource group and backend access permissions from this root's destroy lifecycle. **Do not point this root's backend at the account it currently destroys.** Step 4 will migrate the backend to its own account.

| Step | Scope |
| --- | --- |
| 1 | Local Terraform; apply, no-change plan, destroy, recreate |
| 2 | Remote state and manual infrastructure CI/CD actions: plan, apply, destroy |
| 3 | Combine saved plan and apply in one workflow; serialize state mutations |
| 4 | Migrate state to a dedicated persistent Storage account |
| 5 | Deploy pinned Docker Hub images, connect apps/databases, populate secrets, deploy Angular and smoke-test a business flow |

Terraform will own application image references in step 5. BFF and LiveDocs will have public HTTPS ingress; Products, Users, Invoice and Payments will have internal ingress. Stripe will call the BFF webhook, not a database endpoint.

## Local configuration tests

These use Terraform's mock providers and make no Azure calls:

```powershell
terraform test
if ($LASTEXITCODE -ne 0) { throw 'Terraform tests failed' }
```

They check the free cost settings, private storage, scoped application permissions and explicit database firewall addresses. The live lifecycle checks above remain the acceptance criteria for step 1.

## Cost

One custom-VNet external ACA environment creates managed public IP/load-balancer resources billed even with zero application replicas. The estimate is about **EUR 1.85 for 60 deployed hours** or **EUR 22.48 for 730 hours**, before VAT and traffic. Storage and Key Vault operations add small usage charges. The free database/frontend configurations are fixed in the resource definitions; changing a tier requires a reviewed code change. No application compute is deployed in step 1.

## References

- [Terraform Azure backend and state locking](https://developer.hashicorp.com/terraform/language/backend/azurerm)
- [Applying a saved plan](https://developer.hashicorp.com/terraform/cli/commands/apply)
- [Migrating backend state](https://developer.hashicorp.com/terraform/cli/commands/init)
- [Azure SQL Free offer and pause-at-limit behavior](https://learn.microsoft.com/en-us/azure/azure-sql/database/free-offer)
- [SQL Free settings in the ARM API](https://learn.microsoft.com/en-us/azure/templates/microsoft.sql/2023-08-01/servers/databases)
- [DocumentDB Free restrictions](https://learn.microsoft.com/en-us/azure/documentdb/free-tier)
- [ACA custom-VNet managed resources and costs](https://learn.microsoft.com/en-us/azure/container-apps/custom-virtual-networks)
