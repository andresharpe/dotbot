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
$script:MigrationFailureInjector = $null

$script:PowerShellGetInstallCommand = 'Register-PSRepository -Default; Install-Module powershell-yaml -Repository PSGallery -Scope CurrentUser'
$script:PSResourceGetInstallCommand = 'Install-PSResource powershell-yaml -Repository PSGallery -Scope CurrentUser -TrustRepository'
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
    Load the powershell-yaml module when available.

    .DESCRIPTION
    Called lazily, only after legacy YAML files have been detected. Migration is
    also reached from read-only discovery commands, so this function never changes
    package repositories or installs code. It throws with explicit guidance for
    both supported PowerShell package managers when the parser is unavailable.
    #>
    [CmdletBinding()]
    param()

    if ($script:YamlSupportLoaded) { return }

    if (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue) {
        $script:YamlSupportLoaded = $true
        return
    }

    if (Get-Module -ListAvailable powershell-yaml) {
        Import-Module powershell-yaml -ErrorAction Stop
        $script:YamlSupportLoaded = $true
        return
    }

    throw "Legacy YAML manifests were found but powershell-yaml is not installed. dotbot does not install packages during workflow or registry discovery. Install it explicitly with PowerShellGet: $script:PowerShellGetInstallCommand — or PSResourceGet: $script:PSResourceGetInstallCommand — then re-run this command. $script:MigrationDocPointer"
}

function Invoke-DotbotMigrationFailureInjector {
    param(
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][string]$Source,
        [string]$Destination
    )
    if ($script:MigrationFailureInjector) {
        & $script:MigrationFailureInjector $Operation $Source $Destination
    }
}

function Move-DotbotMigrationItem {
    param(
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    Invoke-DotbotMigrationFailureInjector -Operation $Operation -Source $Source -Destination $Destination
    Move-Item -LiteralPath $Source -Destination $Destination -ErrorAction Stop
}

function Test-DotbotYamlManifestStructure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][ValidateSet('Workflow','Registry')][string]$Kind,
        [Parameter(Mandatory)][string]$SourcePath,
        [switch]$AllowMissingName,
        [string]$ExpectedName
    )

    if ($Manifest -isnot [System.Collections.IDictionary]) {
        throw "$Kind YAML manifest must have a mapping at its root: $SourcePath"
    }

    $name = if ($Manifest.Contains('name')) { [string]$Manifest['name'] } else { '' }
    if (-not $AllowMissingName -and [string]::IsNullOrWhiteSpace($name)) {
        throw "$Kind YAML manifest must declare a non-empty 'name': $SourcePath"
    }
    if ($ExpectedName -and $name -ne $ExpectedName) {
        throw "$Kind YAML manifest name '$name' does not match expected name '$ExpectedName': $SourcePath"
    }

    if ($Kind -eq 'Workflow' -and $Manifest.Contains('tasks')) {
        $tasks = $Manifest['tasks']
        if ($null -ne $tasks -and ($tasks -is [string] -or $tasks -isnot [System.Collections.IEnumerable])) {
            throw "Workflow YAML manifest 'tasks' must be a sequence: $SourcePath"
        }
        foreach ($task in @($tasks)) {
            if ($task -isnot [System.Collections.IDictionary]) {
                throw "Every workflow YAML task must be a mapping: $SourcePath"
            }
        }
    }

    if ($Kind -eq 'Registry') {
        $content = if ($Manifest.Contains('content')) { $Manifest['content'] } else { $null }
        if ($content -isnot [System.Collections.IDictionary] -or $content.Count -eq 0) {
            throw "Registry YAML manifest must declare a non-empty 'content' mapping: $SourcePath"
        }
        $declaredItems = 0
        foreach ($key in $content.Keys) {
            $items = $content[$key]
            if ($items -is [string] -or $items -isnot [System.Collections.IEnumerable]) {
                throw "Registry YAML content '$key' must be a sequence: $SourcePath"
            }
            $declaredItems += @($items).Count
        }
        if ($declaredItems -eq 0) {
            throw "Registry YAML manifest must declare at least one content item: $SourcePath"
        }
    }

    return $true
}

function Read-DotbotValidatedYamlManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$YamlPath,
        [Parameter(Mandatory)][ValidateSet('Workflow','Registry')][string]$Kind,
        [switch]$AllowMissingName,
        [string]$ExpectedName
    )

    Import-DotbotYamlSupport
    $parsed = Get-Content -LiteralPath $YamlPath -Raw | ConvertFrom-Yaml -Ordered
    $null = Test-DotbotYamlManifestStructure -Manifest $parsed -Kind $Kind -SourcePath $YamlPath -AllowMissingName:$AllowMissingName -ExpectedName $ExpectedName
    return $parsed
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
        [Parameter(Mandatory)][string]$JsonPath,
        [ValidateSet('Workflow','Registry')][string]$ManifestKind = 'Workflow',
        [switch]$AllowMissingName,
        [string]$ExpectedName
    )

    $parsed = Read-DotbotValidatedYamlManifest -YamlPath $YamlPath -Kind $ManifestKind -AllowMissingName:$AllowMissingName -ExpectedName $ExpectedName

    $json = $parsed | ConvertTo-Json -Depth 20

    $migratedPath = "$YamlPath.migrated"
    if (Test-Path -LiteralPath $JsonPath) {
        throw "Refusing to overwrite existing JSON manifest: $JsonPath"
    }
    if (Test-Path -LiteralPath $migratedPath) {
        throw "Refusing to overwrite existing migration backup: $migratedPath"
    }

    $jsonDir = Split-Path -Parent $JsonPath
    $jsonDirCreated = $false
    if ($jsonDir -and -not (Test-Path -LiteralPath $jsonDir)) {
        New-Item -ItemType Directory -Path $jsonDir -Force | Out-Null
        $jsonDirCreated = $true
    }

    $tempPath = "$JsonPath.tmp-$PID-$([guid]::NewGuid().ToString('N'))"
    $jsonPublished = $false
    try {
        [System.IO.File]::WriteAllText($tempPath, $json, [System.Text.UTF8Encoding]::new($false))
        $roundTrip = Get-Content -LiteralPath $tempPath -Raw | ConvertFrom-Json -AsHashtable
        $null = Test-DotbotYamlManifestStructure -Manifest $roundTrip -Kind $ManifestKind -SourcePath $tempPath -AllowMissingName:$AllowMissingName -ExpectedName $ExpectedName

        Move-DotbotMigrationItem -Operation 'publish-json' -Source $tempPath -Destination $JsonPath
        $jsonPublished = $true
        try {
            Move-DotbotMigrationItem -Operation 'archive-yaml' -Source $YamlPath -Destination $migratedPath
        } catch {
            Remove-Item -LiteralPath $JsonPath -Force -ErrorAction Stop
            $jsonPublished = $false
            throw
        }
    } finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        if ($jsonPublished -and (Test-Path -LiteralPath $YamlPath) -and -not (Test-Path -LiteralPath $migratedPath)) {
            Remove-Item -LiteralPath $JsonPath -Force -ErrorAction SilentlyContinue
        }
        if ($jsonDirCreated -and (Test-Path -LiteralPath $jsonDir) -and
            -not (Get-ChildItem -LiteralPath $jsonDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
            Remove-Item -LiteralPath $jsonDir -Force -ErrorAction SilentlyContinue
        }
    }
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
        [Parameter(Mandatory)][string[]]$YamlNames,
        [ValidateSet('Workflow','Registry')][string]$ManifestKind = 'Workflow',
        [string]$ExpectedName
    )

    $presentYaml = @($YamlNames |
        ForEach-Object { Join-Path $Dir $_ } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if ($presentYaml.Count -eq 0) { return 'none' }
    if ($presentYaml.Count -gt 1) {
        throw "Multiple legacy YAML manifests exist in ${Dir}: $($presentYaml -join ', '). Resolve the ambiguity before migration."
    }

    $jsonPath = Join-Path $Dir $JsonName
    if (Test-Path -LiteralPath $jsonPath -PathType Leaf) {
        $yamlLeaf = Split-Path -Leaf $presentYaml[0]
        Write-LegacyYamlWarning "Both $JsonName and $yamlLeaf exist in $Dir. dotbot v4 reads only $JsonName — the YAML file is ignored. Delete it or rename it to $yamlLeaf.migrated to clear this warning."
        Write-LegacyYamlLog -Level Warn -Message 'Legacy YAML manifest coexists with its JSON equivalent' -Context @{ event = 'legacy_yaml_ambiguous'; path = $Dir; winner = $JsonName; ignored = $yamlLeaf }
        return 'ambiguous'
    }

    $source = $presentYaml[0]
    Convert-DotbotYamlFileToJson -YamlPath $source -JsonPath $jsonPath -ManifestKind $ManifestKind -ExpectedName $ExpectedName
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
        return $true
    } catch {
        Write-LegacyYamlError "Could not migrate legacy YAML manifest in ${Dir}: $($_.Exception.Message) The YAML file was left untouched."
        Write-LegacyYamlLog -Level Error -Message 'Legacy YAML manifest migration failed' -Context @{ event = 'legacy_yaml_parse_failed'; path = $Dir } -Exception $_
        return $false
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
    $allSucceeded = $true

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

    if (-not (Test-DotbotLegacyYamlPresent -BotRoot $BotRoot)) {
        $script:WorkflowYamlMigrationDone[$key] = $true
        return
    }

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
            if ($dir.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                Write-LegacyYamlWarning "Legacy workflow link $($dir.FullName) was not migrated because it resolves outside the project layout. Replace it with a real directory or convert the linked source explicitly."
                $allSucceeded = $false
                continue
            }

            $target = Join-Path $contentWorkflows $dir.Name
            if (Test-Path -LiteralPath $target) {
                Write-LegacyYamlWarning "Legacy workflow directory $($dir.FullName) was not moved: $target already exists. dotbot v4 reads only the existing directory — merge or remove the legacy one manually."
                Write-LegacyYamlLog -Level Warn -Message 'Legacy workflow directory conflicts with existing v4 directory' -Context @{ event = 'legacy_yaml_ambiguous'; path = $dir.FullName; conflict = $target }
                $allSucceeded = $false
                continue
            }

            $sourceYaml = @('workflow.yaml', 'manifest.yaml') |
                ForEach-Object { Join-Path $dir.FullName $_ } |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
                Select-Object -First 1
            try {
                # Validate before changing the legacy layout. Conversion is
                # repeated after the directory move so all final paths and
                # backups are committed together.
                $null = Read-DotbotValidatedYamlManifest -YamlPath $sourceYaml -Kind Workflow
                if (-not (Test-Path -LiteralPath $contentWorkflows)) {
                    New-Item -ItemType Directory -Path $contentWorkflows -Force | Out-Null
                }
                Move-DotbotMigrationItem -Operation 'move-workflow-directory' -Source $dir.FullName -Destination $target
            } catch {
                Write-LegacyYamlError "Could not move legacy workflow directory $($dir.FullName) to ${target}: $($_.Exception.Message)"
                Write-LegacyYamlLog -Level Error -Message 'Legacy workflow directory move failed' -Context @{ event = 'legacy_yaml_write_failed'; path = $dir.FullName; target = $target } -Exception $_
                $allSucceeded = $false
                continue
            }
            if (-not (Invoke-LegacyYamlDirReconciliation -Dir $target)) {
                try {
                    Move-DotbotMigrationItem -Operation 'rollback-workflow-directory' -Source $target -Destination $dir.FullName
                } catch {
                    Write-LegacyYamlError "Rollback failed after migrating $($dir.FullName): $($_.Exception.Message). Recover the workflow directory from $target."
                    Write-LegacyYamlLog -Level Fatal -Message 'Legacy workflow directory rollback failed' -Context @{ event = 'legacy_yaml_rollback_failed'; path = $dir.FullName; target = $target } -Exception $_
                }
                $allSucceeded = $false
            }
        }

        if (-not (Get-ChildItem -LiteralPath $legacyParent -Force -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $legacyParent -Force -ErrorAction SilentlyContinue
        }
    }

    $baseYaml = Join-Path $BotRoot 'workflow.yaml'
    if (Test-Path -LiteralPath $baseYaml -PathType Leaf) {
        try {
            $parsed = Read-DotbotValidatedYamlManifest -YamlPath $baseYaml -Kind Workflow -AllowMissingName
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
                Convert-DotbotYamlFileToJson -YamlPath $baseYaml -JsonPath $targetJson -ManifestKind Workflow -AllowMissingName
                Write-LegacyYamlWarning "Migrated legacy YAML manifest to JSON: $baseYaml -> $targetJson (original kept as workflow.yaml.migrated)"
                Write-LegacyYamlLog -Level Warn -Message 'Migrated legacy YAML manifest to JSON' -Context @{ event = 'legacy_yaml_migrated'; source = $baseYaml; target = $targetJson }
            }
        } catch {
            Write-LegacyYamlError "Could not migrate legacy base manifest ${baseYaml}: $($_.Exception.Message) The YAML file was left untouched."
            Write-LegacyYamlLog -Level Error -Message 'Legacy base manifest migration failed' -Context @{ event = 'legacy_yaml_parse_failed'; path = $baseYaml } -Exception $_
            $allSucceeded = $false
        }
    }

    if (Test-Path -LiteralPath $contentWorkflows) {
        foreach ($dir in Get-ChildItem -LiteralPath $contentWorkflows -Directory -ErrorAction SilentlyContinue) {
            if ($dir.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                $linkedYaml = @('workflow.yaml', 'manifest.yaml') |
                    Where-Object { Test-Path -LiteralPath (Join-Path $dir.FullName $_) -PathType Leaf }
                if ($linkedYaml) {
                    Write-LegacyYamlWarning "Legacy workflow YAML under linked directory $($dir.FullName) was not migrated. Convert the linked source explicitly."
                    $allSucceeded = $false
                }
                continue
            }
            if (-not (Invoke-LegacyYamlDirReconciliation -Dir $dir.FullName)) {
                $allSucceeded = $false
            }
        }
    }

    if ($allSucceeded) {
        $script:WorkflowYamlMigrationDone[$key] = $true
    }
}

function Invoke-DotbotSingleRegistryYamlMigration {
    <#
    .SYNOPSIS
    Migrate one registry's legacy YAML manifests (registry.yaml and nested workflow.yaml) to JSON.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RegistryPath,
        [switch]$AllowExternalLink,
        [string]$ExpectedName
    )

    if (-not (Test-Path -LiteralPath $RegistryPath)) { return $true }

    $registryItem = Get-Item -LiteralPath $RegistryPath -Force -ErrorAction SilentlyContinue
    if ($registryItem -and ($registryItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -and -not $AllowExternalLink) {
        Write-LegacyYamlWarning "Legacy YAML migration skipped for linked registry $RegistryPath. Run 'dotbot registry update' to explicitly migrate the linked source, or convert it manually."
        Write-LegacyYamlLog -Level Warn -Message 'Legacy registry link requires explicit migration' -Context @{ event = 'legacy_yaml_external_link'; registry = $RegistryPath }
        return $false
    }

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
    if (-not $hasRootYaml -and $nestedYaml.Count -eq 0) { return $true }

    try {
        Import-DotbotYamlSupport
    } catch {
        Write-LegacyYamlError $_.Exception.Message
        Write-LegacyYamlLog -Level Error -Message 'powershell-yaml unavailable — legacy registry YAML was not converted' -Context @{ event = 'legacy_yaml_module_unavailable'; registry = $RegistryPath } -Exception $_
        return $false
    }

    $allSucceeded = $true
    if ($hasRootYaml) {
        try {
            Update-DotbotManifestFromYaml -Dir $RegistryPath -JsonName 'registry.json' -YamlNames @('registry.yaml') -ManifestKind Registry -ExpectedName $ExpectedName | Out-Null
        } catch {
            Write-LegacyYamlError "Could not migrate legacy registry manifest in ${RegistryPath}: $($_.Exception.Message) The YAML file was left untouched."
            Write-LegacyYamlLog -Level Error -Message 'Legacy registry manifest migration failed' -Context @{ event = 'legacy_yaml_parse_failed'; path = $rootYaml } -Exception $_
            $allSucceeded = $false
        }
    }

    foreach ($dir in $nestedYaml) {
        if ($dir.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            Write-LegacyYamlWarning "Legacy workflow YAML under linked registry directory $($dir.FullName) was not migrated. Convert the linked source explicitly."
            $allSucceeded = $false
            continue
        }
        if (-not (Invoke-LegacyYamlDirReconciliation -Dir $dir.FullName)) {
            $allSucceeded = $false
        }
    }
    return $allSucceeded
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

    $registriesRoot = Join-Path $DotbotBase 'registries'
    $configPath = Join-Path $DotbotBase 'registries.json'
    if (-not (Test-Path -LiteralPath $registriesRoot) -or -not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        $script:RegistryYamlMigrationDone[$key] = $true
        return
    }

    try {
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    } catch {
        Write-LegacyYamlError "Could not read registry configuration for YAML migration: $($_.Exception.Message)"
        return
    }

    $rootFull = [System.IO.Path]::GetFullPath($registriesRoot).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    ) + [System.IO.Path]::DirectorySeparatorChar
    $allSucceeded = $true
    foreach ($entry in @($config.registries)) {
        $name = [string]$entry.name
        $safeName = [System.IO.Path]::GetFileName($name)
        if ($safeName -ne $name -or $safeName -in @('.', '..') -or $safeName -notmatch '^[A-Za-z0-9._-]+$') {
            Write-LegacyYamlWarning "Registry name '$name' is invalid — skipping YAML migration"
            $allSucceeded = $false
            continue
        }
        $registryPath = [System.IO.Path]::GetFullPath((Join-Path $registriesRoot $safeName))
        if (-not $registryPath.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-LegacyYamlWarning "Registry '$name' resolves outside the registries directory — skipping YAML migration"
            $allSucceeded = $false
            continue
        }
        if (-not (Invoke-DotbotSingleRegistryYamlMigration -RegistryPath $registryPath -ExpectedName $name)) {
            $allSucceeded = $false
        }
    }
    if ($allSucceeded) {
        $script:RegistryYamlMigrationDone[$key] = $true
    }
}
