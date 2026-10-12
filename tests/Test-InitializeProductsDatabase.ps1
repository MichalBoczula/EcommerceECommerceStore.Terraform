# Offline checks: every external command is replaced in this isolated process.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$migrationScript = Join-Path $repoRoot 'scripts/Initialize-ProductsDatabase.ps1'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('ecommerce-migration-test-' + [Guid]::NewGuid().ToString('N'))
$originalConnection = [Environment]::GetEnvironmentVariable('ConnectionStrings__ProductCatalogDb', 'Process')
$originalFlag = [Environment]::GetEnvironmentVariable('Database__ApplyMigrations', 'Process')
$originalLocation = (Get-Location).Path
$global:productsTestAliases = @()

function Assert-Condition([bool] $Condition, [string] $Message) {
    if (!$Condition) { throw $Message }
}

function global:terraform {
    $global:LASTEXITCODE = $global:productsTestState.OutputExit
    if ($global:LASTEXITCODE -eq 0) { $global:productsTestState.Deployment | ConvertTo-Json }
}

function global:git {
    $toolArgs = @($args)
    $global:LASTEXITCODE = 0
    if ($toolArgs -contains 'rev-parse') { $global:productsTestState.Commit }
    elseif ($toolArgs -contains 'status' -and $global:productsTestState.Dirty) { ' M src/ProductCatalog.Api/Program.cs' }
    else { }
}

function global:az {
    $toolArgs = @($args)
    $global:LASTEXITCODE = 0
    if ($toolArgs -contains 'account') { $global:productsTestState.Subscription }
    elseif ($toolArgs -contains 'keyvault') {
        $global:productsTestState.SecretReads++
        $global:LASTEXITCODE = $global:productsTestState.SecretExit
        if ($global:LASTEXITCODE -eq 0) { $global:productsTestState.Secret }
    }
    else { throw 'Unexpected Azure CLI command in migration helper.' }
}

function global:Invoke-ProductsTestEf {
    $toolArgs = @($args)
    Assert-Condition ($toolArgs[0] -eq 'database' -and $toolArgs[1] -eq 'update') 'Expected a dedicated EF database update.'
    Assert-Condition (!($toolArgs -contains '--connection')) 'Credentials must not be passed as command arguments.'
    Assert-Condition ($env:ConnectionStrings__ProductCatalogDb -ceq $global:productsTestState.Secret) 'EF must receive the selected secret through its environment.'
    Assert-Condition ($env:Database__ApplyMigrations -eq 'false') 'Runtime migration must stay disabled during EF design-time startup.'
    $global:productsTestState.MigrationCalls++
    $global:LASTEXITCODE = $global:productsTestState.MigrationExit
    'Fake EF migration executed.'
}

function global:dotnet {
    $toolArgs = @($args)
    Assert-Condition ($toolArgs[0] -eq 'tool' -and $toolArgs[1] -eq 'install') 'Only temporary tool installation is expected.'
    Assert-Condition ($toolArgs -contains '10.0.1') 'EF version must match the pinned source release.'
    $global:LASTEXITCODE = $global:productsTestState.InstallExit
    if ($global:LASTEXITCODE -ne 0) { return }
    $pathIndex = [Array]::IndexOf($toolArgs, '--tool-path')
    $directory = $toolArgs[$pathIndex + 1]
    $global:productsTestState.ToolDirectory = $directory
    $null = New-Item -ItemType Directory -Path $directory
    foreach ($name in @('dotnet-ef', 'dotnet-ef.exe')) {
        $aliasPath = Join-Path $directory $name
        Set-Alias -Scope Global -Name $aliasPath -Value Invoke-ProductsTestEf
        $global:productsTestAliases += $aliasPath
    }
}

function Invoke-TestCase {
    param([string] $Name, [scriptblock] $Arrange, [string] $ExpectedError, [int] $ExpectedMigrations = 0, [int] $ExpectedSecretReads = 0)
    $global:productsTestState = [pscustomobject]@{
        Deployment = [pscustomobject]@{
            stage = 'prepare'
            migration_ipv4 = '203.0.113.10'
            source_commit = '5fa6966327dbc7894ce8156cf222b28a0cdf52f5'
            subscription_id = '11111111-1111-1111-1111-111111111111'
            sql_connection_secret_id = 'https://example.vault.azure.net/secrets/products-sql-connection/version'
        }
        Commit = '5fa6966327dbc7894ce8156cf222b28a0cdf52f5'
        Dirty = $false
        Subscription = '11111111-1111-1111-1111-111111111111'
        Secret = 'Server=tcp:example.database.windows.net,1433;Database=products;User ID=test;Password="TestOnlySecret123!";Encrypt=True;'
        OutputExit = 0
        SecretExit = 0
        InstallExit = 0
        MigrationExit = 0
        SecretReads = 0
        MigrationCalls = 0
        ToolDirectory = $null
    }
    [Environment]::SetEnvironmentVariable('ConnectionStrings__ProductCatalogDb', 'previous-connection', 'Process')
    [Environment]::SetEnvironmentVariable('Database__ApplyMigrations', 'previous-flag', 'Process')
    & $Arrange
    $failure = $null
    $captured = @()
    try {
        $captured = & $migrationScript -ProductsPath $fixtureRoot -TerraformPath terraform *>&1
    }
    catch { $failure = $_.Exception.Message }

    if ($ExpectedError) {
        Assert-Condition ($failure -and $failure -match $ExpectedError) "${Name}: expected error '$ExpectedError', received '$failure'."
    }
    else { Assert-Condition (!$failure) "${Name}: unexpected failure: $failure" }
    Assert-Condition ($global:productsTestState.MigrationCalls -eq $ExpectedMigrations) "${Name}: unexpected EF execution count."
    Assert-Condition ($global:productsTestState.SecretReads -eq $ExpectedSecretReads) "${Name}: unexpected secret read count."
    Assert-Condition ($env:ConnectionStrings__ProductCatalogDb -eq 'previous-connection') "${Name}: previous SQL environment was not restored."
    Assert-Condition ($env:Database__ApplyMigrations -eq 'previous-flag') "${Name}: previous startup environment was not restored."
    Assert-Condition ((Get-Location).Path -eq $originalLocation) "${Name}: original directory was not restored."
    if ($global:productsTestState.ToolDirectory) {
        Assert-Condition (!(Test-Path -LiteralPath $global:productsTestState.ToolDirectory)) "${Name}: temporary EF tool directory was not removed."
    }
    Assert-Condition (!(($captured | Out-String).Contains('TestOnlySecret123!'))) "${Name}: secret leaked into output."
    Write-Host "PASS: $Name"
}

try {
    $null = New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'src/ProductCatalog.Api') -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'src/ProductCatalog.Infrastructure') -Force
    Set-Content -Path (Join-Path $fixtureRoot 'src/ProductCatalog.Api/ProductCatalog.Api.csproj') -Value '<Project />'
    Set-Content -Path (Join-Path $fixtureRoot 'src/ProductCatalog.Infrastructure/ProductCatalog.Infrastructure.csproj') -Value '<Project />'

    Invoke-TestCase 'successful dedicated migration' {} '' 1 1
    Invoke-TestCase 'wrong deployment stage' { $global:productsTestState.Deployment.stage = 'run' } 'prepare stage'
    Invoke-TestCase 'missing local SQL access' { $global:productsTestState.Deployment.migration_ipv4 = $null } 'no public IPv4'
    Invoke-TestCase 'image/source mismatch' { $global:productsTestState.Commit = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' } 'Check out ProductsCatalog commit'
    Invoke-TestCase 'dirty migration source' { $global:productsTestState.Dirty = $true } 'clean ProductsCatalog checkout'
    Invoke-TestCase 'wrong Azure subscription' { $global:productsTestState.Subscription = '99999999-9999-9999-9999-999999999999' } 'same Azure CLI subscription'
    Invoke-TestCase 'failed applied output read' { $global:productsTestState.OutputExit = 1 } 'Cannot read the applied'
    Invoke-TestCase 'failed secret read' { $global:productsTestState.SecretExit = 1 } 'Cannot read the Products SQL secret' 0 1
    Invoke-TestCase 'empty SQL secret' { $global:productsTestState.Secret = '' } 'secret is empty' 0 1
    Invoke-TestCase 'failed tool installation restores environment' { $global:productsTestState.InstallExit = 1 } 'tool installation failed' 0 1
    Invoke-TestCase 'failed EF migration restores environment' { $global:productsTestState.MigrationExit = 1 } 'Products migration failed' 1 1
    Write-Host 'All 11 offline migration helper checks passed.'
}
finally {
    [Environment]::SetEnvironmentVariable('ConnectionStrings__ProductCatalogDb', $originalConnection, 'Process')
    [Environment]::SetEnvironmentVariable('Database__ApplyMigrations', $originalFlag, 'Process')
    foreach ($name in @('terraform', 'git', 'az', 'dotnet', 'Invoke-ProductsTestEf')) {
        Remove-Item -Path "Function:\$name" -ErrorAction SilentlyContinue
    }
    # Temporary EF aliases are confined to this test process, which now exits.
    Remove-Variable -Name productsTestState, productsTestAliases -Scope Global -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}
