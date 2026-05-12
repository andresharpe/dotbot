<#
.SYNOPSIS
    Seeds the blob containers DotbotServer expects in local Azurite.

.DESCRIPTION
    DotbotServer reads from two blob containers on startup. Azurite does not
    create containers automatically and the server does not call
    CreateIfNotExists, so a fresh Azurite gives a 404 ContainerNotFound
    until the containers are seeded once.

    Containers created (idempotent):
      - answers                  (templates, instances, responses, tokens, admins)
      - conversation-references  (Teams conversation references)

    The connection string is read from appsettings.Development.json so this
    script tracks whatever the dev server is configured to use.

.PARAMETER AppSettingsPath
    Path to appsettings.Development.json. Defaults to the standard
    location relative to this script.

.EXAMPLE
    .\Seed-AzuriteContainers.ps1
        Creates both containers in the configured Azurite instance.

.NOTES
    Requires Azure CLI (`az`) on PATH. Azurite must already be running
    (e.g. `azurite --silent --location <data-dir>`).
#>
[CmdletBinding()]
param(
    [string]$AppSettingsPath = (Join-Path $PSScriptRoot '..' 'src' 'Dotbot.Server' 'appsettings.Development.json')
)

$ErrorActionPreference = 'Stop'

# --- preflight ----------------------------------------------------------------
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI ('az') not found on PATH. Install via 'winget install Microsoft.AzureCLI' and reopen the shell."
}

if (-not (Test-Path $AppSettingsPath)) {
    throw "appsettings file not found: $AppSettingsPath"
}

# --- read connection string ---------------------------------------------------
$settings = Get-Content $AppSettingsPath -Raw | ConvertFrom-Json
$connectionString = $settings.BlobStorage.ConnectionString
if (-not $connectionString) {
    throw "BlobStorage.ConnectionString is empty in $AppSettingsPath. Use AccountUri+managed-identity in production; this script is for the local Azurite dev path only."
}

if ($connectionString -notmatch 'devstoreaccount1') {
    Write-Warning "Connection string does not look like Azurite (no 'devstoreaccount1' marker). Continuing anyway."
}

# --- check Azurite is reachable ----------------------------------------------
# Parse BlobEndpoint from the conn string for a quick sanity ping.
$blobEndpoint = ($connectionString -split ';' |
    Where-Object { $_ -match '^BlobEndpoint=' } |
    ForEach-Object { ($_ -split '=', 2)[1] }) | Select-Object -First 1

if ($blobEndpoint) {
    try {
        $null = Invoke-WebRequest -Uri $blobEndpoint -Method Get -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
    } catch {
        # Azurite returns 400 on bare-endpoint GET, which is fine — we just
        # want to confirm something is listening there.
        if (-not ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -ge 400)) {
            throw "Azurite does not appear to be running at $blobEndpoint. Start it (e.g. 'azurite --silent') and re-run."
        }
    }
}

# --- create containers --------------------------------------------------------
$containers = @('answers', 'conversation-references')

foreach ($name in $containers) {
    Write-Host "Ensuring container '$name' ... " -NoNewline -ForegroundColor Gray
    # Note: omitting --fail-on-exist makes the command idempotent.
    # Passing it (even with no value) flips it on and would error when the container exists.
    $result = az storage container create `
        --name $name `
        --connection-string $connectionString `
        --output json 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAIL" -ForegroundColor Red
        Write-Host $result -ForegroundColor Red
        throw "az storage container create failed for '$name'"
    }

    $parsed = $result | ConvertFrom-Json
    if ($parsed.created) {
        Write-Host "created" -ForegroundColor Green
    } else {
        Write-Host "already exists" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "Done. DotbotServer should now start cleanly against Azurite." -ForegroundColor Green
