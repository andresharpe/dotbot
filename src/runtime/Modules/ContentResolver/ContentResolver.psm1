#!/usr/bin/env pwsh
<#
.SYNOPSIS
Layered content resolver for dotbot framework content.

.DESCRIPTION
Implements the project-overrides-framework lookup pattern described in
the DOTBOT_HOME design. A project can add or override any agent / skill
/ prompt / workflow / stack / recipe by placing it under
<BotRoot>/content/<Type>/. The runtime falls back to
<DOTBOT_HOME>/content/<Type>/ for anything the project does not provide.

Hooks layer similarly. Per design decision D2 the merge is by filename:
a project file replaces the framework file of the same name; framework-
only files still run. Numbered filenames (00-, 01-, 02-, ...) make
filename sort order match execution order.

Exports
  - Resolve-DotbotContent  : single-item lookup, returns a path or $null
  - Get-DotbotContentItems : enumeration, returns objects with override info
  - Get-DotbotHookChain    : ordered hook list for a phase

The framework root resolves through Get-DotbotInstallPath (Dotbot.Core),
which honours $env:DOTBOT_HOME with the usual ~ expansion.
#>

if (-not (Get-Module Dotbot.Core)) {
    $coreModule = Join-Path $PSScriptRoot ".." "Dotbot.Core" "Dotbot.Core.psm1"
    Import-Module $coreModule -DisableNameChecking -Global
}

if (-not (Get-Module Dotbot.Settings)) {
    $settingsModule = Join-Path $PSScriptRoot ".." "Dotbot.Settings" "Dotbot.Settings.psd1"
    Import-Module $settingsModule -DisableNameChecking -Global
}

$script:ContentTypes = @('agents','skills','prompts','workflows','stacks','recipes')
$script:HookPhases   = @('verify','dev','scripts')

function Get-DotbotFrameworkRoot {
    <#
    .SYNOPSIS
    Centralised accessor for $DOTBOT_HOME (or fallback). Single seam so
    tests and tooling have one place to override if ever needed.
    #>
    Get-DotbotInstallPath
}

function Resolve-DotbotContent {
    <#
    .SYNOPSIS
    Resolve a single content item by Type and Name, with project override.

    .DESCRIPTION
    Searches <BotRoot>/content/<Type>/<Name> first, then
    <DOTBOT_HOME>/content/<Type>/<Name>. Returns the first match's
    absolute path, or $null if neither layer has it.

    Name may refer to either a directory (agents, skills, workflows,
    stacks, recipes) or a single file (prompts — pass the full
    filename including extension). The resolver does not distinguish;
    the caller is responsible for knowing the shape of what they
    requested.

    .PARAMETER BotRoot
    Path to the project's .bot/ directory.

    .PARAMETER Type
    One of: agents, skills, prompts, workflows, stacks, recipes.

    .PARAMETER Name
    Item name (e.g. 'implementer', 'start-from-prompt',
    '98-analyse-task.md').

    .OUTPUTS
    [string] Absolute path, or $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BotRoot,

        [Parameter(Mandatory)]
        [ValidateSet('agents','skills','prompts','workflows','stacks','recipes')]
        [string]$Type,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $projectPath = Join-Path $BotRoot 'content' $Type $Name
    if (Test-Path -LiteralPath $projectPath) {
        return (Resolve-Path -LiteralPath $projectPath).Path
    }

    $frameworkRoot = Get-DotbotFrameworkRoot
    if (-not [string]::IsNullOrWhiteSpace($frameworkRoot)) {
        $frameworkPath = Join-Path $frameworkRoot 'content' $Type $Name
        if (Test-Path -LiteralPath $frameworkPath) {
            return (Resolve-Path -LiteralPath $frameworkPath).Path
        }
    }

    return $null
}

function Get-DotbotContentItems {
    <#
    .SYNOPSIS
    Enumerate every content item of a given Type, deduplicated across
    project and framework layers.

    .DESCRIPTION
    Walks <BotRoot>/content/<Type>/ then <DOTBOT_HOME>/content/<Type>/.
    A name that appears in both layers is reported once, sourced to
    'project'. Framework-only items are reported as 'framework'.

    Results are sorted by Name (stable across runs).

    .OUTPUTS
    Array of [PSCustomObject] with Name / Path / Source. Empty array
    when neither layer has any items.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BotRoot,

        [Parameter(Mandatory)]
        [ValidateSet('agents','skills','prompts','workflows','stacks','recipes')]
        [string]$Type
    )

    $items = [ordered]@{}

    $projectDir = Join-Path $BotRoot 'content' $Type
    if (Test-Path -LiteralPath $projectDir) {
        Get-ChildItem -LiteralPath $projectDir -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $items[$_.Name] = [pscustomobject]@{
                Name   = $_.Name
                Path   = $_.FullName
                Source = 'project'
            }
        }
    }

    $frameworkRoot = Get-DotbotFrameworkRoot
    if (-not [string]::IsNullOrWhiteSpace($frameworkRoot)) {
        $frameworkDir = Join-Path $frameworkRoot 'content' $Type
        if (Test-Path -LiteralPath $frameworkDir) {
            Get-ChildItem -LiteralPath $frameworkDir -Force -ErrorAction SilentlyContinue | ForEach-Object {
                if (-not $items.Contains($_.Name)) {
                    $items[$_.Name] = [pscustomobject]@{
                        Name   = $_.Name
                        Path   = $_.FullName
                        Source = 'framework'
                    }
                }
            }
        }
    }

    [array]$result = @($items.Values | Sort-Object -Property Name)
    , $result
}

function Get-DotbotActiveStackChain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BotRoot
    )

    try {
        $settings = Get-MergedSettings -BotRoot $BotRoot
    } catch {
        return @()
    }
    if (-not $settings -or -not $settings.PSObject.Properties['stacks']) { return @() }

    $result = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    function Add-Stack {
        param([string]$Name)
        if ([string]::IsNullOrWhiteSpace($Name)) { return }
        $key = $Name.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { return }

        $path = Resolve-DotbotContent -BotRoot $BotRoot -Type stacks -Name $Name
        if (-not $path) { return }
        $manifest = Join-Path $path 'manifest.yaml'
        if (Test-Path -LiteralPath $manifest) {
            $match = Select-String -LiteralPath $manifest -Pattern '^\s*extends\s*:\s*[''"]?([^''"#\s]+)' | Select-Object -First 1
            if ($match) { Add-Stack -Name $match.Matches[0].Groups[1].Value }
        }
        $seen[$key] = $true
        $result.Add([pscustomobject]@{ Name = $Name; Path = $path }) | Out-Null
    }

    foreach ($name in @($settings.stacks)) { Add-Stack -Name "$name" }
    return @($result)
}

function Get-DotbotHookChain {
    <#
    .SYNOPSIS
    Build the ordered hook chain for a phase, merging project + framework
    hooks by filename.

    .DESCRIPTION
    Returns the list of *.ps1 files for the given phase, merged from:
      - <BotRoot>/hooks/<Phase>/        (project layer)
      - <DOTBOT_HOME>/src/hooks/<Phase>/ (framework layer)

    Per design decision D2 (union by filename, project wins):
      - A project file with the same filename as a framework file
        replaces it.
      - Framework files with no project counterpart still appear.
      - Output is sorted by filename, which matches the numbered
        execution-order convention (00-, 01-, 02-, ...).

    .PARAMETER BotRoot
    Path to the project's .bot/ directory.

    .PARAMETER Phase
    Hook phase: verify, dev, or scripts.

    .OUTPUTS
    Array of [PSCustomObject] with Name / Path / Source. Empty array
    when neither layer has any *.ps1.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BotRoot,

        [Parameter(Mandatory)]
        [ValidateSet('verify','dev','scripts')]
        [string]$Phase
    )

    $items = [ordered]@{}

    $frameworkRoot = Get-DotbotFrameworkRoot
    if (-not [string]::IsNullOrWhiteSpace($frameworkRoot)) {
        $frameworkDir = Join-Path $frameworkRoot 'src' 'hooks' $Phase
        if (Test-Path -LiteralPath $frameworkDir) {
            Get-ChildItem -LiteralPath $frameworkDir -Filter '*.ps1' -File -ErrorAction SilentlyContinue | ForEach-Object {
                $items[$_.Name] = [pscustomobject]@{
                    Name   = $_.Name
                    Path   = $_.FullName
                    Source = 'framework'
                }
            }
        }
    }

    foreach ($stack in (Get-DotbotActiveStackChain -BotRoot $BotRoot)) {
        $stackDir = Join-Path $stack.Path 'hooks' $Phase
        if (-not (Test-Path -LiteralPath $stackDir)) { continue }
        Get-ChildItem -LiteralPath $stackDir -Filter '*.ps1' -File -ErrorAction SilentlyContinue | ForEach-Object {
            $items[$_.Name] = [pscustomobject]@{
                Name   = $_.Name
                Path   = $_.FullName
                Source = "stack:$($stack.Name)"
            }
        }
    }

    $projectDir = Join-Path $BotRoot 'hooks' $Phase
    if (Test-Path -LiteralPath $projectDir) {
        Get-ChildItem -LiteralPath $projectDir -Filter '*.ps1' -File -ErrorAction SilentlyContinue | ForEach-Object {
            $items[$_.Name] = [pscustomobject]@{
                Name   = $_.Name
                Path   = $_.FullName
                Source = 'project'
            }
        }
    }

    [array]$result = @($items.Values | Sort-Object -Property Name)
    , $result
}

Export-ModuleMember -Function Resolve-DotbotContent, Get-DotbotContentItems, Get-DotbotActiveStackChain, Get-DotbotHookChain
