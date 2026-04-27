# profile-init.ps1 - start-from-pr workflow initialization
# Runs after dotbot init -Workflow start-from-pr (not copied to .bot/)

$requiredTools = @(
    @{ Name = "git"; Purpose = "PR auto-detection and repository inspection" }
)

$optionalTools = @(
    @{ Name = "gh"; Purpose = "Optional GitHub CLI fallback" }
    @{ Name = "az"; Purpose = "Optional Azure DevOps CLI fallback" }
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

$mcpJsonPath = Join-Path $ProjectDir ".mcp.json"
if (Test-Path $mcpJsonPath) {
    $mcpConfig = Get-Content $mcpJsonPath -Raw | ConvertFrom-Json
    $mcpServers = if ($mcpConfig.mcpServers) { $mcpConfig.mcpServers } else { $mcpConfig }

    if ($mcpServers.PSObject.Properties.Name -contains "dotbot") {
        Write-Success "dotbot MCP server registered"
    } else {
        Write-DotbotWarning "dotbot MCP server not found in .mcp.json"
    }
} else {
    Write-DotbotWarning ".mcp.json not found -- MCP servers will be configured during init"
}

$envLocal = Join-Path $ProjectDir ".env.local"
$envExample = Join-Path $PSScriptRoot ".env.example"

if (-not (Test-Path $envLocal)) {
    Copy-Item $envExample $envLocal
    Write-DotbotWarning ".env.local created from template -- add credentials if you need private PR access"
    Write-Status "  Path: $envLocal"
} else {
    Write-Success ".env.local already exists"
}

$envVars = @{}
Get-Content $envLocal | ForEach-Object {
    if ($_ -match '^\s*([^#][^=]+)=(.*)$') {
        $envVars[$matches[1].Trim()] = $matches[2].Trim()
    }
}

$hasGitHubToken = -not [string]::IsNullOrWhiteSpace($envVars["GITHUB_TOKEN"]) -or -not [string]::IsNullOrWhiteSpace($envVars["GH_TOKEN"])
$hasAdoPat = -not [string]::IsNullOrWhiteSpace($envVars["AZURE_DEVOPS_PAT"])

if ($hasGitHubToken) {
    Write-Success "GitHub token detected in .env.local"
} else {
    Write-DotbotWarning "No GitHub token configured -- private GitHub PRs may not be readable"
}

if ($hasAdoPat) {
    Write-Success "AZURE_DEVOPS_PAT detected in .env.local"
} else {
    Write-DotbotWarning "AZURE_DEVOPS_PAT not configured -- Azure DevOps PRs will require it"
}

$gitignore = Join-Path $ProjectDir ".gitignore"
if (-not (Test-Path $gitignore)) {
    Set-Content -Path $gitignore -Encoding UTF8 -Value ".env.local"
    Write-Success "Created .gitignore with .env.local entry"
} else {
    $gitignoreContent = Get-Content $gitignore -Raw
    if ($gitignoreContent -notmatch '(?m)^\.env\.local$') {
        Add-Content -Path $gitignore -Value "`r`n.env.local"
        Write-Success "Added .env.local to .gitignore"
    }
}

Write-Success "start-from-pr workflow initialized"
