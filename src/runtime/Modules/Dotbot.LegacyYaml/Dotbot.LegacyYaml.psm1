<#
.SYNOPSIS
Legacy v3.5 YAML manifest migration — detect workflow.yaml / manifest.yaml /
registry.yaml, convert to the v4 JSON layout, and warn on ambiguous state.

.DESCRIPTION
dotbot v3.5 read YAML manifests (.bot/workflow.yaml, .bot/workflows/<name>/workflow.yaml,
<registry>/registry.yaml). v4 reads only JSON from .bot/content/workflows/<name>/workflow.json
and <registry>/registry.json. This module owns the one-time fallback: parse legacy YAML with
the powershell-yaml module, write the JSON equivalent into the v4 layout, rename the source
to *.migrated, and warn the operator. A .yaml file alongside its .json equivalent is never
silently resolved — JSON wins and a warning repeats until the operator removes the YAML.
Consumed by Dotbot.Workflow (Find-Workflow / Discover-Workflows), the registry CLI scripts,
and dotbot init.
#>

$script:WorkflowYamlMigrationDone = @{}
$script:RegistryYamlMigrationDone = @{}
$script:YamlSupportLoaded = $false

$script:ManualInstallCommand = 'Install-Module powershell-yaml -Scope CurrentUser'
$script:MigrationDocPointer = "See MIGRATING.md section 'YAML manifests are retired'."

function Write-LegacyYamlWarning {
    param([Parameter(Mandatory)][string]$Message)

    if (Get-Command Write-DotbotWarning -ErrorAction SilentlyContinue) {
        Write-DotbotWarning $Message
    } else {
        [Console]::Error.WriteLine("WARNING: $Message")
    }
}

function Write-LegacyYamlError {
    param([Parameter(Mandatory)][string]$Message)

    if (Get-Command Write-DotbotError -ErrorAction SilentlyContinue) {
        Write-DotbotError $Message
    } else {
        [Console]::Error.WriteLine("ERROR: $Message")
    }
}

function Write-LegacyYamlLog {
    param(
        [Parameter(Mandatory)][ValidateSet('Debug','Info','Warn','Error','Fatal')][string]$Level,
        [Parameter(Mandatory)][string]$Message,
        [hashtable]$Context,
        [System.Management.Automation.ErrorRecord]$Exception
    )

    if (-not (Get-Command Write-BotLog -ErrorAction SilentlyContinue)) { return }
    $params = @{ Level = $Level; Message = $Message }
    if ($Context) { $params.Context = $Context }
    if ($Exception) { $params.Exception = $Exception }
    Write-BotLog @params
}

function Import-DotbotYamlSupport {
    <#
    .SYNOPSIS
    Load the powershell-yaml module, installing it (CurrentUser scope) when absent.

    .DESCRIPTION
    Called lazily, only after legacy YAML files have been detected. Throws with the
    manual install command when neither import nor install succeeds.
    #>
    [CmdletBinding()]
    param()

    if ($script:YamlSupportLoaded) { return }

    if (Get-Module -ListAvailable powershell-yaml) {
        Import-Module powershell-yaml -ErrorAction Stop
        $script:YamlSupportLoaded = $true
        return
    }

    Write-LegacyYamlWarning "Legacy YAML manifests found — installing the powershell-yaml module (CurrentUser scope) to convert them..."
    try {
        Install-Module powershell-yaml -Scope CurrentUser -Force -ErrorAction Stop
        Import-Module powershell-yaml -ErrorAction Stop
    } catch {
        throw "Legacy YAML manifests were found but the powershell-yaml module could not be installed automatically. Install it manually with: $script:ManualInstallCommand — then re-run this command. $script:MigrationDocPointer Underlying error: $($_.Exception.Message)"
    }
    $script:YamlSupportLoaded = $true
}

function Convert-DotbotYamlFileToJson {
    <#
    .SYNOPSIS
    Convert one YAML manifest to JSON and rename the source to <file>.migrated.

    .DESCRIPTION
    Writes the JSON to a temp name first and moves it into place so a concurrent
    process never observes a partial file. Throws on unparseable or empty YAML,
    leaving the source untouched.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$YamlPath,
        [Parameter(Mandatory)][string]$JsonPath
    )

    Import-DotbotYamlSupport

    $parsed = Get-Content -LiteralPath $YamlPath -Raw | ConvertFrom-Yaml -Ordered
    if (-not $parsed) {
        throw "YAML manifest is empty or does not contain a mapping: $YamlPath"
    }

    $json = $parsed | ConvertTo-Json -Depth 20

    $jsonDir = Split-Path -Parent $JsonPath
    if ($jsonDir -and -not (Test-Path -LiteralPath $jsonDir)) {
        New-Item -ItemType Directory -Path $jsonDir -Force | Out-Null
    }

    $tempPath = "$JsonPath.tmp-$PID"
    [System.IO.File]::WriteAllText($tempPath, $json, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tempPath -Destination $JsonPath -Force
    Move-Item -LiteralPath $YamlPath -Destination "$YamlPath.migrated" -Force
}

function Update-DotbotManifestFromYaml {
    <#
    .SYNOPSIS
    Reconcile one directory: convert its YAML manifest to JSON, or warn when both exist.

    .DESCRIPTION
    Returns 'migrated' when a YAML source was converted, 'ambiguous' when the JSON
    manifest already exists alongside a YAML file (JSON wins, nothing is written,
    the warning repeats every run until the YAML is removed), and 'none' when there
    is no YAML to act on. YamlNames order is the source precedence.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string]$JsonName,
        [Parameter(Mandatory)][string[]]$YamlNames
    )

    $presentYaml = @($YamlNames |
        ForEach-Object { Join-Path $Dir $_ } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if ($presentYaml.Count -eq 0) { return 'none' }

    $jsonPath = Join-Path $Dir $JsonName
    if (Test-Path -LiteralPath $jsonPath -PathType Leaf) {
        $yamlLeaf = Split-Path -Leaf $presentYaml[0]
        Write-LegacyYamlWarning "Both $JsonName and $yamlLeaf exist in $Dir. dotbot v4 reads only $JsonName — the YAML file is ignored. Delete it or rename it to $yamlLeaf.migrated to clear this warning."
        Write-LegacyYamlLog -Level Warn -Message 'Legacy YAML manifest coexists with its JSON equivalent' -Context @{ event = 'legacy_yaml_ambiguous'; path = $Dir; winner = $JsonName; ignored = $yamlLeaf }
        return 'ambiguous'
    }

    $source = $presentYaml[0]
    Convert-DotbotYamlFileToJson -YamlPath $source -JsonPath $jsonPath
    Write-LegacyYamlWarning "Migrated legacy YAML manifest to JSON: $source -> $jsonPath (original kept as $(Split-Path -Leaf $source).migrated)"
    Write-LegacyYamlLog -Level Warn -Message 'Migrated legacy YAML manifest to JSON' -Context @{ event = 'legacy_yaml_migrated'; source = $source; target = $jsonPath }
    return 'migrated'
}

function Get-DotbotLegacyYamlFile {
    <#
    .SYNOPSIS
    Enumerate legacy v3.5 YAML manifest paths under a project's .bot root. No writes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BotRoot
    )

    $found = [System.Collections.Generic.List[string]]::new()

    $baseYaml = Join-Path $BotRoot 'workflow.yaml'
    if (Test-Path -LiteralPath $baseYaml -PathType Leaf) { $found.Add($baseYaml) }

    foreach ($parent in @((Join-Path $BotRoot 'workflows'), (Join-Path $BotRoot 'content' 'workflows'))) {
        if (-not (Test-Path -LiteralPath $parent)) { continue }
        foreach ($dir in Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue) {
            foreach ($name in @('workflow.yaml', 'manifest.yaml')) {
                $candidate = Join-Path $dir.FullName $name
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { $found.Add($candidate) }
            }
        }
    }
    return @($found)
}

function Test-DotbotLegacyYamlPresent {
    <#
    .SYNOPSIS
    Detect whether legacy v3.5 YAML manifests exist under a project's .bot root. No writes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BotRoot
    )

    return (@(Get-DotbotLegacyYamlFile -BotRoot $BotRoot).Count -gt 0)
}

function Get-LegacyYamlMigrationKey {
    param([Parameter(Mandatory)][string]$Path)

    try {
        return [System.IO.Path]::GetFullPath($Path)
    } catch {
        return $Path
    }
}

function Invoke-LegacyYamlDirReconciliation {
    param(
        [Parameter(Mandatory)][string]$Dir
    )

    try {
        Update-DotbotManifestFromYaml -Dir $Dir -JsonName 'workflow.json' -YamlNames @('workflow.yaml', 'manifest.yaml') | Out-Null
    } catch {
        Write-LegacyYamlError "Could not migrate legacy YAML manifest in ${Dir}: $($_.Exception.Message) The YAML file was left untouched."
        Write-LegacyYamlLog -Level Error -Message 'Legacy YAML manifest migration failed' -Context @{ event = 'legacy_yaml_parse_failed'; path = $Dir } -Exception $_
    }
}

function Invoke-DotbotWorkflowYamlMigration {
    <#
    .SYNOPSIS
    One-time migration of a project's legacy v3.5 YAML workflow manifests to the v4 JSON layout.

    .DESCRIPTION
    Handles, in order: legacy .bot/workflows/<name>/ directories (moved whole to
    .bot/content/workflows/<name>/ then converted), the legacy base .bot/workflow.yaml
    (converted into .bot/content/workflows/<slug>/workflow.json), YAML strays already
    inside .bot/content/workflows/, and the framework tier (detected and warned about,
    never written — it may be a read-only package-manager install).
    Idempotent: a process-scope flag keyed by BotRoot short-circuits repeat calls
    (reset with -Force), and converted sources are renamed to *.migrated so later
    processes find nothing to do. One failing file never hides the others.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BotRoot,
        [switch]$Force
    )

    $key = Get-LegacyYamlMigrationKey -Path $BotRoot
    if ($script:WorkflowYamlMigrationDone[$key] -and -not $Force) { return }
    $script:WorkflowYamlMigrationDone[$key] = $true

    $frameworkWorkflows = Join-Path (Get-DotbotInstallPath) 'content' 'workflows'
    if (Test-Path -LiteralPath $frameworkWorkflows) {
        foreach ($dir in Get-ChildItem -LiteralPath $frameworkWorkflows -Directory -ErrorAction SilentlyContinue) {
            $yaml = @('workflow.yaml', 'manifest.yaml') |
                ForEach-Object { Join-Path $dir.FullName $_ } |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
                Select-Object -First 1
            if ($yaml) {
                Write-LegacyYamlWarning "Legacy YAML manifest found in the installed framework: $yaml. dotbot never modifies the framework install — convert it to workflow.json manually or remove it. $script:MigrationDocPointer"
                Write-LegacyYamlLog -Level Warn -Message 'Legacy YAML manifest found in framework tier' -Context @{ event = 'legacy_yaml_framework_tier'; path = $yaml }
            }
        }
    }

    if (-not (Test-DotbotLegacyYamlPresent -BotRoot $BotRoot)) { return }

    try {
        Import-DotbotYamlSupport
    } catch {
        Write-LegacyYamlError $_.Exception.Message
        Write-LegacyYamlLog -Level Error -Message 'powershell-yaml unavailable — legacy YAML manifests were not converted' -Context @{ event = 'legacy_yaml_module_unavailable'; bot_root = $BotRoot } -Exception $_
        return
    }

    $contentWorkflows = Join-Path $BotRoot 'content' 'workflows'

    $legacyParent = Join-Path $BotRoot 'workflows'
    if (Test-Path -LiteralPath $legacyParent) {
        foreach ($dir in Get-ChildItem -LiteralPath $legacyParent -Directory -ErrorAction SilentlyContinue) {
            $hasYaml = @('workflow.yaml', 'manifest.yaml') |
                Where-Object { Test-Path -LiteralPath (Join-Path $dir.FullName $_) -PathType Leaf }
            if (-not $hasYaml) { continue }

            $target = Join-Path $contentWorkflows $dir.Name
            if (Test-Path -LiteralPath $target) {
                Write-LegacyYamlWarning "Legacy workflow directory $($dir.FullName) was not moved: $target already exists. dotbot v4 reads only the existing directory — merge or remove the legacy one manually."
                Write-LegacyYamlLog -Level Warn -Message 'Legacy workflow directory conflicts with existing v4 directory' -Context @{ event = 'legacy_yaml_ambiguous'; path = $dir.FullName; conflict = $target }
                continue
            }

            try {
                if (-not (Test-Path -LiteralPath $contentWorkflows)) {
                    New-Item -ItemType Directory -Path $contentWorkflows -Force | Out-Null
                }
                Move-Item -LiteralPath $dir.FullName -Destination $target
            } catch {
                Write-LegacyYamlError "Could not move legacy workflow directory $($dir.FullName) to ${target}: $($_.Exception.Message)"
                Write-LegacyYamlLog -Level Error -Message 'Legacy workflow directory move failed' -Context @{ event = 'legacy_yaml_write_failed'; path = $dir.FullName; target = $target } -Exception $_
                continue
            }
            Invoke-LegacyYamlDirReconciliation -Dir $target
        }

        if (-not (Get-ChildItem -LiteralPath $legacyParent -Force -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $legacyParent -Force -ErrorAction SilentlyContinue
        }
    }

    $baseYaml = Join-Path $BotRoot 'workflow.yaml'
    if (Test-Path -LiteralPath $baseYaml -PathType Leaf) {
        try {
            $parsed = Get-Content -LiteralPath $baseYaml -Raw | ConvertFrom-Yaml -Ordered
            $slug = ''
            if ($parsed -and $parsed['name']) {
                $slug = (([string]$parsed['name'] -replace '[^\w\s-]', '' -replace '\s+', '-').ToLowerInvariant())
            }
            if (-not $slug) { $slug = 'default' }

            $targetDir = Join-Path $contentWorkflows $slug
            $targetJson = Join-Path $targetDir 'workflow.json'
            if (Test-Path -LiteralPath $targetJson -PathType Leaf) {
                Write-LegacyYamlWarning "Both $targetJson and $baseYaml exist. dotbot v4 reads only workflow.json — the YAML file is ignored. Delete it or rename it to workflow.yaml.migrated to clear this warning."
                Write-LegacyYamlLog -Level Warn -Message 'Legacy base manifest coexists with its JSON equivalent' -Context @{ event = 'legacy_yaml_ambiguous'; path = $baseYaml; winner = $targetJson }
            } else {
                Convert-DotbotYamlFileToJson -YamlPath $baseYaml -JsonPath $targetJson
                Write-LegacyYamlWarning "Migrated legacy YAML manifest to JSON: $baseYaml -> $targetJson (original kept as workflow.yaml.migrated)"
                Write-LegacyYamlLog -Level Warn -Message 'Migrated legacy YAML manifest to JSON' -Context @{ event = 'legacy_yaml_migrated'; source = $baseYaml; target = $targetJson }
            }
        } catch {
            Write-LegacyYamlError "Could not migrate legacy base manifest ${baseYaml}: $($_.Exception.Message) The YAML file was left untouched."
            Write-LegacyYamlLog -Level Error -Message 'Legacy base manifest migration failed' -Context @{ event = 'legacy_yaml_parse_failed'; path = $baseYaml } -Exception $_
        }
    }

    if (Test-Path -LiteralPath $contentWorkflows) {
        foreach ($dir in Get-ChildItem -LiteralPath $contentWorkflows -Directory -ErrorAction SilentlyContinue) {
            Invoke-LegacyYamlDirReconciliation -Dir $dir.FullName
        }
    }
}

function Invoke-DotbotSingleRegistryYamlMigration {
    <#
    .SYNOPSIS
    Migrate one registry's legacy YAML manifests (registry.yaml and nested workflow.yaml) to JSON.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RegistryPath
    )

    if (-not (Test-Path -LiteralPath $RegistryPath)) { return }

    $rootYaml = Join-Path $RegistryPath 'registry.yaml'
    $workflowsParent = Join-Path $RegistryPath 'workflows'
    $nestedYaml = @()
    if (Test-Path -LiteralPath $workflowsParent) {
        $nestedYaml = @(Get-ChildItem -LiteralPath $workflowsParent -Directory -ErrorAction SilentlyContinue |
            Where-Object {
                (Test-Path -LiteralPath (Join-Path $_.FullName 'workflow.yaml') -PathType Leaf) -or
                (Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.yaml') -PathType Leaf)
            })
    }
    $hasRootYaml = Test-Path -LiteralPath $rootYaml -PathType Leaf
    if (-not $hasRootYaml -and $nestedYaml.Count -eq 0) { return }

    try {
        Import-DotbotYamlSupport
    } catch {
        Write-LegacyYamlError $_.Exception.Message
        Write-LegacyYamlLog -Level Error -Message 'powershell-yaml unavailable — legacy registry YAML was not converted' -Context @{ event = 'legacy_yaml_module_unavailable'; registry = $RegistryPath } -Exception $_
        return
    }

    if ($hasRootYaml) {
        try {
            Update-DotbotManifestFromYaml -Dir $RegistryPath -JsonName 'registry.json' -YamlNames @('registry.yaml') | Out-Null
        } catch {
            Write-LegacyYamlError "Could not migrate legacy registry manifest in ${RegistryPath}: $($_.Exception.Message) The YAML file was left untouched."
            Write-LegacyYamlLog -Level Error -Message 'Legacy registry manifest migration failed' -Context @{ event = 'legacy_yaml_parse_failed'; path = $rootYaml } -Exception $_
        }
    }

    foreach ($dir in $nestedYaml) {
        Invoke-LegacyYamlDirReconciliation -Dir $dir.FullName
    }
}

function Invoke-DotbotRegistryYamlMigration {
    <#
    .SYNOPSIS
    One-time migration of every registered registry's legacy YAML manifests under <DotbotBase>/registries.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DotbotBase,
        [switch]$Force
    )

    $key = Get-LegacyYamlMigrationKey -Path $DotbotBase
    if ($script:RegistryYamlMigrationDone[$key] -and -not $Force) { return }
    $script:RegistryYamlMigrationDone[$key] = $true

    $registriesRoot = Join-Path $DotbotBase 'registries'
    if (-not (Test-Path -LiteralPath $registriesRoot)) { return }

    foreach ($dir in Get-ChildItem -LiteralPath $registriesRoot -Directory -ErrorAction SilentlyContinue) {
        Invoke-DotbotSingleRegistryYamlMigration -RegistryPath $dir.FullName
    }
}
