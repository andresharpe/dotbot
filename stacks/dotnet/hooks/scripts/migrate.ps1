#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Manually apply database migrations to Flux database

.DESCRIPTION
    This script applies pending Entity Framework migrations to the database.
    Use this for production deployments where automatic migrations are disabled.

.PARAMETER Environment
    The environment to use (Development, Staging, Production). Default: Production

.PARAMETER ConnectionString
    Optional connection string override. If not provided, uses appsettings.

.PARAMETER DryRun
    If specified, shows pending migrations without applying them.

.EXAMPLE
    .\migrate.ps1
    Applies migrations using Production configuration

.EXAMPLE
    .\migrate.ps1 -Environment Development
    Applies migrations using Development configuration

.EXAMPLE
    .\migrate.ps1 -DryRun
    Shows pending migrations without applying

.EXAMPLE
    .\migrate.ps1 -ConnectionString "Host=localhost;Database=flux;..."
    Applies migrations using custom connection string
#>

param(
    [string]$Environment = "Production",
    [string]$ConnectionString,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# Navigate to project root
$scriptDir = Split-Path -Parent $PSScriptRoot
$projectRoot = Split-Path -Parent $scriptDir
Push-Location $projectRoot

try {
    Write-Host "=== Flux Database Migration Tool ===" -ForegroundColor Cyan
    Write-Host ""

    $apiProject = Join-Path $projectRoot "src\Flux.Api\Flux.Api.csproj"
    $infraProject = Join-Path $projectRoot "src\Flux.Infrastructure\Flux.Infrastructure.csproj"

    if (-not (Test-Path $apiProject)) {
        throw "API project not found at: $apiProject"
    }

    if (-not (Test-Path $infraProject)) {
        throw "Infrastructure project not found at: $infraProject"
    }

    # Check pending migrations
    Write-Host "Checking for pending migrations..." -ForegroundColor Yellow
    $pendingOutput = dotnet ef migrations list `
        --project $infraProject `
        --startup-project $apiProject `
        --no-build `
        --environment $Environment `
        2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error checking migrations:" -ForegroundColor Red
        Write-Host $pendingOutput
        exit 1
    }

    Write-Host $pendingOutput
    Write-Host ""

    # Get migration status
    $hasPending = $pendingOutput -match "Pending"
    
    if (-not $hasPending) {
        Write-Host "✓ Database is up to date - no pending migrations" -ForegroundColor Green
        exit 0
    }

    if ($DryRun) {
        Write-Host "Dry run mode - migrations would be applied but not executing" -ForegroundColor Yellow
        exit 0
    }

    # Confirm before applying
    Write-Host "About to apply migrations to environment: $Environment" -ForegroundColor Yellow
    if ($ConnectionString) {
        Write-Host "Using custom connection string" -ForegroundColor Yellow
    }
    Write-Host ""
    $confirm = Read-Host "Continue? (yes/no)"
    
    if ($confirm -ne "yes") {
        Write-Host "Migration cancelled" -ForegroundColor Yellow
        exit 0
    }

    # Apply migrations
    Write-Host ""
    Write-Host "Applying migrations..." -ForegroundColor Yellow
    
    $migrateArgs = @(
        "ef", "database", "update",
        "--project", $infraProject,
        "--startup-project", $apiProject,
        "--environment", $Environment
    )

    if ($ConnectionString) {
        $migrateArgs += "--connection", $ConnectionString
    }

    $output = & dotnet $migrateArgs 2>&1
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "✗ Migration failed:" -ForegroundColor Red
        Write-Host $output
        exit 1
    }

    Write-Host $output
    Write-Host ""
    Write-Host "✓ Migrations applied successfully" -ForegroundColor Green

} catch {
    Write-Host ""
    Write-Host "✗ Error: $_" -ForegroundColor Red
    exit 1
} finally {
    Pop-Location
}
