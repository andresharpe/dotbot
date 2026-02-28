<#
.SYNOPSIS
    Deploys the Dotbot Teams Bot to Azure App Service.

.DESCRIPTION
    Builds the .NET project, creates a zip package, and deploys it to the
    Azure App Service using az webapp deploy.

    Optionally runs Terraform first with -WithTerraform to provision/update
    infrastructure before deploying the application.

.PARAMETER ResourceGroup
    Azure resource group name. Defaults to RG_WE_APPS_DOTBOT_TEST.

.PARAMETER AppName
    Azure App Service name. Defaults to we-dotbot-bot-test-01.

.PARAMETER WithTerraform
    If set, runs terraform init/plan/apply before the dotnet build step.

.PARAMETER TerraformDir
    Path to the Terraform configuration directory. Defaults to ../terraform.

.PARAMETER AutoApprove
    If set with -WithTerraform, applies the plan without prompting for confirmation.

.EXAMPLE
    .\scripts\Deploy.ps1
    .\scripts\Deploy.ps1 -WithTerraform
    .\scripts\Deploy.ps1 -WithTerraform -AutoApprove
    .\scripts\Deploy.ps1 -ResourceGroup "RG_WE_APPS_DOTBOT_PROD" -AppName "we-dotbot-bot-prod-01"
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup = "RG_WE_APPS_DOTBOT_TEST",
    [string]$AppName = "we-dotbot-bot-test-01",
    [switch]$WithTerraform,
    [string]$TerraformDir = (Join-Path $PSScriptRoot "..\terraform"),
    [switch]$AutoApprove
)

$ErrorActionPreference = 'Stop'

# ── Terraform (optional) ────────────────────────────────────────────────────
if ($WithTerraform) {
    $tfDir = Resolve-Path $TerraformDir -ErrorAction Stop

    Write-Host "Running Terraform in $tfDir..." -ForegroundColor Cyan

    Write-Host "  terraform init -upgrade" -ForegroundColor Gray
    terraform -chdir="$tfDir" init -upgrade
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Terraform init failed!" -ForegroundColor Red
        exit 1
    }

    Write-Host "  terraform plan -out=tfplan" -ForegroundColor Gray
    terraform -chdir="$tfDir" plan -out=tfplan
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Terraform plan failed!" -ForegroundColor Red
        exit 1
    }

    if (-not $AutoApprove) {
        $confirm = Read-Host "Apply these changes? (y/N)"
        if ($confirm -ne 'y') {
            Write-Host "Aborted." -ForegroundColor Yellow
            Remove-Item (Join-Path $tfDir "tfplan") -Force -ErrorAction SilentlyContinue
            exit 0
        }
    }

    Write-Host "  terraform apply tfplan" -ForegroundColor Gray
    terraform -chdir="$tfDir" apply tfplan
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Terraform apply failed!" -ForegroundColor Red
        exit 1
    }

    Remove-Item (Join-Path $tfDir "tfplan") -Force -ErrorAction SilentlyContinue
    Write-Host "Terraform apply complete." -ForegroundColor Green
    Write-Host ""
}

# ── Build & Deploy ──────────────────────────────────────────────────────────
$projectDir = Join-Path $PSScriptRoot "..\src\Dotbot.Server"
$publishDir = Join-Path $PSScriptRoot "..\publish"
$zipPath = Join-Path $PSScriptRoot "..\publish.zip"

Write-Host "Building Dotbot.Server..." -ForegroundColor Cyan
dotnet publish $projectDir -c Release -o $publishDir --nologo

if ($LASTEXITCODE -ne 0) {
    Write-Host "Build failed!" -ForegroundColor Red
    exit 1
}

Write-Host "Creating deployment package..." -ForegroundColor Cyan
if (Test-Path $zipPath) { Remove-Item $zipPath }
Compress-Archive -Path "$publishDir\*" -DestinationPath $zipPath

Write-Host "Deploying to $AppName in $ResourceGroup..." -ForegroundColor Cyan
az webapp deploy `
    --resource-group $ResourceGroup `
    --name $AppName `
    --src-path $zipPath `
    --type zip `
    --async false

if ($LASTEXITCODE -ne 0) {
    Write-Host "Deployment failed!" -ForegroundColor Red
    exit 1
}

Write-Host "Deployment complete!" -ForegroundColor Green
Write-Host "   URL: https://$AppName.azurewebsites.net" -ForegroundColor Gray
Write-Host "   Health: https://$AppName.azurewebsites.net/api/health" -ForegroundColor Gray

# Cleanup
Remove-Item $publishDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
