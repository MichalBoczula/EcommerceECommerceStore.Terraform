# Products and SQL: first application smoke deployment

Deploy only the existing ProductsCatalog API to the already-applied foundation.
Terraform runs locally and continues using the foundation's existing Blob backend.
Keep the same foundation inputs, SQL/Mongo passwords and operator identity.

The first release is pinned to:

- Source: [`5fa6966327dbc7894ce8156cf222b28a0cdf52f5`](https://github.com/MichalBoczula/ProductsCatalog/commit/5fa6966327dbc7894ce8156cf222b28a0cdf52f5).
- Image: `mb0101/product-catalog-api@sha256:8ebff9865f56bf4c073417fa1ebdc3d0748b8a9a565f30f3f9afbf4705fa90fc`.
- Successful producer [CI run 37360409392](https://github.com/MichalBoczula/ProductsCatalog/actions/runs/37360409392), including image build, scan and publication.

Anonymous Docker Hub pull was verified for this digest. `DOCKERHUB_USERNAME` and
`DOCKERHUB_TOKEN` are used by ProductsCatalog's image-publishing GitHub Actions
workflow; local Terraform does not read GitHub secrets. This public image requires
no registry credentials in Azure. A private image needs an explicit registry
credential configuration before being selected.

## Deployment order

| Configuration | Behavior |
| --- | --- |
| `products` omitted / `null` | The original 28-resource foundation; no API or Products SQL rules/secret |
| `products.stage = "prepare"` | SQL firewall rules and Key Vault connection secret; API absent |
| Local migration command | Apply this source commit's EF migrations and seed once to the existing `products` database |
| `products.stage = "run"` | One small Products replica with runtime migrations disabled and internal ingress |

The separate preparation stage prevents deploying a SQL readiness probe against
an unmigrated database. Review every saved plan before applying; subsequent
sessions must retain `products.auto.tfvars`, otherwise Terraform proposes removal
of the optional resources.

The preparation reads **all attached, allocated static public IPs** from the ACA
environment's existing managed resource group and creates one exact SQL firewall
rule per unique address. This includes the platform's ingress address as well as
its egress addresses; it avoids mistaking the environment's inbound `static_ip_address`
for a complete egress allowlist. Those platform resources remain Azure-owned.
The plan fails if the read yields no addresses. Apply the foundation first so its
managed addresses exist and are known during planning. No Azure-wide `0.0.0.0`
rule, NAT gateway, SQL tier change or environment replacement is introduced.
Verify the running API's SQL readiness in Azure: IP enumeration alone is not
proof of connectivity. Re-plan if the platform's addresses change.

The SQL connection uses encryption and certificate validation. Terraform writes
it to Key Vault, then ACA retrieves it through the existing Products managed
identity. This disposable test uses the existing SQL administrator for both
migrations and runtime. A persistent or multi-app rollout must first introduce
a contained runtime user with only the required data permissions. The secret is
also present in protected Terraform state/plans; it is not a Terraform output.

## 1. Prepare SQL access and the secret

In the existing Terraform directory, after pulling the merged change:

```powershell
$ecommerceTerraform = Join-Path $env:LOCALAPPDATA 'Programs\Terraform\1.16.5\terraform.exe'
if (!(Test-Path $ecommerceTerraform)) { throw 'Terraform 1.16.5 was not found' }

if (!(Test-Path 'products.auto.tfvars')) {
    Copy-Item products.tfvars.example products.auto.tfvars
}
# Edit products.auto.tfvars: set migration_ipv4 to your actual public IPv4.
# Keep stage = "prepare". Preserve your existing terraform.tfvars.

& $ecommerceTerraform init
if ($LASTEXITCODE -ne 0) { throw 'Terraform init failed' }
& $ecommerceTerraform fmt
if ($LASTEXITCODE -ne 0) { throw 'Terraform formatting failed' }
& $ecommerceTerraform validate
if ($LASTEXITCODE -ne 0) { throw 'Terraform validation failed' }
& $ecommerceTerraform test
if ($LASTEXITCODE -ne 0) { throw 'Offline Terraform tests failed' }

& $ecommerceTerraform plan '-input=false' '-out=products-prepare.tfplan'
if ($LASTEXITCODE -ne 0) { throw 'Preparation plan failed' }
# Inspect: Products SQL rules + one Key Vault secret; no API, replacements or unrelated changes.
& $ecommerceTerraform apply 'products-prepare.tfplan'
if ($LASTEXITCODE -ne 0) { throw 'Preparation failed; retain state/passwords and inspect the error' }
& $ecommerceTerraform output products_deployment
```

Use your actual migration IPv4, not a documentation address. If `operator_ipv4`
already allows your laptop, `migration_ipv4` can remain null; that existing setting
also allows Mongo access. Prefer the Products-specific migration IP for this test.

Key Vault RBAC or SQL firewall changes can take time to propagate. If preparation
or the migration fails, inspect the error and retry the failed stage after the
cause is corrected. Keep state and credentials and generate a fresh plan after
an unsuccessful apply.

## 2. Apply Products migrations locally

Prerequisites: .NET SDK 10.0.100 or a newer .NET 10 feature band, Git, Azure CLI,
PowerShell, and local network access to Azure SQL on TCP 1433. Use a clean source
checkout pinned to the image's commit. Keep your development checkout separate:

```powershell
git clone https://github.com/MichalBoczula/ProductsCatalog.git ..\ProductsCatalog-smoke
if ($LASTEXITCODE -ne 0) { throw 'Products source clone failed' }
git -C ..\ProductsCatalog-smoke checkout --detach 5fa6966327dbc7894ce8156cf222b28a0cdf52f5
if ($LASTEXITCODE -ne 0) { throw 'Products source checkout failed' }

.\scripts\Initialize-ProductsDatabase.ps1 `
    -TerraformPath $ecommerceTerraform `
    -ProductsPath ..\ProductsCatalog-smoke
```

If that directory already exists, reuse it only if it is a clean ProductsCatalog
checkout at the expected commit. The helper checks source cleanliness, the applied
prepare stage and Azure subscription before reading the SQL secret. It installs
EF Core 10.0.1 temporarily, runs `database update` against the existing database,
then restores environment variables and removes its temporary tool directory.
It never passes the connection string in command arguments or prints it.
Repeated successful execution uses EF's migration history; the API never performs
migrations during startup. A migration error stops the command without retrying
the whole migration automatically. This first smoke test targets a new disposable
database; upgrading an existing populated catalogue requires a separate migration review.

## 3. Start Products

After the migration command succeeds, edit `products.auto.tfvars`:

```hcl
# Keep the same image and source_commit.
stage          = "run"
migration_ipv4 = null
```

Removing `migration_ipv4` closes the Products-specific laptop rule. If you still
need laptop access for SQL diagnostics, keep the same IP temporarily.

```powershell
& $ecommerceTerraform plan '-input=false' '-out=products-run.tfplan'
if ($LASTEXITCODE -ne 0) { throw 'Products plan failed' }
# Expect one Container App addition; removing migration_ipv4 deletes only its laptop rule.
# No database, environment or foundation resource should be replaced.
& $ecommerceTerraform apply 'products-run.tfplan'
if ($LASTEXITCODE -ne 0) { throw 'Products apply failed; keep state/passwords and inspect the error' }

& $ecommerceTerraform plan '-input=false' '-detailed-exitcode'
$productsPlanExit = $LASTEXITCODE
if ($productsPlanExit -ne 0) { throw "Expected no changes; Terraform returned $productsPlanExit" }

$productsDeployment = (& $ecommerceTerraform output -json products_deployment) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Cannot read Products outputs' }
az containerapp show --resource-group $productsDeployment.resource_group_name `
    --name $productsDeployment.container_app_name `
    --query '{state:properties.provisioningState,revision:properties.latestRevisionName,running:properties.runningStatus}' --output json
az containerapp logs show --resource-group $productsDeployment.resource_group_name `
    --name $productsDeployment.container_app_name --type console --tail 100
```

## 4. Verify HTTP and SQL from inside the container

Products ingress is internal to ACA; its URL cannot be opened from a laptop's
browser. Enter the running Linux container through the Azure CLI:

```powershell
az containerapp exec --resource-group $productsDeployment.resource_group_name `
    --name $productsDeployment.container_app_name --container products --command /bin/bash
```

In that **container Bash console**, paste this read-only smoke test. It uses Bash
and coreutils because the API image does not install curl:

```bash
for route in /health/live /health/ready '/mobile-phones?amount=3'; do
  printf '\n%s\n' "$route"
  timeout 20 bash -c '
    exec 3<>/dev/tcp/127.0.0.1/8080
    printf "GET %s HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" "$1" >&3
    cat <&3
  ' -- "$route" || break
done
```

All three responses must be `HTTP/1.1 200 OK`. The readiness response verifies
SQL and the current/history tables; the product read exercises Dapper and should
return seeded phones on a fresh database. This does not yet test BFF routing,
browser access, CRUD/history behavior or the other services. Preserve the results
before claiming Azure compatibility.

A `503` readiness response means SQL/schema access is not ready. Inspect console
logs and the platform addresses in `products_deployment`, verify the migrations
succeeded against the correct database, and account for SQL Free resume/limit
behavior. Liveness remains independent of SQL so a database pause does not
restart the API repeatedly. If ACA reports Key Vault resolution errors, inspect
the Products identity's Secrets User assignment and RBAC propagation.

## Stop the test

Set `products = null` (or remove the object), then generate and review a fresh plan
to remove the optional API, Products SQL rules and connection secret. This keeps
the foundation and database/data. A whole-root destroy still removes the entire
disposable environment while retaining the independent backend account. Avoid
manually changing the image/ingress in Azure: Terraform owns that configuration.
