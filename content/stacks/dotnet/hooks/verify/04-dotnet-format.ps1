param(
    [string]$TaskId,
    [string]$Category
)

# Verify code formatting with dotnet format
$issues = @()
$details = @{}

# Check for .NET project
$csproj = Get-ChildItem -Path . -Filter "*.csproj" -Recurse -Depth 3 | Select-Object -First 1

if (-not $csproj) {
    @{
        success = $true
        script = "04-dotnet-format.ps1"
        message = "Skipped (not a .NET project)"
        details = @{ skipped = $true }
        failures = @()
    } | ConvertTo-Json -Depth 10
    exit 0
}

$details['project'] = $csproj.Name

try {
    $null = dotnet format --verify-no-changes 2>&1
    if ($LASTEXITCODE -ne 0) {
        $issues += @{
            issue = "Code formatting issues detected"
            severity = "error"
            context = "Run 'dotnet format' to fix"
        }
    }
    $details['format_ok'] = ($LASTEXITCODE -eq 0)
} catch {
    $issues += @{
        issue = "Format check failed: $($_.Exception.Message)"
        severity = "error"
    }
}

@{
    success = ($issues.Count -eq 0)
    script = "04-dotnet-format.ps1"
    message = if ($issues.Count -eq 0) { "Formatting OK" } else { "Formatting issues found" }
    details = $details
    failures = $issues
} | ConvertTo-Json -Depth 10
