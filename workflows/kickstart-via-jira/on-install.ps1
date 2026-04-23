# profile-init.ps1 — kickstart-via-jira profile initialization
# Runs after dotbot init -Profile kickstart-via-jira (not copied to .bot/)

# ---------------------------------------------------------------------------
# 1. Check required CLI tools
# ---------------------------------------------------------------------------
$requiredTools = @(
    @{ Name = "git";    Required = $true;  Purpose = "Repo cloning, branch management" }
    @{ Name = "az";     Required = $true;  Purpose = "Draft PR creation (az repos pr create)" }
)

$optionalTools = @(
    @{ Name = "dotnet"; Required = $false; Purpose = "Build verification" }
)

foreach ($tool in $requiredTools) {
    if (Get-Command $tool.Name -ErrorAction SilentlyContinue) {
        Write-Success "$($tool.Name) found -- $($tool.Purpose)"
    } else {
        Write-DotbotWarning "$($tool.Name) not found -- required for: $($tool.Purpose)"
    }
}

foreach ($tool in $optionalTools) {
    if (Get-Command $tool.Name -ErrorAction SilentlyContinue) {
        Write-Success "$($tool.Name) found -- $($tool.Purpose)"
    } else {
        Write-DotbotWarning "$($tool.Name) not found -- optional: $($tool.Purpose)"
    }
}

# ---------------------------------------------------------------------------
# 2. Check MCP server availability
# ---------------------------------------------------------------------------
$mcpJsonPath = Join-Path $ProjectDir ".mcp.json"
if (Test-Path $mcpJsonPath) {
    $mcpConfig = Get-Content $mcpJsonPath -Raw | ConvertFrom-Json

    # Check for dotbot MCP server (registered by init-project.ps1)
    $mcpServers = $mcpConfig.mcpServers
    if (-not $mcpServers) { $mcpServers = $mcpConfig }

    if ($mcpServers.PSObject.Properties.Name -contains "dotbot") {
        Write-Success "dotbot MCP server registered"
    } else {
        Write-DotbotWarning "dotbot MCP server not found in .mcp.json"
    }

    # Check for Atlassian MCP server (optional but recommended)
    if ($mcpServers.PSObject.Properties.Name -contains "atlassian") {
        Write-Success "atlassian MCP server registered"
    } else {
        Write-DotbotWarning "atlassian MCP server not found -- Phase 0 will use graceful degradation"
        Write-Status "  To add Atlassian MCP: claude mcp add --transport http atlassian -s user https://mcp.atlassian.com/v1/mcp (then /mcp -> authenticate)"
    }
} else {
    Write-DotbotWarning ".mcp.json not found -- MCP servers will be configured during init"
}

# ---------------------------------------------------------------------------
# 3. Bootstrap .env.local
# ---------------------------------------------------------------------------
$envLocal = Join-Path $ProjectDir ".env.local"
$envExample = Join-Path $PSScriptRoot ".env.example"

if (-not (Test-Path $envLocal)) {
    Copy-Item $envExample $envLocal
    Write-DotbotWarning ".env.local created from template -- edit it with your credentials"
    Write-Status "  Path: $envLocal"
} else {
    Write-Success ".env.local already exists"
}

# Validate required variables are populated
$envVars = @{}
Get-Content $envLocal | ForEach-Object {
    if ($_ -match '^\s*([^#][^=]+)=(.*)$') {
        $envVars[$matches[1].Trim()] = $matches[2].Trim()
    }
}
$required = @("AZURE_DEVOPS_PAT", "AZURE_DEVOPS_ORG_URL")
$missing = $required | Where-Object { -not $envVars[$_] }
if ($missing) {
    Write-DotbotWarning "Missing required values in .env.local: $($missing -join ', ')"
    Write-Status "  Edit $envLocal and fill in the missing values before running workflows"
} else {
    Write-Success "All required .env.local values populated"
}

# ---------------------------------------------------------------------------
# 4. Create repos/ directory and gitignore it
# ---------------------------------------------------------------------------
$reposDir = Join-Path $ProjectDir "repos"
if (-not (Test-Path $reposDir)) {
    New-Item -Path $reposDir -ItemType Directory | Out-Null
    Write-Success "Created repos/ directory"
} else {
    Write-Success "repos/ directory already exists"
}

# Ensure repos/ is in .gitignore
$gitignore = Join-Path $ProjectDir ".gitignore"
if (Test-Path $gitignore) {
    $content = Get-Content $gitignore -Raw
    if ($content -notmatch '(?m)^/?repos/') {
        Add-Content $gitignore "`n/repos/"
        Write-Success "Added repos/ to .gitignore"
    }
} else {
    Set-Content $gitignore "/repos/`n"
    Write-Success "Created .gitignore with repos/ entry"
}

# Ensure .env.local is in .gitignore
$content = Get-Content $gitignore -Raw
if ($content -notmatch '\.env\.local') {
    Add-Content $gitignore ".env.local"
    Write-Success "Added .env.local to .gitignore"
}

Write-Success "kickstart-via-jira profile initialized"
