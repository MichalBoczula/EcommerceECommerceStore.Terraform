# ECommerceStore Terraform

Provision a disposable Azure development environment with ordinary Terraform commands or manually triggered GitHub Actions. This repository replaces the deprecated Infrastructure repository.

Step 1 is marked complete. Step 2 implements remote state and manual infrastructure CI/CD; live workflow acceptance is still pending.

## Resource ownership

| Configuration | Owns | Lifecycle |
| --- | --- | --- |
| `bootstrap/` | Shared resource group, Standard Hot LRS Storage account, private `tfstate`/`tfplans` containers, operator Blob access, GitHub CI identity/federation and CI roles | Persistent; operator-managed local state |
| Repository root | VNet, ACA environment, databases, business Blob containers, vault, application identities/roles and frontend hosting | Disposable; Azure Blob remote state |

Until step 4, state and business files share one Storage account. The main resource group and this account are retained when the root is destroyed. Bootstrap protects both with `prevent_destroy`; do not run bootstrap destroy as part of the demo lifecycle. Keep its separate local state outside Git.

The ACA environment also causes Azure to create `rg-ecom-dev-aca-managed` for platform networking. Azure manages that group and removes it with the environment.

## Foundation

| Resource | Configuration |
| --- | --- |
| Network | One VNet, one delegated `/27` ACA subnet |
| Container Apps environment | External, Consumption workload profile, streamed logs |
| Products database | Azure SQL Free, 32 GiB, `AutoPause` when the free limit is exhausted |
| Users / Invoice / Payments database server | One Azure DocumentDB Mongo-compatible Free cluster, 32 GiB, native authentication |
| Business files | Private `photos`, `invoices`, `livedocs`; Entra access on the shared account |
| Key Vault | Standard, RBAC authorization; disposable and purged on destroy |
| Managed identities | Products, Users, Invoice, Payments, BFF and LiveDocs |
| Permissions | Business APIs read secrets; Products writes photos; Invoice writes invoices; LiveDocs reads reports |
| Frontend | Static Web Apps Free; East US 2 by default; Angular deployment comes in step 5 |

Databases have public endpoints with no firewall rules by default. Optional `operator_ipv4` permits exactly one local address in each database. Storage and Key Vault use authenticated public HTTPS endpoints. No application containers, workers, verification jobs, NAT gateways, private endpoints, dedicated compute or Log Analytics are deployed yet. Database/application compatibility remains a step-5 check.

## Start here

Follow [the step-2 setup guide](docs/infrastructure-cicd.md) to create bootstrap, initialize remote state, configure the GitHub environment and run the manual workflow. The rollout assumes the step-1 environment has already been destroyed; active-state upgrades need an explicit ownership migration.

Requirements: Terraform **1.16.x** (pinned development version **1.16.5**), Azure CLI, subscription access to the SQL Free offer in France Central, and no competing DocumentDB Free cluster. Bootstrap needs permission to register providers and assign its documented Azure roles; a subscription Owner can perform the initial setup.

Both provider versions are locked: AzureRM **5.8.0**, AzAPI **2.13.0**. Commit the lockfiles and keep state, saved plans, personal tfvars and credentials outside Git.

## Local commands after setup

With remote state initialized and the same configuration/passwords as CI:

```powershell
terraform fmt -check -recursive
if ($LASTEXITCODE -ne 0) { throw 'Formatting failed' }
terraform validate
if ($LASTEXITCODE -ne 0) { throw 'Validation failed' }
terraform test
if ($LASTEXITCODE -ne 0) { throw 'Tests failed' }
terraform plan '-out=deploy.tfplan'
if ($LASTEXITCODE -ne 0) { throw 'Planning failed' }
```

Review the saved plan, then apply it:

```powershell
terraform apply 'deploy.tfplan'
if ($LASTEXITCODE -ne 0) { throw 'Apply failed; retain state and credentials' }
terraform plan -detailed-exitcode
$planExit = $LASTEXITCODE
if ($planExit -eq 1) { throw 'Planning failed' }
if ($planExit -eq 2) { throw 'Terraform proposes changes; inspect them' }
```

For teardown, plan with `terraform plan -destroy '-out=destroy.tfplan'`, check the exit code, review it and apply `terraform apply 'destroy.tfplan'`. This removes the disposable resources and business files, while retaining bootstrap and state. Recreate by generating a new deployment plan with the same passwords/settings. Never reuse a saved plan after a failed apply or after state changes.

The SQL ARM body uses `GP_S_Gen5` with capacity 2, matching observed Azure readback. The SQL postcondition verifies Azure returned `useFreeLimit = true` and `freeLimitExhaustionBehavior = "AutoPause"`; there is no paid fallback.

SWA supports different provisioning regions from ACA. `static_web_app_location` controls only the frontend. West Europe can reject new customers; this environment successfully used East US 2. Keep the successful region setting across recreation. If Azure creates an SWA but Terraform loses its readback, inspect Azure and state first, then import the existing app if missing from state.

## CI/CD

- **Terraform checks**: automatic formatting, validation, mock Terraform tests and saved-plan handoff tests; no Azure credentials.
- **Infrastructure lifecycle**: manual `plan`, `apply` or `destroy` on `main`, using the `development` environment and GitHub OIDC.
- **Plan** writes its saved plan and matching metadata to private Azure Blob Storage.
- **Apply** takes a successful plan run ID, verifies source commit/settings/passwords/file integrity and applies that exact plan.
- **Destroy** generates and applies its own teardown plan. GitHub concurrency and Blob state locking serialize the workflow operations.

The repository is public, so confidential saved plans are not uploaded as GitHub artifacts. Plan metadata expires after 24 hours; old private blobs can be removed separately. Application builds and deployment are deferred to step 5.

## Roadmap

| Step | Status | Work | Done when |
| --- | --- | --- | --- |
| 1. Working Terraform locally | Done | Ordinary local Terraform lifecycle | Apply succeeds, second plan is unchanged, destroy/recreate works |
| 2. Infrastructure CI/CD | In progress | Manual plan/apply/destroy with remote state | GitHub Actions completes the laptop lifecycle |
| 3. Combine plan + apply | Todo | Generate and apply the exact saved plan in one run | One infrastructure deployment run; separate manual destroy |
| 4. Separate state storage | Todo | Move state to a dedicated persistent Storage account | Migration succeeds; next plan has no infrastructure changes |
| 5. Deploy our images | Todo | Docker Hub digests, app configuration and Angular deployment | Apps start and a basic business flow works |

Application repos test/build/publish images. This Terraform repo selects backend image versions and will manage their deployment. The Angular repo deploys compiled website files to the hosting resource created here.

## Costs and references

Custom-VNet ACA creates billed networking resources even with no app replicas. Retained Standard LRS Storage also incurs usage charges; it is not deleted with the disposable environment. Database and frontend Free configurations remain fixed in code.

- [Azure Blob backend and state locking](https://developer.hashicorp.com/terraform/language/backend/azurerm)
- [GitHub OIDC to Azure](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect)
- [ACA managed networking](https://learn.microsoft.com/en-us/azure/container-apps/custom-virtual-networks)
- [Azure SQL Free offer](https://learn.microsoft.com/en-us/azure/azure-sql/database/free-offer)
- [SWA region eligibility](https://learn.microsoft.com/en-us/azure/azure-resource-manager/troubleshooting/error-region-access-policy)
