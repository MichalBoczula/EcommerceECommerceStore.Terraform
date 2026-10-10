# Step 2: manual infrastructure CI/CD

This setup starts from the destroyed step-1 environment. It retains one shared business/state Storage account and the resource group in a small operator-run bootstrap root. Step 4 still creates a separate account for state. The GitHub workflow never applies or destroys bootstrap.

## 1. Create persistent bootstrap locally

Before updating, inspect your current `terraform state list`: no managed step-1 resources should remain. Data source entries can remain. If resources are still managed, retain that state and configuration; do not apply this ownership change directly. Existing environments need a planned transfer of the group/account/operator role to bootstrap.

From the repository directory, update `main`, then run:

```powershell
git pull --ff-only
if ($LASTEXITCODE -ne 0) { throw 'Git update failed' }
az login
if ($LASTEXITCODE -ne 0) { throw 'Azure login failed' }
az account set --subscription '<your-subscription-id>'
if ($LASTEXITCODE -ne 0) { throw 'Subscription selection failed' }
$env:TF_VAR_subscription_id = az account show --query id --output tsv
if ($LASTEXITCODE -ne 0) { throw 'Account read failed' }

Copy-Item bootstrap/terraform.tfvars.example bootstrap/terraform.tfvars
# Edit environment/name_suffix/location/group if your step-1 settings differed.
terraform -chdir=bootstrap init
if ($LASTEXITCODE -ne 0) { throw 'Bootstrap init failed' }
terraform -chdir=bootstrap validate
if ($LASTEXITCODE -ne 0) { throw 'Bootstrap validation failed' }
terraform -chdir=bootstrap test
if ($LASTEXITCODE -ne 0) { throw 'Bootstrap tests failed' }
terraform -chdir=bootstrap plan '-out=bootstrap.tfplan'
if ($LASTEXITCODE -ne 0) { throw 'Bootstrap planning failed' }
```

Review, then execute:

```powershell
terraform -chdir=bootstrap apply 'bootstrap.tfplan'
if ($LASTEXITCODE -ne 0) { throw 'Bootstrap apply failed; retain its local state' }
$bootstrapJson = terraform -chdir=bootstrap output -json setup
if ($LASTEXITCODE -ne 0) { throw 'Bootstrap output failed' }
$setup = $bootstrapJson | ConvertFrom-Json
$env:TF_VAR_operator_object_id = $setup.operator_object_id
$setup
```

Bootstrap registers the eight providers needed by the foundation. It grants the human operator Blob Data Contributor on the shared account. Its CI managed identity receives Contributor and Role Based Access Control Administrator on the resource group, Blob Data Contributor on the shared account, and Key Vault Purge Operator at subscription scope (deleted vault purge endpoints live outside the group). The role-management permission is needed for the application's managed identities/RBAC. The purge permission preserves the disposable vault recreation behavior.

If an empty group already exists, import that group into **bootstrap**, not the foundation. If storage or any other bootstrap object exists and is managed elsewhere, resolve ownership before importing. Initial Blob RBAC assignments may need time to propagate; on authorization failures, retain state and retry after confirming the role is effective. Do not enable shared keys or anonymous access to bypass this.

Keep `bootstrap/terraform.tfstate` backed up outside Git. It holds the persistent resources and is not part of the ordinary destroy workflow.

## 2. Initialize the root's remote state

Keep the existing root `terraform.tfvars`; compare it with the example and bootstrap settings. Add `operator_object_id` from bootstrap output if you prefer a file over the environment variable. The same human UUID is used locally and in CI so changing execution identity does not change operator roles.

```powershell
Copy-Item backend.hcl.example backend.hcl
# Set storage_account_name to $setup.storage_account in backend.hcl.
# container_name=tfstate; key=development.terraform.tfstate for the dev workflow.

terraform init -migrate-state '-backend-config=backend.hcl'
if ($LASTEXITCODE -ne 0) { throw 'Remote-state initialization/migration failed' }
```

When prompted, migrate the existing local state. Even after a complete destroy, it may contain data source entries. If there is no prior state, this initializes an empty backend. If the destination already contains state, inspect it before choosing any overwrite/migration option. Do not use force-copy or discard local state to resolve a conflict.

For later local sessions, sign in with Azure CLI and initialize using the same `backend.hcl`. Set `TF_VAR_subscription_id` and `TF_VAR_operator_object_id`, and restore the same database passwords:

```powershell
$env:TF_VAR_sql_admin_password = [System.Net.NetworkCredential]::new(
    '', (Read-Host 'SQL administrator password' -AsSecureString)
).Password
$env:TF_VAR_mongo_admin_password = [System.Net.NetworkCredential]::new(
    '', (Read-Host 'Mongo administrator password' -AsSecureString)
).Password

terraform validate
if ($LASTEXITCODE -ne 0) { throw 'Foundation validation failed' }
terraform test
if ($LASTEXITCODE -ne 0) { throw 'Foundation tests failed' }
```

Reuse passwords from step 1, each 16-64 characters with uppercase, lowercase, a digit and a symbol. Passwords can be present in Terraform state and saved plans; the Blob containers are private and access uses Entra. Never commit passwords, state or saved plans.

## 3. Configure GitHub once

In this repository's Settings -> Environments, create **development**. Restrict its deployment branches to **main** using selected deployment branches. Bootstrap's federation subject is exactly `repo:MichalBoczula/EcommerceECommerceStore.Terraform:environment:development`; changing the repository/environment name requires updating the federated credential.

Add the following environment **variables** using bootstrap output:

| GitHub variable | Bootstrap output |
| --- | --- |
| `AZURE_SUBSCRIPTION_ID` | `subscription_id` |
| `AZURE_TENANT_ID` | `tenant_id` |
| `AZURE_CLIENT_ID` | `client_id` (CI identity, not the operator) |
| `STATE_ACCOUNT` | `storage_account` |
| `OPERATOR_OBJECT_ID` | `operator_object_id` (human operator, not CI identity) |

Optional variables must match your local/bootstrap settings if non-default:

| GitHub variable | Default |
| --- | --- |
| `NAME_SUFFIX` | `mike2026` |
| `LOCATION` | `northeurope` |
| `SQL_LOCATION` | `francecentral` |
| `STATIC_WEB_APP_LOCATION` | `eastus2` |
| `RESOURCE_GROUP_NAME` | `rg-ecommerce-dev` |
| `OPERATOR_IPV4` | Unset; no DB firewall rules |

Add these environment **secrets** from your password manager:

- `SQL_ADMIN_PASSWORD`: the same SQL password used locally.
- `MONGO_ADMIN_PASSWORD`: the same Mongo password used locally.

No Azure client secret, Storage key or Docker Hub secret is needed for this infrastructure step. GitHub exchanges its short-lived OIDC token for the bootstrap CI identity. Terraform state access uses Azure Blob locking and Entra authentication.

Protect `main` and require **Terraform checks / check** for changes to infrastructure/workflows. Anyone allowed to change the trusted workflow can change how its Azure permissions are used.

## 4. Run the manual lifecycle

Open Actions -> **Infrastructure lifecycle** -> Run workflow. Choose branch **main**.

| Action | Behavior |
| --- | --- |
| `plan` | Generates a saved deployment plan; stores it and metadata privately in `tfplans/<run-id>/`; prints the run ID in the job summary |
| `apply` | Takes `plan_run_id`; downloads and verifies that successful plan run and applies its exact saved plan |
| `destroy` | Generates and applies a teardown plan for the disposable root; bootstrap is retained |

Review the redacted plan in the successful plan run's logs, then start `apply` with its numeric run ID. It must be from the same workflow, main commit and configuration, and less than 24 hours old. The checks also reject changed passwords/identity/backend or changed plan bytes. Terraform rejects stale state plans itself. If any check fails, generate a new plan; do not override it. Applying a saved plan is immediate and does not ask for another Terraform confirmation.

Plans contain confidential data, so this public repository does **not** use GitHub artifacts for plan handoff. They are private Azure blobs. After a plan expires or has been used, the operator can delete its `tfplans/<run-id>/` blobs; keep the `tfstate` container and its state blob. The workflow removes temporary plan files from the runner even on failure.

GitHub concurrency serializes these runs, while Blob leases protect against simultaneous laptop operations. Pending GitHub concurrency runs can be superseded; do not rely on a queue of many runs. Avoid making local changes between a plan and its apply.

## Acceptance for step 2

1. CI `plan`, then manual `apply` using that run ID: creation succeeds.
2. CI `plan`: reports **No changes**.
3. Local `terraform plan -detailed-exitcode`: returns **0** with the same inputs.
4. CI `destroy`: disposable resources disappear; bootstrap/shared account/state remain.
5. CI `plan` + `apply`: recreation succeeds.
6. CI `plan`: reports **No changes** again.

Step 2 stays in progress until these live checks pass. Step 3 will combine the deployment plan and apply in one run. Step 4 will migrate state to a dedicated account without replacing the application's Storage account. Step 5 will add applications and pinned Docker Hub digests.
