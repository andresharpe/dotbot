<#
.SYNOPSIS
Cleanup utilities for temporary directories and sessions

.DESCRIPTION
Provides functions for cleaning up temporary directories and session data
created during provider sessions. Provider-aware: dispatches cleanup by
active provider (Claude cleans ~/.claude/projects/, Codex/Gemini are no-ops).
#>

function Get-ClaudeProjectDir {
    <#
    .SYNOPSIS
    Get the Claude projects directory for a given project root (Claude-specific internal helper)

    .PARAMETER ProjectRoot
    Path to the project root directory

    .OUTPUTS
    Path to the Claude projects directory, or $null if not found
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot
    )

    # Claude stores sessions in ~/.claude/projects/{project-hash}/
    # Project hash is derived from project path with drive letter and slashes replaced
    $fullPath = [System.IO.Path]::GetFullPath($ProjectRoot)

    # Convert path to hash format: colons and slashes replaced with dashes (matches Claude's project dir naming)
    $projectHash = $fullPath -replace ':', '-' -replace '\\', '-' -replace '/', '-'

    $claudeProjectDir = Join-Path $HOME '.claude' 'projects' $projectHash

    if (Test-Path $claudeProjectDir) {
        return $claudeProjectDir
    }

    return $null
}

function Remove-ProviderSession {
    <#
    .SYNOPSIS
    Remove a specific provider session's data. Dispatches by active provider.
    Claude: removes session folder + .jsonl from ~/.claude/projects/.
    Codex/Gemini: no-op (no local session artifacts).

    .PARAMETER SessionId
    The session ID (GUID) to remove

    .PARAMETER ProjectRoot
    Path to the project root directory

    .OUTPUTS
    $true if session was removed, $false otherwise
    #>
    param(
        [Parameter(Mandatory = $false)]
        [string]$SessionId,

        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot
    )

    if (-not $SessionId) { return $false }

    # Determine active provider
    $providerName = 'claude'
    try {
        if (-not (Get-Module ProviderCLI)) {
            Import-Module (Join-Path $PSScriptRoot '..\ProviderCLI\ProviderCLI.psm1') -Force
        }
        $config = Get-ProviderConfig
        $providerName = $config.name
    } catch { Write-BotLog -Level Debug -Message "Settings operation failed" -Exception $_ }

    # Only Claude has local session artifacts to clean
    if ($providerName -ne 'claude') { return $false }

    $claudeProjectDir = Get-ClaudeProjectDir -ProjectRoot $ProjectRoot

    if (-not $claudeProjectDir) { return $false }

    $removed = $false

    # Remove session folder (tool results)
    $sessionFolder = Join-Path $claudeProjectDir $SessionId
    if (Test-Path $sessionFolder) {
        Remove-Item $sessionFolder -Recurse -Force -ErrorAction SilentlyContinue
        $removed = $true
    }

    # Remove session .jsonl file
    $sessionFile = Join-Path $claudeProjectDir "$SessionId.jsonl"
    if (Test-Path $sessionFile) {
        Remove-Item $sessionFile -Force -ErrorAction SilentlyContinue
        $removed = $true
    }

    return $removed
}
