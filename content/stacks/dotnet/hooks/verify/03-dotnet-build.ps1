param(
    [string]$TaskId,
    [string]$Category
)

# Verify dotnet build succeeds
$issues = @()
$details = @{}

# Check for .NET project
$csproj = Get-ChildItem -Path . -Filter "*.csproj" -Recurse -Depth 3 | Select-Object -First 1

if (-not $csproj) {
    @{
        success = $true
        script = "03-dotnet-build.ps1"
        message = "Skipped (not a .NET project)"
        details = @{ skipped = $true }
        failures = @()
    } | ConvertTo-Json -Depth 10
    exit 0
}

$details['project'] = $csproj.Name

try {
    $null = dotnet build --no-restore 2>&1
    if ($LASTEXITCODE -ne 0) {
        $issues += @{
            issue = "Build failed"
            severity = "error"
            context = "Run 'dotnet build' to see errors"
        }
    }
    $details['build_passed'] = ($LASTEXITCODE -eq 0)
} catch {
    $issues += @{
        issue = "Build check failed: $($_.Exception.Message)"
        severity = "error"
    }
}

@{
    success = ($issues.Count -eq 0)
    script = "03-dotnet-build.ps1"
    message = if ($issues.Count -eq 0) { "Build succeeded" } else { "Build failed" }
    details = $details
    failures = $issues
} | ConvertTo-Json -Depth 10
