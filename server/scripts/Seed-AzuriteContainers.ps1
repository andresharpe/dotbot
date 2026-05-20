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

# --- detect Azurite, pick auth flags, derive blob endpoint -------------------
# When the connection string targets Azurite, Azure CLI 2.85+ mis-signs requests
# for the full DefaultEndpointsProtocol=...;AccountName=...;AccountKey=...;BlobEndpoint=...;
# form and returns "AuthorizationFailure" (surfaced as the misleading
# "request may be blocked by network rules" message). The short
# "UseDevelopmentStorage=true" form uses Azure CLI's built-in Azurite preset
# which signs correctly. Substitute it transparently when we detect Azurite.
#
# Detection uses the well-known Azurite account key (a public constant baked
# into Azurite's source). Real Azure storage accounts generate random 512-bit
# keys at creation time, so this value never appears outside the emulator.
$AzuriteWellKnownKey = 'Eby8vdM02xNOcqFlqUwJPLlmEu9Fyuwz2LNgaXcHMRvXv3lGbPjhImDs4Wqg6zY/JxGgZANyEDOmXpKXHVRjkw=='
$AzuriteDefaultBlobEndpoint = 'http://127.0.0.1:10000/devstoreaccount1'

$isShortForm = $connectionString -match '^\s*UseDevelopmentStorage\s*=\s*true\s*;?\s*$'
$isAzurite = $isShortForm -or ($connectionString -like "*$AzuriteWellKnownKey*")

if ($isAzurite) {
    $effectiveConnectionString = 'UseDevelopmentStorage=true'
    $authMode = 'key'
} else {
    $effectiveConnectionString = $connectionString
    $authMode = $null
    Write-Warning "Connection string does not look like Azurite (well-known key not present and not 'UseDevelopmentStorage=true'). Continuing anyway."
}

# Use the explicit BlobEndpoint when present; otherwise (e.g. the short form)
# fall back to Azurite's default. This lets the reachability ping work for
# either connection-string style.
$blobEndpoint = ($connectionString -split ';' |
    Where-Object { $_ -match '^BlobEndpoint=' } |
    ForEach-Object { ($_ -split '=', 2)[1] }) | Select-Object -First 1
if (-not $blobEndpoint -and $isAzurite) {
    $blobEndpoint = $AzuriteDefaultBlobEndpoint
}

# --- check Azurite is reachable ----------------------------------------------
if ($blobEndpoint) {
    try {
        $null = Invoke-WebRequest -Uri $blobEndpoint -Method Get -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
    } catch {
        # Azurite returns 400 on bare-endpoint GET, which is fine - we just
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
    $azArgs = @(
        'storage', 'container', 'create',
        '--name', $name,
        '--connection-string', $effectiveConnectionString,
        '--output', 'json'
    )
    if ($authMode) { $azArgs += @('--auth-mode', $authMode) }

    $result = az @azArgs 2>&1

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
