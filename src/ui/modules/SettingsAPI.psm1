<#
.SYNOPSIS
Settings, theme, and configuration API module

.DESCRIPTION
Provides theme management, UI settings, analysis config, and verification config CRUD.
Extracted from server.ps1 for modularity.
#>

if (-not (Get-Module Dotbot.Settings)) {
    Import-Module (Join-Path $PSScriptRoot "../../runtime/Modules/Dotbot.Settings/Dotbot.Settings.psd1") -DisableNameChecking -Global
}
if (-not (Get-Module Dotbot.Harness)) {
    Import-Module (Join-Path $PSScriptRoot "../../runtime/Modules/Dotbot.Harness/Dotbot.Harness.psd1") -DisableNameChecking -Global
}

$script:Config = @{
    ControlDir = $null
    BotRoot = $null
    StaticRoot = $null
}

function Initialize-SettingsAPI {
    param(
        [Parameter(Mandatory)] [string]$ControlDir,
        [Parameter(Mandatory)] [string]$BotRoot,
        [Parameter(Mandatory)] [string]$StaticRoot
    )
    $script:Config.ControlDir = $ControlDir
    $script:Config.BotRoot = $BotRoot
    $script:Config.StaticRoot = $StaticRoot
}

# Internal: load .control/settings.json as a hashtable (empty if missing/malformed).
function Get-OverridesHashtable {
    $overridesFile = Join-Path $script:Config.ControlDir "settings.json"
    $h = @{}
    if (Test-Path $overridesFile) {
        try {
            $existing = Get-Content $overridesFile -Raw | ConvertFrom-Json
            foreach ($prop in $existing.PSObject.Properties) {
                $h[$prop.Name] = $prop.Value
            }
        } catch {
            if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
                Write-BotLog -Level Debug -Message "Failed to parse overrides" -Exception $_
            }
        }
    }
    return $h
}

# Internal: persist a hashtable back to .control/settings.json. Writes to a
# sibling temp file then renames over the target so a concurrent reader never
# observes a half-written file.
function Save-OverridesHashtable {
    param([Parameter(Mandatory)] [hashtable]$Overrides)
    if (-not (Test-Path $script:Config.ControlDir)) {
        New-Item -ItemType Directory -Path $script:Config.ControlDir -Force | Out-Null
    }
    $overridesFile = Join-Path $script:Config.ControlDir "settings.json"

    # Capture the prior on-disk state BEFORE the write so the inbound decision
    # funnel can diff old vs new (issue #416). Runs inside the settings mutex
    # held by Invoke-SettingsFileLocked, so no extra lock is taken here.
    $priorOverrides = $null
    if (Test-Path $overridesFile) {
        try { $priorOverrides = Get-Content $overridesFile -Raw | ConvertFrom-Json } catch { $priorOverrides = $null }
    }

    $tmp = "$overridesFile.tmp"
    $Overrides | ConvertTo-Json -Depth 10 | Set-Content $tmp -Force -Encoding utf8NoBOM
    Move-Item -LiteralPath $tmp -Destination $overridesFile -Force

    Invoke-SettingsInboundDecisions -Prior $priorOverrides -New $Overrides
}

# Flatten a settings object to a map of dotted-path -> stringified leaf value.
# Objects recurse; arrays are treated as a single leaf (compact JSON) so that
# file_listener.watchers compares as one value rather than per-element.
function Get-FlatSettingLeaves {
    param($Object, [string]$Prefix = '')
    $leaves = @{}
    if ($null -eq $Object) { return $leaves }

    $props = @()
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($k in $Object.Keys) { $props += , @("$k", $Object[$k]) }
    } elseif ($Object -is [PSCustomObject]) {
        foreach ($p in $Object.PSObject.Properties) { $props += , @($p.Name, $p.Value) }
    } else {
        return $leaves
    }

    foreach ($pair in $props) {
        $name = $pair[0]; $val = $pair[1]
        $path = if ($Prefix) { "$Prefix.$name" } else { "$name" }
        if ($val -is [System.Collections.IDictionary] -or $val -is [PSCustomObject]) {
            $child = Get-FlatSettingLeaves -Object $val -Prefix $path
            foreach ($ck in $child.Keys) { $leaves[$ck] = $child[$ck] }
        } elseif (($val -is [System.Array]) -or ($val -is [System.Collections.IList] -and $val -isnot [string])) {
            $leaves[$path] = ($val | ConvertTo-Json -Depth 10 -Compress)
        } else {
            $leaves[$path] = "$val"
        }
    }
    return $leaves
}

# Best-effort: diff prior vs new settings leaves and route each changed key
# through the inbound funnel. The funnel owns the material-key allow-list, so
# this caller deliberately passes EVERY changed key and lets non-material keys
# be dropped there (single vocabulary source). A failure must not fail the save.
function Invoke-SettingsInboundDecisions {
    param($Prior, $New)
    try {
        if (-not (Get-Command New-InboundDecision -ErrorAction SilentlyContinue)) {
            Import-Module (Join-Path $PSScriptRoot ".." ".." "runtime" "Modules" "Dotbot.Decision" "Dotbot.Decision.psd1") -DisableNameChecking -Global -ErrorAction Stop
        }

        $priorLeaves = Get-FlatSettingLeaves -Object $Prior
        $newLeaves = Get-FlatSettingLeaves -Object $New

        $allKeys = @($priorLeaves.Keys) + @($newLeaves.Keys) | Select-Object -Unique
        foreach ($key in $allKeys) {
            $before = if ($priorLeaves.ContainsKey($key)) { $priorLeaves[$key] } else { $null }
            $after = if ($newLeaves.ContainsKey($key)) { $newLeaves[$key] } else { $null }
            if ("$before" -eq "$after") { continue }
            $null = New-InboundDecision -Source settings -BotPath $script:Config.BotRoot -Payload @{
                key    = $key
                before = $before
                after  = $after
            }
        }
    } catch {
        if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
            Write-BotLog -Level Warn -Message "Inbound decision funnel (settings) failed" -Exception $_
        }
    }
}

# Internal: run a script block under an OS-level named mutex keyed on the
# settings.json path, so concurrent writers (multiple UI sessions or concurrent
# workflow runs, in this or other processes) serialize their read-modify-write
# cycles instead of clobbering each other. Acquisition blocks with no timeout
# and no poll; a crashed holder is released by the kernel (next waiter granted
# ownership via AbandonedMutexException) — no stale lock, no wall-clock timer.
# (Primitive intentionally duplicated per-module to avoid load-order coupling.)
function Invoke-WithNamedMutex {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    # Internal locals are '$__nm'-prefixed so they cannot shadow any variable the
    # caller's $Action references via dynamic scope when invoked with '& $Action'.
    $__nmSha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $__nmHash = ([System.BitConverter]::ToString(
            $__nmSha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Name))) -replace '-', '').Substring(0, 32)
    } finally {
        $__nmSha.Dispose()
    }
    $__nmMutex = [System.Threading.Mutex]::new($false, "Global\dotbot-$__nmHash")
    $__nmOwns = $false
    try {
        try {
            $__nmOwns = $__nmMutex.WaitOne()
        } catch [System.Threading.AbandonedMutexException] {
            $__nmOwns = $true
        }
        return (& $Action)
    } finally {
        if ($__nmOwns) { try { $__nmMutex.ReleaseMutex() } catch { $null = $_ } }
        $__nmMutex.Dispose()
    }
}

function Invoke-SettingsFileLocked {
    param(
        [Parameter(Mandatory)][scriptblock]$Action
    )
    if (-not (Test-Path $script:Config.ControlDir)) {
        New-Item -ItemType Directory -Path $script:Config.ControlDir -Force | Out-Null
    }
    # Note: avoid a local named '$key' here — '& $Action' uses dynamic scope, and
    # Save-OverrideSection's action references '$Key' (case-insensitive match),
    # which a local '$key' on this frame would shadow.
    $mutexName = "settings:" + [System.IO.Path]::GetFullPath((Join-Path $script:Config.ControlDir "settings.json"))
    Invoke-WithNamedMutex -Name $mutexName -Action $Action
}

# Internal: merge a partial section (or top-level scalars) into .control/settings.json.
# - $Key is the section name (e.g. 'analysis', 'mothership'). When $null, $Patch keys are
#   merged at the top level (used for scalars like 'provider').
# - $Patch is a hashtable of fields to set/replace.
function Save-OverrideSection {
    param(
        [string]$Key,
        [Parameter(Mandatory)] [hashtable]$Patch
    )
    Invoke-SettingsFileLocked -Action {
    $overrides = Get-OverridesHashtable
    if ($Key) {
        $existingSection = if ($overrides.ContainsKey($Key)) { $overrides[$Key] } else { @{} }
        # Normalize persisted section values to a hashtable so Merge-DeepSettings only receives
        # object-like data. Treat $null and scalar/array values as an empty section.
        if ($null -eq $existingSection) {
            $existingSection = @{}
        } elseif ($existingSection -is [hashtable]) {
            # Already normalized.
        } elseif ($existingSection -is [System.Collections.IDictionary]) {
            $h = @{}
            foreach ($k in $existingSection.Keys) { $h[$k] = $existingSection[$k] }
            $existingSection = $h
        } elseif ($existingSection -is [PSCustomObject]) {
            $h = @{}
            foreach ($p in $existingSection.PSObject.Properties) { $h[$p.Name] = $p.Value }
            $existingSection = $h
        } else {
            $existingSection = @{}
        }
        $merged = Merge-DeepSettings $existingSection $Patch
        # Merge-DeepSettings returns an [ordered] dict; convert to plain hashtable for ConvertTo-Json fidelity.
        $sectionHash = @{}
        foreach ($k in $merged.Keys) { $sectionHash[$k] = $merged[$k] }
        $overrides[$Key] = $sectionHash
    } else {
        foreach ($k in $Patch.Keys) {
            $overrides[$k] = $Patch[$k]
        }
    }
    Save-OverridesHashtable -Overrides $overrides
    }
}

function Get-DefaultModelTier {
    try {
        $providerConfig = Get-HarnessConfig
        if ($providerConfig.default_model) { return [string]$providerConfig.default_model }
    } catch {
        if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
            Write-BotLog -Level Debug -Message "Failed to resolve default model tier" -Exception $_
        }
    }
    return "best"
}

function Resolve-UiModelTier {
    param([string]$Model)

    try {
        return Resolve-HarnessModelTier -Model $Model
    } catch {
        if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
            Write-BotLog -Level Debug -Message "Failed to resolve UI model tier '$Model'" -Exception $_
        }
        return Get-DefaultModelTier
    }
}

function Resolve-ProviderConfigFile {
    param([Parameter(Mandatory)][string]$ProviderName)

    $projectProviderFile = Join-Path $script:Config.BotRoot "settings/providers/$ProviderName.json"
    if (Test-Path $projectProviderFile) { return $projectProviderFile }

    $frameworkProviderFile = Join-Path (Get-DotbotInstallPath) "content/settings/providers/$ProviderName.json"
    if (Test-Path $frameworkProviderFile) { return $frameworkProviderFile }

    return $null
}

function Get-Theme {
    $themePath = Join-Path $script:Config.StaticRoot "theme-config.json"
    $settingsFile = Join-Path $script:Config.ControlDir "ui-settings.json"

    if (-not (Test-Path $themePath)) {
        return @{ _statusCode = 404; success = $false; error = "Theme config not found" }
    }

    try {
        # Load presets from theme-config.json
        $themeConfig = Get-Content $themePath -Raw | ConvertFrom-Json

        # Get active theme from ui-settings.json (default to "amber")
        $activeTheme = "amber"
        if (Test-Path $settingsFile) {
            try {
                $settings = Get-Content $settingsFile -Raw | ConvertFrom-Json
                if ($settings.theme) {
                    $activeTheme = $settings.theme
                }
            } catch { Write-BotLog -Level Debug -Message "Failed to parse data" -Exception $_ }
        }

        # Validate active theme exists
        if (-not $themeConfig.presets.($activeTheme)) {
            $activeTheme = "amber"
        }

        # Build response with computed mappings
        $preset = $themeConfig.presets.($activeTheme)
        $mappings = @{}
        foreach ($key in $preset.PSObject.Properties.Name) {
            if ($key -ne "name") {
                $rgb = $preset.$key
                $mappings[$key] = @{ r = $rgb[0]; g = $rgb[1]; b = $rgb[2] }
            }
        }

        return @{
            name = $preset.name
            mappings = $mappings
            presets = $themeConfig.presets
        }
    } catch {
        return @{ _statusCode = 500; success = $false; error = "Failed to load theme: $($_.Exception.Message)" }
    }
}

function Set-Theme {
    param(
        [Parameter(Mandatory)] $Body
    )
    $themePath = Join-Path $script:Config.StaticRoot "theme-config.json"
    $settingsFile = Join-Path $script:Config.ControlDir "ui-settings.json"

    if (-not (Test-Path $themePath)) {
        return @{ _statusCode = 404; success = $false; error = "Theme config not found" }
    }

    # Load presets
    $themeConfig = Get-Content $themePath -Raw | ConvertFrom-Json

    # Validate preset exists
    if (-not $Body.preset -or -not $themeConfig.presets.($Body.preset)) {
        return @{ _statusCode = 400; success = $false; error = "Invalid preset: $($Body.preset)" }
    }

    # Load or create settings as hashtable
    $settings = @{
        showDebug = $false
        showVerbose = $false
        theme = "amber"
    }
    if (Test-Path $settingsFile) {
        try {
            $existingSettings = Get-Content $settingsFile -Raw | ConvertFrom-Json
            foreach ($prop in $existingSettings.PSObject.Properties) {
                $settings[$prop.Name] = $prop.Value
            }
        } catch { Write-BotLog -Level Debug -Message "Failed to parse data" -Exception $_ }
    }

    # Update theme preference
    $settings.theme = $Body.preset

    # Save settings
    $settings | ConvertTo-Json -Depth 5 | Set-Content $settingsFile -Force

    # Build response with computed mappings
    $preset = $themeConfig.presets.($Body.preset)
    $mappings = @{}
    foreach ($key in $preset.PSObject.Properties.Name) {
        if ($key -ne "name") {
            $rgb = $preset.$key
            $mappings[$key] = @{ r = $rgb[0]; g = $rgb[1]; b = $rgb[2] }
        }
    }

    return @{
        name = $preset.name
        mappings = $mappings
        presets = $themeConfig.presets
    }
}

function Get-Settings {
    $settingsFile = Join-Path $script:Config.ControlDir "ui-settings.json"
    $defaultModelTier = Get-DefaultModelTier
    $defaultSettings = @{
        showDebug = $false
        showVerbose = $false
        analysisModel = $defaultModelTier
        executionModel = $defaultModelTier
        permissionMode = $null
    }

    $settings = $defaultSettings.Clone()
    if (Test-Path $settingsFile) {
        try {
            $existingSettings = Get-Content $settingsFile -Raw | ConvertFrom-Json
            foreach ($prop in $existingSettings.PSObject.Properties) {
                $settings[$prop.Name] = $prop.Value
            }
        } catch {
            return $settings
        }
    }

    $settings.analysisModel = Resolve-UiModelTier -Model ([string]$settings.analysisModel)
    $settings.executionModel = Resolve-UiModelTier -Model ([string]$settings.executionModel)
    return $settings
}

function Set-Settings {
    param(
        [Parameter(Mandatory)] $Body
    )
    $settingsFile = Join-Path $script:Config.ControlDir "ui-settings.json"
    $defaultModelTier = Get-DefaultModelTier
    $defaultSettings = @{
        showDebug = $false
        showVerbose = $false
        analysisModel = $defaultModelTier
        executionModel = $defaultModelTier
        permissionMode = $null
    }

    # Load existing settings into defaults hashtable
    $settings = $defaultSettings.Clone()
    if (Test-Path $settingsFile) {
        try {
            $existingSettings = Get-Content $settingsFile -Raw | ConvertFrom-Json
            foreach ($prop in $existingSettings.PSObject.Properties) {
                $settings[$prop.Name] = $prop.Value
            }
        } catch { Write-BotLog -Level Debug -Message "Failed to parse data" -Exception $_ }
    }

    # Update settings with provided values
    if ($null -ne $Body.showDebug) {
        $settings.showDebug = [bool]$Body.showDebug
    }
    if ($null -ne $Body.showVerbose) {
        $settings.showVerbose = [bool]$Body.showVerbose
    }
    if ($null -ne $Body.analysisModel) {
        try {
            $settings.analysisModel = Resolve-HarnessModelTier -Model ([string]$Body.analysisModel)
        } catch {
            return @{ _statusCode = 400; success = $false; error = "Invalid model tier '$($Body.analysisModel)' for active provider" }
        }
    }
    if ($null -ne $Body.executionModel) {
        try {
            $settings.executionModel = Resolve-HarnessModelTier -Model ([string]$Body.executionModel)
        } catch {
            return @{ _statusCode = 400; success = $false; error = "Invalid model tier '$($Body.executionModel)' for active provider" }
        }
    }
    if ($Body.PSObject.Properties.Name -contains 'permissionMode') {
        if ($null -eq $Body.permissionMode) {
            $settings.permissionMode = $null
        } else {
            $modeValue = [string]$Body.permissionMode
            # Validate against active provider's permission modes
            $providerConfig = Get-HarnessConfig
            if ($providerConfig.permission_modes -and $providerConfig.permission_modes.PSObject.Properties.Name -contains $modeValue) {
                $settings.permissionMode = $modeValue
            } else {
                return @{ _statusCode = 400; success = $false; error = "Invalid permission mode '$modeValue' for active provider '$($providerConfig.name)'" }
            }
        }
    }

    # Save settings
    $settings | ConvertTo-Json | Set-Content $settingsFile -Force
    Write-Status "Settings updated: Debug=$($settings.showDebug), Verbose=$($settings.showVerbose)" -Type Success

    return @{
        success = $true
        settings = $settings
    }
}

function Get-AnalysisConfig {
    try {
        $settingsData = Get-MergedSettings -BotRoot $script:Config.BotRoot
        $analysis = if ($settingsData.analysis) { $settingsData.analysis } else {
            @{ auto_approve_splits = $false; split_threshold_effort = "XL"; question_timeout_hours = $null; mode = "on-demand" }
        }
        return $analysis
    } catch {
        return @{ _statusCode = 500; error = "Failed to read analysis config: $($_.Exception.Message)" }
    }
}

function Set-AnalysisConfig {
    param(
        [Parameter(Mandatory)] $Body
    )
    $patch = @{}

    if ($null -ne $Body.auto_approve_splits) {
        $patch.auto_approve_splits = [bool]$Body.auto_approve_splits
    }
    if ($null -ne $Body.split_threshold_effort) {
        $patch.split_threshold_effort = [string]$Body.split_threshold_effort
    }
    if ($Body.PSObject.Properties.Name -contains 'question_timeout_hours') {
        if ($null -eq $Body.question_timeout_hours) {
            $patch.question_timeout_hours = $null
        } else {
            $patch.question_timeout_hours = [int]$Body.question_timeout_hours
        }
    }
    if ($null -ne $Body.mode) {
        $patch.mode = [string]$Body.mode
    }

    Save-OverrideSection -Key 'analysis' -Patch $patch
    Write-Status "Analysis config updated" -Type Success

    $merged = Get-MergedSettings -BotRoot $script:Config.BotRoot
    return @{
        success = $true
        analysis = $merged.analysis
    }
}

function Get-GitConfig {
    $settingsData = Get-MergedSettings -BotRoot $script:Config.BotRoot
    if ($settingsData.git) {
        return $settingsData.git
    }
    return @{ base_branch = $null }
}

function Set-GitConfig {
    param(
        [Parameter(Mandatory)] $Body
    )
    $patch = @{}

    if ($Body.PSObject.Properties.Name -contains 'base_branch') {
        if ([string]::IsNullOrWhiteSpace([string]$Body.base_branch)) {
            $patch.base_branch = $null
        } else {
            $patch.base_branch = [string]$Body.base_branch
        }
    }

    Save-OverrideSection -Key 'git' -Patch $patch
    Write-Status "Git config updated" -Type Success

    $merged = Get-MergedSettings -BotRoot $script:Config.BotRoot
    return @{
        success = $true
        git = $merged.git
    }
}

function Resolve-VerifyConfigPath {
    # Project tier first; framework default fallback. Reads prefer the
    # project override; writes always target the project path so the
    # override is created lazily.
    $projectConfig = Join-Path $script:Config.BotRoot "hooks/verify/config.json"
    if (Test-Path $projectConfig) { return $projectConfig }
    $frameworkConfig = Join-Path (Get-DotbotInstallPath) "src/hooks/verify/config.json"
    if (Test-Path $frameworkConfig) { return $frameworkConfig }
    return $null
}

function Get-VerificationConfig {
    $verifyConfigFile = Resolve-VerifyConfigPath
    if (-not $verifyConfigFile) {
        return @{ _statusCode = 500; error = "Verification config not found in project or framework." }
    }

    try {
        return Get-Content $verifyConfigFile -Raw | ConvertFrom-Json
    } catch {
        return @{ _statusCode = 500; error = "Failed to read verification config: $($_.Exception.Message)" }
    }
}

function Set-VerificationConfig {
    param(
        [Parameter(Mandatory)] $Body
    )
    # Read from whichever layer currently has the config. Writes go to the
    # project tier so toggling a script materialises a project override.
    $sourceConfig = Resolve-VerifyConfigPath
    if (-not $sourceConfig) {
        return @{ _statusCode = 500; success = $false; error = "Verification config not found in project or framework." }
    }
    $projectConfigFile = Join-Path $script:Config.BotRoot "hooks/verify/config.json"

    $verifyData = Get-Content $sourceConfig -Raw | ConvertFrom-Json
    $scriptName = $Body.name

    # Find the script entry
    $scriptEntry = $verifyData.scripts | Where-Object { $_.name -eq $scriptName }
    if (-not $scriptEntry) {
        return @{ _statusCode = 404; success = $false; error = "Script not found: $scriptName" }
    }
    elseif ($scriptEntry.core -eq $true) {
        return @{ _statusCode = 400; success = $false; error = "Cannot modify core verification script: $scriptName" }
    }

    $scriptEntry.required = [bool]$Body.required
    $projectParent = Split-Path -Parent $projectConfigFile
    if (-not (Test-Path $projectParent)) {
        New-Item -ItemType Directory -Force -Path $projectParent | Out-Null
    }
    $verifyData | ConvertTo-Json -Depth 5 | Set-Content $projectConfigFile -Force
    Write-Status "Verification config updated: $scriptName required=$($scriptEntry.required)" -Type Success

    return @{
        success = $true
        scripts = $verifyData.scripts
    }
}

function Get-CostConfig {
    try {
        $settingsData = Get-MergedSettings -BotRoot $script:Config.BotRoot
        $costs = if ($settingsData.costs) { $settingsData.costs } else {
            @{ hourly_rate = 50; ai_cost_per_task = 0.50; ai_speedup_factor = 10; currency = "USD" }
        }
        return $costs
    } catch {
        return @{ _statusCode = 500; error = "Failed to read cost config: $($_.Exception.Message)" }
    }
}

function Set-CostConfig {
    param(
        [Parameter(Mandatory)] $Body
    )
    $patch = @{}

    if ($null -ne $Body.hourly_rate) {
        $patch.hourly_rate = [decimal]$Body.hourly_rate
    }
    if ($null -ne $Body.ai_cost_per_task) {
        $patch.ai_cost_per_task = [decimal]$Body.ai_cost_per_task
    }
    if ($null -ne $Body.ai_speedup_factor) {
        $patch.ai_speedup_factor = [decimal]$Body.ai_speedup_factor
    }
    if ($null -ne $Body.currency) {
        $patch.currency = [string]$Body.currency
    }

    Save-OverrideSection -Key 'costs' -Patch $patch
    Write-Status "Cost config updated" -Type Success

    $merged = Get-MergedSettings -BotRoot $script:Config.BotRoot
    return @{
        success = $true
        costs = $merged.costs
    }
}

# Editor command registry — single source of truth for editor metadata
$script:EditorRegistry = @(
    @{ id = 'vscode';         name = 'VS Code';          commands = @('code') }
    @{ id = 'visual-studio';  name = 'Visual Studio';    commands = @('devenv') }
    @{ id = 'cursor';         name = 'Cursor';           commands = @('cursor') }
    @{ id = 'windsurf';       name = 'Windsurf';         commands = @('windsurf') }
    @{ id = 'rider';          name = 'JetBrains Rider';  commands = @('rider64', 'rider', 'rider.sh') }
    @{ id = 'idea';           name = 'JetBrains IDEA';   commands = @('idea64', 'idea', 'idea.sh') }
    @{ id = 'webstorm';       name = 'WebStorm';         commands = @('webstorm64', 'webstorm', 'webstorm.sh') }
    @{ id = 'sublime';        name = 'Sublime Text';     commands = @('subl', 'sublime_text') }
    @{ id = 'atom';           name = 'Atom';             commands = @('atom') }
    @{ id = 'notepadpp';      name = 'Notepad++';        commands = @('notepad++') }
    @{ id = 'vim';            name = 'Vim';              commands = @('vim') }
    @{ id = 'neovim';         name = 'Neovim';           commands = @('nvim') }
    @{ id = 'emacs';          name = 'Emacs';            commands = @('emacs', 'emacsclient') }
    @{ id = 'nano';           name = 'Nano';             commands = @('nano') }
    @{ id = 'helix';          name = 'Helix';            commands = @('hx') }
)

# Cached detection result
$script:InstalledEditorIds = $null

function Get-InstalledEditors {
    param([switch]$Refresh)

    if ($script:InstalledEditorIds -and -not $Refresh) {
        return $script:InstalledEditorIds
    }

    $installed = @()
    foreach ($editor in $script:EditorRegistry) {
        $found = $false
        foreach ($cmd in $editor.commands) {
            try {
                $result = Get-Command $cmd -ErrorAction SilentlyContinue
                if ($result) {
                    $found = $true
                    break
                }
            } catch { Write-BotLog -Level Debug -Message "Non-critical operation failed" -Exception $_ }
        }
        if ($found) {
            $installed += $editor.id
        }
    }

    $script:InstalledEditorIds = $installed
    return $installed
}

function Get-EditorRegistry {
    param([switch]$Refresh)

    $installed = Get-InstalledEditors -Refresh:$Refresh
    $editors = @()
    foreach ($entry in $script:EditorRegistry) {
        $editors += @{
            id        = $entry.id
            name      = $entry.name
            installed = ($entry.id -in $installed)
        }
    }
    return @{ editors = $editors; installed = $installed }
}

function Get-EditorConfig {
    try {
        $settingsData = Get-MergedSettings -BotRoot $script:Config.BotRoot
        $editor = if ($settingsData.editor) { $settingsData.editor } else {
            @{ name = 'off'; custom_command = '' }
        }

        # Include installed editors (cached)
        $installed = Get-InstalledEditors

        return @{
            name = if ($editor.name) { $editor.name } else { 'off' }
            custom_command = if ($editor.custom_command) { $editor.custom_command } else { '' }
            installed = $installed
        }
    } catch {
        return @{ _statusCode = 500; error = "Failed to read editor config: $($_.Exception.Message)" }
    }
}

function Set-EditorConfig {
    param(
        [Parameter(Mandatory)] $Body
    )
    $patch = @{}

    if ($null -ne $Body.name) {
        # Validate against allowlist
        $allowedNames = @('off', 'custom') + ($script:EditorRegistry | ForEach-Object { $_.id })
        $requestedName = [string]$Body.name
        if ($requestedName -notin $allowedNames) {
            return @{ _statusCode = 400; success = $false; error = "Invalid editor name: $requestedName" }
        }

        # For better UX, ensure that non-'off' and non-'custom' editors are actually available
        if ($requestedName -ne 'off' -and $requestedName -ne 'custom') {
            $installed = Get-InstalledEditors
            if ($requestedName -notin $installed) {
                return @{
                    _statusCode = 400
                    success     = $false
                    error       = "Selected editor '$requestedName' does not appear to be installed or available in PATH."
                }
            }
        }
        $patch.name = $requestedName
    }
    if ($null -ne $Body.custom_command) {
        $customCommand = [string]$Body.custom_command
        $maxCustomCommandLength = 500
        if ($customCommand.Length -gt $maxCustomCommandLength) {
            return @{
                _statusCode = 400
                success     = $false
                error       = "custom_command exceeds maximum length of $maxCustomCommandLength characters."
            }
        }
        $patch.custom_command = $customCommand
    }

    Save-OverrideSection -Key 'editor' -Patch $patch
    $merged = Get-MergedSettings -BotRoot $script:Config.BotRoot
    Write-Status "Editor config updated: $($merged.editor.name)" -Type Success

    return @{
        success = $true
        editor = $merged.editor
    }
}

$script:ProviderProbeCache = $null

function Get-ProviderProbe {
    param(
        [Parameter(Mandatory)] $Config,
        [switch]$Refresh
    )

    # Return cached result if available
    $providerName = $Config.name
    if (-not $Refresh -and $script:ProviderProbeCache -and $script:ProviderProbeCache.ContainsKey($providerName)) {
        return $script:ProviderProbeCache[$providerName]
    }

    if (-not $script:ProviderProbeCache) { $script:ProviderProbeCache = @{} }

    $result = @{
        version    = $null
        accessible = $false
        plan_type  = $null
    }

    $exe = $Config.executable
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) {
        if ($providerName -eq 'copilot' -and (Get-Command gh -ErrorAction SilentlyContinue)) {
            $exe = 'gh'
        } else {
            $script:ProviderProbeCache[$providerName] = $result
            return $result
        }
    }

    # Version probe (all providers)
    try {
        $versionOutput = & $exe --version 2>$null
        if ($versionOutput) {
            # Extract version string — handle formats like "claude v1.0.42", "codex-cli 0.88.0", "0.31.0"
            $versionMatch = [regex]::Match("$versionOutput", '(\d+\.\d+[\.\d]*)')
            if ($versionMatch.Success) { $result.version = $versionMatch.Groups[1].Value }
        }
    } catch { Write-BotLog -Level Debug -Message "Version probe failed for $providerName" -Exception $_ }

    # Auth/accessibility probe (provider-specific, using configured executable)
    switch ($providerName) {
        'claude' {
            try {
                $authJson = & $exe auth status --json 2>$null
                if ($authJson) {
                    $authData = $authJson | ConvertFrom-Json
                    $result.accessible = $true
                    if ($authData.subscriptionType) {
                        $result.plan_type = $authData.subscriptionType
                    }
                }
            } catch { Write-BotLog -Level Debug -Message "Auth probe failed for claude" -Exception $_ }
        }
        'codex' {
            try {
                & $exe login status 2>$null
                $result.accessible = ($LASTEXITCODE -eq 0)
            } catch { Write-BotLog -Level Debug -Message "Auth probe failed for codex" -Exception $_ }
        }
        'antigravity' {
            if ($env:ANTIGRAVITY_API_KEY -or $env:GEMINI_API_KEY -or $env:GOOGLE_API_KEY) {
                $result.accessible = $true
            } else {
                # Check for Google OAuth login
                $googleAccountsFile = Join-Path $HOME ".antigravity" "google_accounts.json"
                if (Test-Path $googleAccountsFile) {
                    try {
                        $accounts = Get-Content $googleAccountsFile -Raw | ConvertFrom-Json
                        $result.accessible = [bool]$accounts.active
                    } catch { Write-BotLog -Level Debug -Message "Antigravity OAuth check failed" -Exception $_ }
                }
            }
        }
        'opencode' {
            # OpenCode is multi-provider: any configured credential makes it accessible.
            # Credentials live in ~/.local/share/opencode/auth.json (managed by
            # `opencode auth login`) or in provider-specific env vars.
            if ($env:ANTHROPIC_API_KEY -or $env:OPENAI_API_KEY -or $env:GEMINI_API_KEY -or $env:GOOGLE_API_KEY) {
                $result.accessible = $true
            } else {
                $authFile = Join-Path $HOME ".local" "share" "opencode" "auth.json"
                if (Test-Path $authFile) {
                    try {
                        $auth = Get-Content $authFile -Raw | ConvertFrom-Json
                        $hasProvider = @($auth.PSObject.Properties).Count -gt 0
                        $result.accessible = $hasProvider
                    } catch { Write-BotLog -Level Debug -Message "OpenCode auth probe failed" -Exception $_ }
                }
            }
        }
        'copilot' {
            # Copilot CLI can authenticate via env vars or the system credential
            # store. There is no stable non-interactive auth-status command, so
            # installed means selectable; prompt execution will surface auth
            # failures with the provider's own message.
            $result.accessible = $true
        }
        default {
            # For unknown providers, assume accessible if installed
            $result.accessible = $true
        }
    }

    $script:ProviderProbeCache[$providerName] = $result
    return $result
}

function Get-ProviderList {
    # Enumerate providers across project (<BotRoot>/settings/providers/) and
    # framework (<DOTBOT_HOME>/content/settings/providers/) layers.
    # Project overrides win on filename collision; framework-only entries
    # still appear so the UI can show the full picker.
    $providerFiles = [ordered]@{}
    $projectProvidersDir = Join-Path $script:Config.BotRoot "settings/providers"
    if (Test-Path $projectProvidersDir) {
        Get-ChildItem $projectProvidersDir -Filter "*.json" -File | ForEach-Object {
            $providerFiles[$_.Name] = $_
        }
    }
    $frameworkProvidersDir = Join-Path (Get-DotbotInstallPath) "content/settings/providers"
    if (Test-Path $frameworkProvidersDir) {
        Get-ChildItem $frameworkProvidersDir -Filter "*.json" -File | ForEach-Object {
            if (-not $providerFiles.Contains($_.Name)) {
                $providerFiles[$_.Name] = $_
            }
        }
    }

    try {
        # Read active provider and permission mode from the merged settings chain
        $activeProvider = 'claude'
        $settingsPermMode = $null
        $settingsData = Get-MergedSettings -BotRoot $script:Config.BotRoot
        if ($settingsData.PSObject.Properties['provider'] -and $settingsData.provider) { $activeProvider = $settingsData.provider }
        if ($settingsData.PSObject.Properties['permission_mode'] -and $settingsData.permission_mode) { $settingsPermMode = $settingsData.permission_mode }

        # Migrate legacy "gemini" to "antigravity" so upgraded projects don't
        # render an empty model picker; the dispatcher does the same mapping.
        if ($activeProvider -eq 'gemini') { $activeProvider = 'antigravity' }

        # If the resolved active provider has no matching JSON on disk, fall
        # back to claude so the UI shows a populated picker instead of going
        # silently empty.
        $availableNames = @($providerFiles.Values | ForEach-Object { ($_.BaseName) })
        if ($availableNames -notcontains $activeProvider) {
            Write-BotLog -Level Warn -Message "Active provider '$activeProvider' has no provider JSON; falling back to 'claude' for UI rendering."
            $activeProvider = 'claude'
        }

        # Check ui-settings for permission mode override
        $uiSettingsFile = Join-Path $script:Config.ControlDir "ui-settings.json"
        if (Test-Path $uiSettingsFile) {
            try {
                $uiSettings = Get-Content $uiSettingsFile -Raw | ConvertFrom-Json
                if ($uiSettings.permissionMode) { $settingsPermMode = $uiSettings.permissionMode }
            } catch { Write-BotLog -Level Debug -Message "Failed to parse data" -Exception $_ }
        }

        # Read all provider config files
        $providers = @()
        $activeModels = @()
        $activePermModes = $null
        $activeDefaultPermMode = $null
        $activeDefaultModel = $null

        if ($providerFiles.Count -gt 0) {
            $providerFiles.Values | ForEach-Object {
                try {
                    $config = Get-Content $_.FullName -Raw | ConvertFrom-Json
                    $installed = $false
                    try {
                        $exe = $config.executable
                        if (Get-Command $exe -ErrorAction SilentlyContinue) { $installed = $true }
                    } catch { Write-BotLog -Level Debug -Message "Failed to parse data" -Exception $_ }

                    # Probe version, auth, plan type
                    $probe = @{ version = $null; accessible = $false; plan_type = $null }
                    if ($installed) {
                        $probe = Get-ProviderProbe -Config $config
                    }

                    $providers += @{
                        name         = $config.name
                        display_name = $config.display_name
                        installed    = $installed
                        version      = $probe.version
                        accessible   = $probe.accessible
                        plan_type    = $probe.plan_type
                    }

                    # Build models and permission modes for active provider
                    if ($config.name -eq $activeProvider) {
                        $mergedConfig = $null
                        try {
                            $mergedConfig = Get-HarnessConfig -Name $config.name
                        } catch {
                            Write-BotLog -Level Debug -Message "Failed to load merged harness config for UI provider list" -Exception $_
                            $mergedConfig = $config
                        }
                        $activeDefaultModel = $mergedConfig.default_model
                        if (-not $activeDefaultModel) { $activeDefaultModel = 'best' }
                        $modelRows = @()
                        try {
                            if ($mergedConfig.adapter) {
                                $modelRows = @(Get-HarnessModels -HarnessName $config.name)
                            }
                        } catch {
                            Write-BotLog -Level Debug -Message "Failed to load harness models for UI provider list" -Exception $_
                        }
                        if ($modelRows.Count -eq 0 -and $mergedConfig.models) {
                            foreach ($tier in @('fast', 'balanced', 'best')) {
                                $entry = $mergedConfig.models.PSObject.Properties[$tier]
                                if ($entry) {
                                    $value = $entry.Value
                                    $modelRows += [pscustomobject]@{
                                        Tier = $tier
                                        Name = if ($value.display_name) { $value.display_name } else { $tier }
                                        Badge = if ($value.badge) { $value.badge } else { $null }
                                        Description = if ($value.description) { $value.description } else { '' }
                                        IsDefault = ($tier -eq $activeDefaultModel)
                                    }
                                }
                            }
                        }
                        foreach ($m in $modelRows) {
                            $activeModels += @{
                                id = $m.Tier
                                tier = $m.Tier
                                name = $m.Name
                                badge = if ($m.badge) { $m.badge } else { $null }
                                description = $m.Description
                                is_default = [bool]$m.IsDefault
                            }
                        }

                        # Permission modes
                        if ($mergedConfig.permission_modes) {
                            $activePermModes = @{}
                            foreach ($key in $mergedConfig.permission_modes.PSObject.Properties.Name) {
                                $pm = $mergedConfig.permission_modes.$key
                                $activePermModes[$key] = @{
                                    display_name = $pm.display_name
                                    description  = $pm.description
                                    restrictions = if ($pm.restrictions) { $pm.restrictions } else { $null }
                                }
                            }
                            $activeDefaultPermMode = $mergedConfig.default_permission_mode
                        }
                    }
                } catch { Write-BotLog -Level Debug -Message "Non-critical operation failed" -Exception $_ }
            }
        }

        # Resolve active permission mode
        $activePermMode = $activeDefaultPermMode
        if ($settingsPermMode -and $activePermModes -and $activePermModes.ContainsKey($settingsPermMode)) {
            $activePermMode = $settingsPermMode
        }

        return @{
            providers               = $providers
            active                  = $activeProvider
            models                  = $activeModels
            default_model           = $activeDefaultModel
            permission_modes        = $activePermModes
            default_permission_mode = $activeDefaultPermMode
            active_permission_mode  = $activePermMode
        }
    } catch {
        return @{ _statusCode = 500; error = "Failed to read provider list: $($_.Exception.Message)" }
    }
}

function Set-ActiveProvider {
    param(
        [Parameter(Mandatory)] $Body
    )

    $providerName = $Body.provider
    if (-not $providerName) {
        return @{ _statusCode = 400; success = $false; error = "Missing 'provider' field" }
    }
    if ($providerName -notmatch '^[a-z0-9_-]+$') {
        return @{ _statusCode = 400; success = $false; error = "Invalid provider name: must be lowercase alphanumeric, hyphens, or underscores" }
    }

    # Validate provider exists
    $providerFile = Resolve-ProviderConfigFile -ProviderName $providerName
    if (-not $providerFile -or -not (Test-Path $providerFile)) {
        return @{ _statusCode = 400; success = $false; error = "Unknown provider: $providerName" }
    }

    try {
        Save-OverrideSection -Key $null -Patch @{ provider = $providerName }
    } catch {
        return @{ _statusCode = 500; success = $false; error = "Failed to write settings file: $($_.Exception.Message)" }
    }

    # Clear cached probe data so new provider gets fresh detection
    $script:ProviderProbeCache = $null

    # Reset permission mode (old mode may not exist on new provider)
    $uiSettingsFile = Join-Path $script:Config.ControlDir "ui-settings.json"
    if (Test-Path $uiSettingsFile) {
        try {
            $uiSettings = Get-Content $uiSettingsFile -Raw | ConvertFrom-Json
            if ($uiSettings.permissionMode) {
                $uiSettings.permissionMode = $null
                $uiSettings | ConvertTo-Json | Set-Content $uiSettingsFile -Force
            }
        } catch { Write-BotLog -Level Debug -Message "Failed to reset permission mode" -Exception $_ }
    }

    # Return updated provider list
    return Get-ProviderList
}

function Get-MothershipConfig {
    $uiSettingsFile = Join-Path $script:Config.ControlDir "ui-settings.json"

    $defaults = @{
        enabled               = $false
        server_url            = ""
        api_key               = ""
        channel               = "teams"
        recipients            = @()
        project_name          = ""
        project_description   = ""
        poll_interval_seconds = 30
        sync_tasks            = $true
        sync_questions        = $true
    }
    $soundEnabled = $false

    try {
        # Resolve the three-tier settings chain (settings.default → user-settings.json → .control/settings)
        $merged = Get-MergedSettings -BotRoot $script:Config.BotRoot
        $sectionKey = if ($merged.PSObject.Properties['mothership']) { 'mothership' }
                      elseif ($merged.PSObject.Properties['notifications']) { 'notifications' }
                      else { $null }
        if ($sectionKey) {
            $section = $merged.$sectionKey
            foreach ($prop in $section.PSObject.Properties) {
                if ($defaults.ContainsKey($prop.Name)) {
                    $defaults[$prop.Name] = $prop.Value
                }
            }
            if ($section.PSObject.Properties['sound_enabled']) {
                $soundEnabled = [bool]$section.sound_enabled
            }
        }

        # ui-settings.json is a separate local-UI-only file (theme, UI toggles). Not part of the merged chain.
        if (Test-Path $uiSettingsFile) {
            try {
                $uiSettings = Get-Content $uiSettingsFile -Raw | ConvertFrom-Json
                if ($uiSettings.PSObject.Properties['notificationSoundEnabled']) {
                    $soundEnabled = [bool]$uiSettings.notificationSoundEnabled
                }
            } catch { Write-BotLog -Level Debug -Message "Failed to parse data" -Exception $_ }
        }

        # Mask api_key for display (show last 4 chars only)
        $maskedKey = ""
        if ($defaults.api_key -and $defaults.api_key.Length -gt 4) {
            $maskedKey = ("*" * ($defaults.api_key.Length - 4)) + $defaults.api_key.Substring($defaults.api_key.Length - 4)
        } elseif ($defaults.api_key) {
            $maskedKey = "****"
        }

        return @{
            enabled               = $defaults.enabled
            sound_enabled         = $soundEnabled
            server_url            = $defaults.server_url
            api_key_masked        = $maskedKey
            api_key_set           = [bool]$defaults.api_key
            channel               = $defaults.channel
            recipients            = @($defaults.recipients)
            project_name          = $defaults.project_name
            project_description   = $defaults.project_description
            poll_interval_seconds = $defaults.poll_interval_seconds
            sync_tasks            = $defaults.sync_tasks
            sync_questions        = $defaults.sync_questions
        }
    } catch {
        return @{ _statusCode = 500; error = "Failed to read mothership config: $($_.Exception.Message)" }
    }
}

# Backward-compatible alias
function Get-NotificationConfig { return Get-MothershipConfig }

function Set-MothershipConfig {
    param(
        [Parameter(Mandatory)] $Body
    )
    $uiSettingsFile = Join-Path $script:Config.ControlDir "ui-settings.json"

    $legacySoundEnabled = $null

    # Single read of .control/settings.json; mutate in-memory; single save at end.
    $overrides = Get-OverridesHashtable
    $dirty = $false

    # Legacy 'notifications' -> 'mothership' migration.
    if ($overrides.ContainsKey('notifications') -and -not $overrides.ContainsKey('mothership')) {
        $overrides['mothership'] = $overrides['notifications']
        $overrides.Remove('notifications')
        $dirty = $true
    }

    # Ensure mothership section is a mutable hashtable.
    if (-not $overrides.ContainsKey('mothership')) {
        $overrides['mothership'] = @{}
    } elseif ($overrides['mothership'] -is [PSCustomObject]) {
        $h = @{}
        foreach ($p in $overrides['mothership'].PSObject.Properties) { $h[$p.Name] = $p.Value }
        $overrides['mothership'] = $h
        $dirty = $true
    }
    $section = $overrides['mothership']

    # Strip legacy sound_enabled (now lives in ui-settings.json, handled below).
    if ($section.ContainsKey('sound_enabled')) {
        $legacySoundEnabled = [bool]$section['sound_enabled']
        $section.Remove('sound_enabled')
        $dirty = $true
    }

    if ($null -ne $Body.enabled)    { $section['enabled']    = [bool]$Body.enabled;      $dirty = $true }
    if ($null -ne $Body.server_url) { $section['server_url'] = [string]$Body.server_url; $dirty = $true }
    if ($null -ne $Body.channel) {
        $validChannels = @("teams", "email", "jira", "slack")
        if ($Body.channel -in $validChannels) { $section['channel'] = [string]$Body.channel; $dirty = $true }
    }
    # recipients REPLACE (not merge) -- Merge-DeepSettings concat+dedups scalar arrays.
    if ($null -ne $Body.recipients) { $section['recipients'] = @($Body.recipients); $dirty = $true }
    if ($null -ne $Body.project_name)        { $section['project_name']        = [string]$Body.project_name;        $dirty = $true }
    if ($null -ne $Body.project_description) { $section['project_description'] = [string]$Body.project_description; $dirty = $true }
    if ($null -ne $Body.poll_interval_seconds) {
        $interval = [int]$Body.poll_interval_seconds
        if ($interval -lt 5) { $interval = 5 }
        $section['poll_interval_seconds'] = $interval
        $dirty = $true
    }
    if ($null -ne $Body.sync_tasks)     { $section['sync_tasks']     = [bool]$Body.sync_tasks;     $dirty = $true }
    if ($null -ne $Body.sync_questions) { $section['sync_questions'] = [bool]$Body.sync_questions; $dirty = $true }
    if ($null -ne $Body.api_key -and $Body.api_key -ne '') { $section['api_key'] = [string]$Body.api_key; $dirty = $true }

    if ($dirty) {
        Save-OverridesHashtable -Overrides $overrides
    }

    # ui-settings.json: notification sound is a UI-only preference, not a merged setting.
    $uiSettings = @{
        showDebug = $false
        showVerbose = $false
        analysisModel = "best"
        executionModel = "best"
    }
    $uiSettingsChanged = $false
    $uiSettingsHasSoundPreference = $false
    if (Test-Path $uiSettingsFile) {
        try {
            $existingUiSettings = Get-Content $uiSettingsFile -Raw | ConvertFrom-Json
            foreach ($prop in $existingUiSettings.PSObject.Properties) {
                $uiSettings[$prop.Name] = $prop.Value
            }
            if ($existingUiSettings.PSObject.Properties['notificationSoundEnabled']) {
                $uiSettingsHasSoundPreference = $true
            }
        } catch { Write-BotLog -Level Debug -Message "Failed to parse data" -Exception $_ }
    }

    if ($null -ne $Body.sound_enabled) {
        $uiSettings.notificationSoundEnabled = [bool]$Body.sound_enabled
        $uiSettingsChanged = $true
    } elseif (-not $uiSettingsHasSoundPreference -and $null -ne $legacySoundEnabled) {
        $uiSettings.notificationSoundEnabled = [bool]$legacySoundEnabled
        $uiSettingsChanged = $true
    }

    if ($uiSettingsChanged) {
        $uiSettings | ConvertTo-Json -Depth 5 | Set-Content $uiSettingsFile -Force
    }

    Write-Status "Mothership config updated" -Type Success

    return @{
        success = $true
        mothership = (Get-MothershipConfig)
    }
}

# Backward-compatible alias
function Set-NotificationConfig { param([Parameter(Mandatory)] $Body) return Set-MothershipConfig -Body $Body }

function Test-MothershipServerFromUI {
    $notifModule = Join-Path $PSScriptRoot ".." ".." "mcp" "modules" "NotificationClient.psm1"
    if (-not (Test-Path $notifModule)) {
        return @{ reachable = $false; error = "NotificationClient module not found" }
    }

    Import-Module $notifModule -Force
    $settings = Get-NotificationSettings -BotRoot $script:Config.BotRoot
    if (-not $settings.server_url) {
        return @{ reachable = $false; error = "No server URL configured" }
    }

    $reachable = Test-NotificationServer -Settings $settings
    return @{ reachable = $reachable; server_url = $settings.server_url }
}

# Backward-compatible alias
function Test-NotificationServerFromUI { return Test-MothershipServerFromUI }

function Invoke-OpenEditor {
    param(
        [Parameter(Mandatory)] [string]$ProjectRoot
    )

    try {
        $settingsData = Get-MergedSettings -BotRoot $script:Config.BotRoot
        $editor = $settingsData.editor
    } catch {
        return @{ _statusCode = 500; success = $false; error = "Failed to read editor config" }
    }

    if (-not $editor -or $editor.name -eq 'off') {
        return @{ _statusCode = 400; success = $false; error = "No editor configured" }
    }

    $editorName = $editor.name

    if ($editorName -eq 'custom') {
        $cmd = $editor.custom_command
        if (-not $cmd) {
            return @{ _statusCode = 400; success = $false; error = "No custom command configured" }
        }

        # Quote the project path to handle spaces
        $quotedPath = "`"$ProjectRoot`""

        # Replace {path} placeholder with quoted path, or append quoted path
        if ($cmd -match '\{path\}') {
            $cmd = $cmd -replace '\{path\}', $quotedPath
        } else {
            $cmd = "$cmd $quotedPath"
        }

        try {
            # Parse the command into executable and arguments, respecting quoted strings
            $exe = $null
            $argString = $null

            # First, handle a leading quoted executable path: "C:\Program Files\Editor\editor.exe" ...
            if ($cmd -match '^\s*"([^"]+)"\s*(.*)$') {
                $exe = $matches[1]
                $argString = $matches[2]
            }
            # Fallback: unquoted executable path: editor.exe ...
            elseif ($cmd -match '^\s*(\S+)\s*(.*)$') {
                $exe = $matches[1]
                $argString = $matches[2]
            }

            if (-not $exe) {
                throw "Unable to parse custom editor command."
            }

            # Build argument list array, respecting quoted arguments.
            # Note: escaped quotes inside quoted strings (e.g. "path\"with\"quotes")
            # are not supported. Use simple quoting: "C:\My Path\editor.exe" "C:\My Project"
            $argumentList = @()
            if ($argString) {
                $tokenPattern = '("[^"]*"|\S+)'
                foreach ($m in [System.Text.RegularExpressions.Regex]::Matches($argString, $tokenPattern)) {
                    $arg = $m.Value.Trim()
                    if ($arg.StartsWith('"') -and $arg.EndsWith('"') -and $arg.Length -ge 2) {
                        $arg = $arg.Substring(1, $arg.Length - 2)
                    }
                    if ($arg -ne '') {
                        $argumentList += $arg
                    }
                }
            }

            if ($argumentList.Count -gt 0) {
                Start-Process -FilePath $exe -ArgumentList $argumentList
            } else {
                Start-Process -FilePath $exe
            }
            return @{ success = $true; editor = 'Custom' }
        } catch {
            return @{ _statusCode = 500; success = $false; error = "Failed to launch custom editor: $($_.Exception.Message)" }
        }
    }

    # Predefined editor
    $registryEntry = $script:EditorRegistry | Where-Object { $_.id -eq $editorName }
    if (-not $registryEntry) {
        return @{ _statusCode = 400; success = $false; error = "Unknown editor: $editorName" }
    }

    # Find the installed command
    $foundCmd = $null
    foreach ($cmd in $registryEntry.commands) {
        try {
            if (Get-Command $cmd -ErrorAction SilentlyContinue) {
                $foundCmd = $cmd
                break
            }
        } catch { Write-BotLog -Level Debug -Message "Non-critical operation failed" -Exception $_ }
    }

    if (-not $foundCmd) {
        return @{ _statusCode = 400; success = $false; error = "Editor '$editorName' is not installed" }
    }

    try {
        Start-Process -FilePath $foundCmd -ArgumentList "`"$ProjectRoot`""
        return @{ success = $true; editor = $editorName }
    } catch {
        return @{ _statusCode = 500; success = $false; error = "Failed to launch editor: $($_.Exception.Message)" }
    }
}

Export-ModuleMember -Function @(
    'Initialize-SettingsAPI',
    'Get-Theme',
    'Set-Theme',
    'Get-Settings',
    'Set-Settings',
    'Get-AnalysisConfig',
    'Set-AnalysisConfig',
    'Get-GitConfig',
    'Set-GitConfig',
    'Get-VerificationConfig',
    'Set-VerificationConfig',
    'Get-CostConfig',
    'Set-CostConfig',
    'Get-EditorConfig',
    'Set-EditorConfig',
    'Get-EditorRegistry',
    'Get-InstalledEditors',
    'Invoke-OpenEditor',
    'Get-ProviderList',
    'Set-ActiveProvider',
    'Get-MothershipConfig',
    'Set-MothershipConfig',
    'Test-MothershipServerFromUI',
    'Get-NotificationConfig',
    'Set-NotificationConfig',
    'Test-NotificationServerFromUI'
)
