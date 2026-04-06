<#
.SYNOPSIS
Settings, theme, and configuration API module

.DESCRIPTION
Provides theme management, UI settings, analysis config, and verification config CRUD.
Extracted from server.ps1 for modularity.
#>

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
    $defaultSettings = @{
        showDebug = $false
        showVerbose = $false
        analysisModel = "Opus"
        executionModel = "Opus"
        permissionMode = $null
    }

    if (Test-Path $settingsFile) {
        try {
            return Get-Content $settingsFile -Raw | ConvertFrom-Json
        } catch {
            return $defaultSettings
        }
    } else {
        return $defaultSettings
    }
}

function Set-Settings {
    param(
        [Parameter(Mandatory)] $Body
    )
    $settingsFile = Join-Path $script:Config.ControlDir "ui-settings.json"
    $defaultSettings = @{
        showDebug = $false
        showVerbose = $false
        analysisModel = "Opus"
        executionModel = "Opus"
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
        $settings.analysisModel = [string]$Body.analysisModel
    }
    if ($null -ne $Body.executionModel) {
        $settings.executionModel = [string]$Body.executionModel
    }
    if ($Body.PSObject.Properties.Name -contains 'permissionMode') {
        if ($null -eq $Body.permissionMode) {
            $settings.permissionMode = $null
        } else {
            $modeValue = [string]$Body.permissionMode
            # Validate against active provider's permission modes
            $providerConfig = Get-ProviderConfig
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
    $settingsDefaultFile = Join-Path $script:Config.BotRoot "settings\settings.default.json"

    try {
        $settingsData = Get-Content $settingsDefaultFile -Raw | ConvertFrom-Json
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
    $settingsDefaultFile = Join-Path $script:Config.BotRoot "settings\settings.default.json"

    $settingsData = Get-Content $settingsDefaultFile -Raw | ConvertFrom-Json
    if (-not $settingsData.analysis) {
        $settingsData | Add-Member -NotePropertyName "analysis" -NotePropertyValue @{
            auto_approve_splits = $false
            split_threshold_effort = "XL"
            question_timeout_hours = $null
            mode = "on-demand"
        }
    }

    if ($null -ne $Body.auto_approve_splits) {
        $settingsData.analysis.auto_approve_splits = [bool]$Body.auto_approve_splits
    }
    if ($null -ne $Body.split_threshold_effort) {
        $settingsData.analysis.split_threshold_effort = [string]$Body.split_threshold_effort
    }
    if ($Body.PSObject.Properties.Name -contains 'question_timeout_hours') {
        if ($null -eq $Body.question_timeout_hours) {
            $settingsData.analysis.question_timeout_hours = $null
        } else {
            $settingsData.analysis.question_timeout_hours = [int]$Body.question_timeout_hours
        }
    }
    if ($null -ne $Body.mode) {
        $settingsData.analysis.mode = [string]$Body.mode
    }

    $settingsData | ConvertTo-Json -Depth 5 | Set-Content $settingsDefaultFile -Force
    Write-Status "Analysis config updated" -Type Success

    return @{
        success = $true
        analysis = $settingsData.analysis
    }
}

function Get-VerificationConfig {
    $verifyConfigFile = Join-Path $script:Config.BotRoot "hooks\verify\config.json"

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
    $verifyConfigFile = Join-Path $script:Config.BotRoot "hooks\verify\config.json"

    $verifyData = Get-Content $verifyConfigFile -Raw | ConvertFrom-Json
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
    $verifyData | ConvertTo-Json -Depth 5 | Set-Content $verifyConfigFile -Force
    Write-Status "Verification config updated: $scriptName required=$($scriptEntry.required)" -Type Success

    return @{
        success = $true
        scripts = $verifyData.scripts
    }
}

function Get-CostConfig {
    $settingsDefaultFile = Join-Path $script:Config.BotRoot "settings\settings.default.json"

    try {
        $settingsData = Get-Content $settingsDefaultFile -Raw | ConvertFrom-Json
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
    $settingsDefaultFile = Join-Path $script:Config.BotRoot "settings\settings.default.json"

    $settingsData = Get-Content $settingsDefaultFile -Raw | ConvertFrom-Json
    if (-not $settingsData.costs) {
        $settingsData | Add-Member -NotePropertyName "costs" -NotePropertyValue @{
            hourly_rate = 50
            ai_speedup_factor = 10
            currency = "USD"
        }
    }

    if ($null -ne $Body.hourly_rate) {
        $settingsData.costs.hourly_rate = [decimal]$Body.hourly_rate
    }
    if ($null -ne $Body.ai_cost_per_task) {
        $settingsData.costs.ai_cost_per_task = [decimal]$Body.ai_cost_per_task
    }
    if ($null -ne $Body.ai_speedup_factor) {
        $settingsData.costs.ai_speedup_factor = [decimal]$Body.ai_speedup_factor
    }
    if ($null -ne $Body.currency) {
        $settingsData.costs.currency = [string]$Body.currency
    }

    $settingsData | ConvertTo-Json -Depth 5 | Set-Content $settingsDefaultFile -Force
    Write-Status "Cost config updated" -Type Success

    return @{
        success = $true
        costs = $settingsData.costs
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
    $settingsDefaultFile = Join-Path $script:Config.BotRoot "settings\settings.default.json"

    try {
        $settingsData = Get-Content $settingsDefaultFile -Raw | ConvertFrom-Json
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
    $settingsDefaultFile = Join-Path $script:Config.BotRoot "settings\settings.default.json"

    if (-not (Test-Path $settingsDefaultFile)) {
        # Create a minimal settings file if it doesn't exist
        @{ editor = @{ name = 'off'; custom_command = '' } } | ConvertTo-Json -Depth 5 | Set-Content $settingsDefaultFile -Force
    }

    $settingsData = Get-Content $settingsDefaultFile -Raw | ConvertFrom-Json
    if (-not $settingsData.editor) {
        $settingsData | Add-Member -NotePropertyName "editor" -NotePropertyValue ([PSCustomObject]@{
            name = 'off'
            custom_command = ''
        })
    }

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
        $settingsData.editor.name = $requestedName
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
        $settingsData.editor.custom_command = $customCommand
    }

    $settingsData | ConvertTo-Json -Depth 5 | Set-Content $settingsDefaultFile -Force
    Write-Status "Editor config updated: $($settingsData.editor.name)" -Type Success

    return @{
        success = $true
        editor = $settingsData.editor
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
        $script:ProviderProbeCache[$providerName] = $result
        return $result
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
        'gemini' {
            if ($env:GEMINI_API_KEY -or $env:GOOGLE_API_KEY) {
                $result.accessible = $true
            } else {
                # Check for Google OAuth login
                $googleAccountsFile = Join-Path $HOME ".gemini" "google_accounts.json"
                if (Test-Path $googleAccountsFile) {
                    try {
                        $accounts = Get-Content $googleAccountsFile -Raw | ConvertFrom-Json
                        $result.accessible = [bool]$accounts.active
                    } catch { Write-BotLog -Level Debug -Message "Gemini OAuth check failed" -Exception $_ }
                }
            }
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
    $providersDir = Join-Path $script:Config.BotRoot "settings\providers"
    $settingsDefaultFile = Join-Path $script:Config.BotRoot "settings\settings.default.json"

    try {
        # Read active provider from settings
        $activeProvider = 'claude'
        $settingsPermMode = $null
        if (Test-Path $settingsDefaultFile) {
            try {
                $settingsData = Get-Content $settingsDefaultFile -Raw | ConvertFrom-Json
                if ($settingsData.provider) { $activeProvider = $settingsData.provider }
                if ($settingsData.permission_mode) { $settingsPermMode = $settingsData.permission_mode }
            } catch { Write-BotLog -Level Debug -Message "Failed to parse data" -Exception $_ }
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

        if (Test-Path $providersDir) {
            Get-ChildItem $providersDir -Filter "*.json" | ForEach-Object {
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
                        foreach ($key in $config.models.PSObject.Properties.Name) {
                            $m = $config.models.$key
                            $activeModels += @{
                                id = $key
                                name = $key
                                badge = if ($m.badge) { $m.badge } else { $null }
                                description = $m.description
                            }
                        }

                        # Permission modes
                        if ($config.permission_modes) {
                            $activePermModes = @{}
                            foreach ($key in $config.permission_modes.PSObject.Properties.Name) {
                                $pm = $config.permission_modes.$key
                                $activePermModes[$key] = @{
                                    display_name = $pm.display_name
                                    description  = $pm.description
                                    restrictions = if ($pm.restrictions) { $pm.restrictions } else { $null }
                                }
                            }
                            $activeDefaultPermMode = $config.default_permission_mode
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
    $settingsDefaultFile = Join-Path $script:Config.BotRoot "settings\settings.default.json"
    $providersDir = Join-Path $script:Config.BotRoot "settings\providers"

    $providerName = $Body.provider
    if (-not $providerName) {
        return @{ _statusCode = 400; success = $false; error = "Missing 'provider' field" }
    }
    if ($providerName -notmatch '^[a-z0-9_-]+$') {
        return @{ _statusCode = 400; success = $false; error = "Invalid provider name: must be lowercase alphanumeric, hyphens, or underscores" }
    }

    # Validate provider exists
    $providerFile = Join-Path $providersDir "$providerName.json"
    if (-not (Test-Path $providerFile)) {
        return @{ _statusCode = 400; success = $false; error = "Unknown provider: $providerName" }
    }

    # Update settings
    if (-not (Test-Path $settingsDefaultFile)) {
        @{ provider = $providerName } | ConvertTo-Json -Depth 5 | Set-Content $settingsDefaultFile -Force
    }

    try {
        $settingsData = Get-Content $settingsDefaultFile -Raw | ConvertFrom-Json
    } catch {
        return @{ _statusCode = 500; success = $false; error = "Failed to parse settings file: $($_.Exception.Message)" }
    }

    if ($settingsData.PSObject.Properties.Name -contains 'provider') {
        $settingsData.provider = $providerName
    } else {
        $settingsData | Add-Member -NotePropertyName "provider" -NotePropertyValue $providerName
    }

    try {
        $settingsData | ConvertTo-Json -Depth 5 | Set-Content $settingsDefaultFile -Force
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
    $settingsDefaultFile = Join-Path $script:Config.BotRoot "settings\settings.default.json"
    $overridesFile = Join-Path $script:Config.ControlDir "settings.json"
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
        # Layer 1: checked-in defaults
        if (Test-Path $settingsDefaultFile) {
            $settingsData = Get-Content $settingsDefaultFile -Raw | ConvertFrom-Json
            # Read from 'mothership' key (with 'notifications' fallback for migration)
            $sectionKey = if ($settingsData.PSObject.Properties['mothership']) { 'mothership' }
                          elseif ($settingsData.PSObject.Properties['notifications']) { 'notifications' }
                          else { $null }
            if ($sectionKey) {
                $section = $settingsData.$sectionKey
                foreach ($prop in $section.PSObject.Properties) {
                    if ($defaults.ContainsKey($prop.Name)) {
                        $defaults[$prop.Name] = $prop.Value
                    }
                }
                if ($section.PSObject.Properties['sound_enabled']) {
                    $soundEnabled = [bool]$section.sound_enabled
                }
            }
        }

        # Layer 2: user overrides (api_key typically lives here)
        if (Test-Path $overridesFile) {
            $overrides = Get-Content $overridesFile -Raw | ConvertFrom-Json
            $sectionKey = if ($overrides.PSObject.Properties['mothership']) { 'mothership' }
                          elseif ($overrides.PSObject.Properties['notifications']) { 'notifications' }
                          else { $null }
            if ($sectionKey) {
                $section = $overrides.$sectionKey
                foreach ($prop in $section.PSObject.Properties) {
                    if ($defaults.ContainsKey($prop.Name)) {
                        $defaults[$prop.Name] = $prop.Value
                    }
                }
                if ($section.PSObject.Properties['sound_enabled']) {
                    $soundEnabled = [bool]$section.sound_enabled
                }
            }
        }

        # Layer 3: local UI preferences
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
    $settingsDefaultFile = Join-Path $script:Config.BotRoot "settings\settings.default.json"
    $overridesFile = Join-Path $script:Config.ControlDir "settings.json"
    $uiSettingsFile = Join-Path $script:Config.ControlDir "ui-settings.json"

    # Non-secret settings go in settings.default.json
    $settingsData = if (Test-Path $settingsDefaultFile) {
        Get-Content $settingsDefaultFile -Raw | ConvertFrom-Json
    } else {
        [PSCustomObject]@{}
    }

    # Migrate legacy 'notifications' key to 'mothership'
    if ($settingsData.PSObject.Properties['notifications'] -and -not $settingsData.PSObject.Properties['mothership']) {
        $settingsData | Add-Member -NotePropertyName "mothership" -NotePropertyValue $settingsData.notifications
        $settingsData.PSObject.Properties.Remove('notifications')
        $settingsChanged = $true
    }

    if (-not $settingsData.PSObject.Properties['mothership']) {
        $settingsData | Add-Member -NotePropertyName "mothership" -NotePropertyValue ([PSCustomObject]@{
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
        })
    }

    $notif = $settingsData.mothership
    $settingsChanged = $false
    $legacySoundEnabled = $null

    if ($notif.PSObject.Properties['sound_enabled']) {
        $legacySoundEnabled = [bool]$notif.sound_enabled
        [void]$notif.PSObject.Properties.Remove('sound_enabled')
        $settingsChanged = $true
    }

    if ($null -ne $Body.enabled) {
        $notif.enabled = [bool]$Body.enabled
        $settingsChanged = $true
    }
    if ($null -ne $Body.server_url) {
        $notif.server_url = [string]$Body.server_url
        $settingsChanged = $true
    }
    if ($null -ne $Body.channel) {
        $validChannels = @("teams", "email", "jira", "slack")
        if ($Body.channel -in $validChannels) {
            $notif.channel = [string]$Body.channel
            $settingsChanged = $true
        }
    }
    if ($null -ne $Body.recipients) {
        $notif.recipients = @($Body.recipients)
        $settingsChanged = $true
    }
    if ($null -ne $Body.project_name) {
        $notif.project_name = [string]$Body.project_name
        $settingsChanged = $true
    }
    if ($null -ne $Body.project_description) {
        $notif.project_description = [string]$Body.project_description
        $settingsChanged = $true
    }
    if ($null -ne $Body.poll_interval_seconds) {
        $interval = [int]$Body.poll_interval_seconds
        if ($interval -lt 5) { $interval = 5 }
        $notif.poll_interval_seconds = $interval
        $settingsChanged = $true
    }
    if ($null -ne $Body.sync_tasks) {
        $notif | Add-Member -NotePropertyName 'sync_tasks' -NotePropertyValue ([bool]$Body.sync_tasks) -Force
        $settingsChanged = $true
    }
    if ($null -ne $Body.sync_questions) {
        $notif | Add-Member -NotePropertyName 'sync_questions' -NotePropertyValue ([bool]$Body.sync_questions) -Force
        $settingsChanged = $true
    }

    if ($settingsChanged) {
        $settingsData | ConvertTo-Json -Depth 5 | Set-Content $settingsDefaultFile -Force
    }

    # API key goes in the gitignored overrides file
    $overrides = @{}
    $overridesChanged = $false
    if (Test-Path $overridesFile) {
        try {
            $existing = Get-Content $overridesFile -Raw | ConvertFrom-Json
            foreach ($prop in $existing.PSObject.Properties) {
                $overrides[$prop.Name] = $prop.Value
            }
        } catch { Write-BotLog -Level Debug -Message "Failed to parse data" -Exception $_ }
    }

    # Migrate legacy 'notifications' key to 'mothership' in overrides
    if ($overrides.ContainsKey('notifications') -and -not $overrides.ContainsKey('mothership')) {
        $overrides['mothership'] = $overrides['notifications']
        $overrides.Remove('notifications')
        $overridesChanged = $true
    }

    if ($overrides.ContainsKey('mothership') -and $overrides['mothership'] -is [PSCustomObject]) {
        $hash = @{}
        foreach ($p in $overrides['mothership'].PSObject.Properties) { $hash[$p.Name] = $p.Value }
        $overrides['mothership'] = $hash
    }

    if ($overrides.ContainsKey('mothership') -and $overrides['mothership'].ContainsKey('sound_enabled')) {
        if ($null -eq $legacySoundEnabled) {
            $legacySoundEnabled = [bool]$overrides['mothership']['sound_enabled']
        }
        $overrides['mothership'].Remove('sound_enabled')
        $overridesChanged = $true
    }

    $uiSettings = @{
        showDebug = $false
        showVerbose = $false
        analysisModel = "Opus"
        executionModel = "Opus"
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

    if ($null -ne $Body.api_key -and $Body.api_key -ne '') {
        if (-not $overrides.ContainsKey('mothership')) {
            $overrides['mothership'] = @{}
        }
        $overrides['mothership']['api_key'] = [string]$Body.api_key
        $overridesChanged = $true
    }

    if ($overridesChanged) {
        $overrides | ConvertTo-Json -Depth 5 | Set-Content $overridesFile -Force
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
    $notifModule = Join-Path $script:Config.BotRoot "systems\mcp\modules\NotificationClient.psm1"
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

    $settingsDefaultFile = Join-Path $script:Config.BotRoot "settings\settings.default.json"

    try {
        $settingsData = Get-Content $settingsDefaultFile -Raw | ConvertFrom-Json
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
