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
            } catch { }
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
        } catch { }
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
    }

    # Load existing settings into defaults hashtable
    $settings = $defaultSettings.Clone()
    if (Test-Path $settingsFile) {
        try {
            $existingSettings = Get-Content $settingsFile -Raw | ConvertFrom-Json
            foreach ($prop in $existingSettings.PSObject.Properties) {
                $settings[$prop.Name] = $prop.Value
            }
        } catch { }
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

    # Save settings
    $settings | ConvertTo-Json | Set-Content $settingsFile -Force
    Write-Status "Settings updated: Debug=$($settings.showDebug), Verbose=$($settings.showVerbose)" -Type Success

    return @{
        success = $true
        settings = $settings
    }
}

function Get-AnalysisConfig {
    $settingsDefaultFile = Join-Path $script:Config.BotRoot "defaults\settings.default.json"

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
    $settingsDefaultFile = Join-Path $script:Config.BotRoot "defaults\settings.default.json"

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
    $settingsDefaultFile = Join-Path $script:Config.BotRoot "defaults\settings.default.json"

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
    $settingsDefaultFile = Join-Path $script:Config.BotRoot "defaults\settings.default.json"

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
            } catch { }
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
    $settingsDefaultFile = Join-Path $script:Config.BotRoot "defaults\settings.default.json"

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
    $settingsDefaultFile = Join-Path $script:Config.BotRoot "defaults\settings.default.json"

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

function Invoke-OpenEditor {
    param(
        [Parameter(Mandatory)] [string]$ProjectRoot
    )

    $settingsDefaultFile = Join-Path $script:Config.BotRoot "defaults\settings.default.json"

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
        } catch { }
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
    'Invoke-OpenEditor'
)
