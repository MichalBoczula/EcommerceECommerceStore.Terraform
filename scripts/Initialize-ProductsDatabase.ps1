[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ProductsPath,
    [string] $TerraformPath = 'terraform'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$terraformRoot = Split-Path -Parent $PSScriptRoot
$productsRoot = (Resolve-Path -LiteralPath $ProductsPath).Path

foreach ($tool in @('git', 'az', 'dotnet', $TerraformPath)) {
    $null = Get-Command $tool -ErrorAction Stop
}

$deploymentJson = & $TerraformPath "-chdir=$terraformRoot" output -json products_deployment
if ($LASTEXITCODE -ne 0) { throw 'Cannot read the applied Products preparation outputs.' }
$deployment = ($deploymentJson -join "`n") | ConvertFrom-Json
if ($null -eq $deployment -or $deployment.stage -ne 'prepare') {
    throw 'Apply the Products prepare stage before running database migrations.'
}
if ([string]::IsNullOrWhiteSpace($deployment.migration_ipv4)) {
    throw 'The applied configuration has no public IPv4 for local database migrations.'
}

$sourceCommit = & git -C $productsRoot rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'ProductsPath must be a ProductsCatalog Git checkout.' }
if (($sourceCommit -join '').Trim() -cne $deployment.source_commit) {
    throw "Check out ProductsCatalog commit $($deployment.source_commit) to match the selected container image."
}
$sourceChanges = & git -C $productsRoot status --porcelain --untracked-files=all
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the ProductsCatalog working tree.' }
if ($sourceChanges) { throw 'Use a clean ProductsCatalog checkout so migrations match the published image.' }

$apiProject = Join-Path $productsRoot 'src/ProductCatalog.Api/ProductCatalog.Api.csproj'
$infraProject = Join-Path $productsRoot 'src/ProductCatalog.Infrastructure/ProductCatalog.Infrastructure.csproj'
if (!(Test-Path -LiteralPath $apiProject) -or !(Test-Path -LiteralPath $infraProject)) {
    throw 'ProductsPath does not contain the expected ProductsCatalog projects.'
}

$subscription = & az account show --query id --output tsv
if ($LASTEXITCODE -ne 0) { throw 'Cannot read the current Azure CLI subscription.' }
if (($subscription -join '').Trim() -ine $deployment.subscription_id) {
    throw 'Select the same Azure CLI subscription used by this Terraform deployment.'
}

$originalConnection = [Environment]::GetEnvironmentVariable('ConnectionStrings__ProductCatalogDb', 'Process')
$originalMigrationFlag = [Environment]::GetEnvironmentVariable('Database__ApplyMigrations', 'Process')
$toolDirectory = Join-Path ([IO.Path]::GetTempPath()) ('ecommerce-ef-' + [Guid]::NewGuid().ToString('N'))
try {
    # Capture the value without printing it or putting credentials in arguments.
    $connection = & az keyvault secret show --id $deployment.sql_connection_secret_id --query value --output tsv
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read the Products SQL secret using your operator identity.' }
    $connection = ($connection -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($connection)) { throw 'The Products SQL secret is empty.' }
    [Environment]::SetEnvironmentVariable('ConnectionStrings__ProductCatalogDb', $connection, 'Process')
    [Environment]::SetEnvironmentVariable('Database__ApplyMigrations', 'false', 'Process')

    Push-Location $productsRoot
    try {
        # Match this release's EF Core 10.0.1 without changing global tools.
        & dotnet tool install dotnet-ef --version 10.0.1 --tool-path $toolDirectory
        if ($LASTEXITCODE -ne 0) { throw 'EF Core tool installation failed.' }
        $efName = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { 'dotnet-ef.exe' } else { 'dotnet-ef' }
        $efTool = Join-Path $toolDirectory $efName

        & $efTool database update --project $infraProject --startup-project $apiProject --configuration Release
        if ($LASTEXITCODE -ne 0) {
            throw 'Products migration failed. Keep state/passwords, inspect SQL connectivity or the migration error, and rerun after fixing it.'
        }
    }
    finally { Pop-Location }

    Write-Host 'Products migrations completed. Change products.stage to run, then generate and review a fresh Terraform plan.'
}
finally {
    [Environment]::SetEnvironmentVariable('ConnectionStrings__ProductCatalogDb', $originalConnection, 'Process')
    [Environment]::SetEnvironmentVariable('Database__ApplyMigrations', $originalMigrationFlag, 'Process')
    $connection = $null
    if (Test-Path -LiteralPath $toolDirectory) { Remove-Item -LiteralPath $toolDirectory -Recurse -Force }
}
