<#
.SYNOPSIS
Reference cache for prompt file cross-references

.DESCRIPTION
Builds and manages a cache of inter-file references across .bot/prompts/ directories.
Provides file content retrieval with reference resolution.
Extracted from server.ps1 for modularity.
#>

$script:Config = @{
    BotRoot = $null
    ProjectRoot = $null
}

function Initialize-ReferenceCache {
    param(
        [Parameter(Mandatory)] [string]$BotRoot,
        [Parameter(Mandatory)] [string]$ProjectRoot
    )
    $script:Config.BotRoot = $BotRoot
    $script:Config.ProjectRoot = $ProjectRoot
}

function Get-CacheLocation {
    $projectRoot = $script:Config.ProjectRoot

    $projectHash = [System.BitConverter]::ToString(
        [System.Security.Cryptography.MD5]::Create().ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($projectRoot)
        )
    ).Replace("-", "").Substring(0, 8)

    $cachePath = Join-Path $env:TEMP ".bot-ui-cache" $projectHash
    if (-not (Test-Path $cachePath)) {
        New-Item -Path $cachePath -ItemType Directory -Force | Out-Null
    }
    return $cachePath
}

function Test-CacheValidity {
    $botRoot = $script:Config.BotRoot
    $cacheFile = Join-Path (Get-CacheLocation) "references.json"

    if (-not (Test-Path $cacheFile)) {
        return $false
    }

    try {
        $cache = Get-Content $cacheFile -Raw | ConvertFrom-Json

        # Check if any files have been modified
        foreach ($fileEntry in $cache.file_mtimes.PSObject.Properties) {
            $filePath = Join-Path $botRoot $fileEntry.Name
            if (Test-Path -LiteralPath $filePath) {
                $currentMtime = (Get-Item -LiteralPath $filePath).LastWriteTimeUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
                if ($currentMtime -ne $fileEntry.Value) {
                    return $false
                }
            }
        }

        # Cache is valid if less than 24 hours old
        $cacheAge = (Get-Date) - [DateTime]::Parse($cache.generated_at)
        return $cacheAge.TotalHours -lt 24
    } catch {
        return $false
    }
}

function Clear-ReferenceCache {
    $cacheFile = Join-Path (Get-CacheLocation) "references.json"
    if (Test-Path $cacheFile) {
        Remove-Item $cacheFile -Force
    }
    return @{
        success = $true
        message = "Cache cleared"
    }
}

# Helper: Get type from directory (generates 3-letter short type)
function Get-TypeFromDir {
    param([string]$Dir)
    return $Dir.Substring(0, [Math]::Min(3, $Dir.Length))
}

# Helper: Get type from path (extracts directory and generates short type)
function Get-TypeFromPath {
    param(
        [string]$Path,
        [string[]]$Directories = @()
    )
    if ($Path -match '^([^/]+)/') {
        $dir = $matches[1]
        return Get-TypeFromDir -Dir $dir
    }
    return 'unk'
}

# Helper: Parse reference (dynamic - extracts type from path)
function Parse-Reference {
    param(
        [string]$LinkPath,
        [string]$CurrentFile,
        [hashtable]$AllFiles
    )

    $filename = Split-Path $LinkPath -Leaf
    $name = [System.IO.Path]::GetFileNameWithoutExtension($filename)

    $type = 'unk'
    $relativePath = $filename

    # Match patterns like .bot/prompts/TYPE/subpath/file.md or ../TYPE/subpath/file.md
    if ($LinkPath -match '(?:prompts/)?(\w+)/(.+\.md)$') {
        $dir = $matches[1]
        $type = Get-TypeFromDir -Dir $dir
        $relativePath = $matches[2]
    }
    # If no directory found, try to infer from current file's directory
    elseif ($CurrentFile -match '^([^/]+)/') {
        $type = Get-TypeFromDir -Dir $matches[1]
    }

    return @{
        type = $type
        file = $relativePath
        name = $name
    }
}

# Helper: Find target path (dynamic - derives directory from short type)
function Find-TargetPath {
    param(
        [hashtable]$Reference,
        [hashtable]$AllFiles
    )

    $shortType = $Reference.type

    # Find matching directory by checking if its short type matches
    $matchingDir = $null
    foreach ($key in $AllFiles.Keys) {
        if ($key -match '^([^/]+)/') {
            $dir = $matches[1]
            if ($dir.Substring(0, [Math]::Min(3, $dir.Length)) -eq $shortType) {
                $matchingDir = $dir
                break
            }
        }
    }

    if ($matchingDir) {
        # Try direct path first
        $targetPath = "$matchingDir/$($Reference.file)"
        if ($AllFiles.ContainsKey($targetPath)) {
            return $targetPath
        }

        # Try with subdirectories
        foreach ($key in $AllFiles.Keys) {
            $escapedFile = [regex]::Escape($Reference.file)
            if ($key -match "^$matchingDir/.*$escapedFile$") {
                return $key
            }
        }
    }

    return $null
}

function Build-ReferenceCache {
    $botRoot = $script:Config.BotRoot
    $projectRoot = $script:Config.ProjectRoot

    Write-Host ""
    Write-Status "Building reference cache..." -Type Process

    $cache = @{
        generated_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        project_root = $projectRoot
        file_mtimes = @{}
        references = @{}
    }

    # Dynamically discover directories under .bot/prompts/
    $promptsDir = Join-Path $botRoot "prompts"
    $dirs = @()
    if (Test-Path $promptsDir) {
        $dirs = @(Get-ChildItem -Path $promptsDir -Directory | ForEach-Object { $_.Name })
    }
    $allFiles = @{}

    # First pass: collect all files
    foreach ($dir in $dirs) {
        $dirPath = Join-Path $botRoot "prompts\$dir"
        if (Test-Path $dirPath) {
            $mdFiles = Get-ChildItem -Path $dirPath -Filter "*.md" -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch '\\archived\\' }

            foreach ($file in $mdFiles) {
                $relativePath = "$dir/" + $file.FullName.Replace("$dirPath\", "").Replace("\", "/")
                $allFiles[$relativePath] = $file.FullName
                $cache.file_mtimes[$relativePath] = $file.LastWriteTimeUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
            }
        }
    }

    # Second pass: parse references
    foreach ($entry in $allFiles.GetEnumerator()) {
        $relativePath = $entry.Key
        $fullPath = $entry.Value
        $content = Get-Content -Path $fullPath -Raw

        $references = @()

        # Parse markdown links: [text](path.md)
        $mdLinkPattern = '\[([^\]]+)\]\(([^\)]+\.md)\)'
        $regexMatches = [regex]::Matches($content, $mdLinkPattern)
        foreach ($m in $regexMatches) {
            if ($null -ne $m -and $null -ne $m.Groups -and $m.Groups.Count -gt 2) {
                $linkPath = $m.Groups[2].Value
                $references += Parse-Reference -LinkPath $linkPath -CurrentFile $relativePath -AllFiles $allFiles
            }
        }

        # Parse agent directives: @.bot/prompts/agents/name.md
        $agentPattern = '@\.bot/prompts/(\w+)/([^\s]+\.md)'
        $regexMatches = [regex]::Matches($content, $agentPattern)
        foreach ($m in $regexMatches) {
            if ($null -ne $m -and $null -ne $m.Groups -and $m.Groups.Count -gt 2) {
                $dir = $m.Groups[1].Value
                $refFullPath = $m.Groups[2].Value
                $filename = Split-Path $refFullPath -Leaf
                $references += @{
                    type = Get-TypeFromDir -Dir $dir
                    file = $refFullPath
                    name = [System.IO.Path]::GetFileNameWithoutExtension($filename)
                }
            }
        }

        # Parse path references: .bot/prompts/standards/global/file.md
        $pathPattern = '\.bot/prompts/(\w+)/([^\s]+\.md)'
        $regexMatches = [regex]::Matches($content, $pathPattern)
        foreach ($m in $regexMatches) {
            if ($null -ne $m -and $null -ne $m.Groups -and $m.Groups.Count -gt 2) {
                $dir = $m.Groups[1].Value
                $refFullPath = $m.Groups[2].Value
                $filename = Split-Path $refFullPath -Leaf
                $references += @{
                    type = Get-TypeFromDir -Dir $dir
                    file = $refFullPath
                    name = [System.IO.Path]::GetFileNameWithoutExtension($filename)
                }
            }
        }

        # Remove duplicates
        $uniqueRefs = @{}
        foreach ($ref in $references) {
            $key = "$($ref.type):$($ref.file)"
            $uniqueRefs[$key] = $ref
        }

        $cache.references[$relativePath] = @{
            references = @($uniqueRefs.Values)
            referenced_by = @()
        }
    }

    # Third pass: build reverse references
    $refKeys = @($cache.references.Keys)
    foreach ($sourcePath in $refKeys) {
        $entry = $cache.references[$sourcePath]
        if ($null -eq $entry) { continue }
        $refs = $entry.references
        if ($null -eq $refs) { continue }

        foreach ($ref in @($refs)) {
            if ($null -eq $ref) { continue }
            try {
                # Find the target file
                $targetPath = Find-TargetPath -Reference $ref -AllFiles $allFiles
                if ($targetPath -and $cache.references.ContainsKey($targetPath)) {
                    $sourceType = Get-TypeFromPath -Path $sourcePath -Directories $dirs
                    $sourceRelativePath = $sourcePath -replace '^[^/]+/', ''

                    if ($null -eq $cache.references[$targetPath].referenced_by) {
                        $cache.references[$targetPath].referenced_by = @()
                    }
                    $cache.references[$targetPath].referenced_by += @{
                        type = $sourceType
                        file = $sourceRelativePath
                        name = [System.IO.Path]::GetFileNameWithoutExtension($sourceRelativePath)
                    }
                }
            } catch {
                Write-Status "Error processing reference for $($ref.file): $_" -Type Warn
            }
        }
    }

    # Save cache
    $cacheFile = Join-Path (Get-CacheLocation) "references.json"
    $cache | ConvertTo-Json -Depth 10 | Set-Content -Path $cacheFile -Force

    Write-Status "Reference cache built with $($cache.references.Count) files" -Type Success
    $cache.references.Keys | Where-Object { $_ -like "*write-spec*" } | ForEach-Object { Write-Phosphor "  Cached: $_" -Color Bezel }
    return $cache
}

function Get-FileWithReferences {
    param(
        [string]$Type,
        [string]$Filename
    )
    $botRoot = $script:Config.BotRoot

    # Dynamically find directory that matches the short type
    $promptsDir = Join-Path $botRoot "prompts"
    $matchingDir = $null

    if (Test-Path $promptsDir) {
        $allDirs = Get-ChildItem -Path $promptsDir -Directory
        foreach ($dir in $allDirs) {
            $shortType = $dir.Name.Substring(0, [Math]::Min(3, $dir.Name.Length))
            if ($shortType -eq $Type) {
                $matchingDir = $dir.Name
                break
            }
        }
    }

    if (-not $matchingDir) {
        return @{
            success = $false
            error = "Invalid type: $Type"
        }
    }

    $targetDir = Join-Path $botRoot "prompts\$matchingDir"
    $filePath = Join-Path $targetDir $Filename

    if (-not (Test-Path -LiteralPath $filePath)) {
        return @{
            success = $false
            error = "File not found: $Filename"
        }
    }

    # Check cache first
    $cacheFile = Join-Path (Get-CacheLocation) "references.json"
    $cache = $null

    if (Test-CacheValidity) {
        try {
            $cache = Get-Content $cacheFile -Raw | ConvertFrom-Json
        } catch {
            # Cache invalid, will rebuild
        }
    }

    # Build cache if needed
    if (-not $cache) {
        $cache = Build-ReferenceCache
    }

    # Get file content
    $fileContent = Get-Content -LiteralPath $filePath -Raw
    $relativePath = "$matchingDir/$Filename"

    # Get references from cache
    $references = @()
    $referencedBy = @()

    Write-Phosphor "Looking up: $relativePath" -Color Bezel

    # Handle both hashtable (from Build-ReferenceCache) and PSCustomObject (from JSON)
    $hasKey = $false
    if ($cache.references -is [hashtable]) {
        $hasKey = $cache.references.ContainsKey($relativePath)
    } elseif ($null -ne $cache.references) {
        $hasKey = $null -ne $cache.references.PSObject.Properties[$relativePath]
    }

    Write-Phosphor "Cache has key? $hasKey" -Color Bezel

    if ($hasKey) {
        $fileRefs = $cache.references.$relativePath
        if ($null -ne $fileRefs) {
            $refCount = if ($fileRefs.references) { @($fileRefs.references).Count } else { 0 }
            $refByCount = if ($fileRefs.referenced_by) { @($fileRefs.referenced_by).Count } else { 0 }
            Write-Status "Found refs: $refCount, refBy: $refByCount" -Type Success
            if ($fileRefs.references) {
                $references = @($fileRefs.references)
            }
            if ($fileRefs.referenced_by) {
                $referencedBy = @($fileRefs.referenced_by)
            }
        }
    } else {
        Write-Status "Key not found in cache!" -Type Error
    }

    return @{
        success = $true
        name = $Filename
        content = $fileContent
        references = $references
        referencedBy = $referencedBy
        cacheAge = if ($cache.generated_at) {
            [int]((Get-Date) - [DateTime]::Parse($cache.generated_at)).TotalMinutes
        } else { 0 }
    }
}

Export-ModuleMember -Function @(
    'Initialize-ReferenceCache',
    'Get-CacheLocation',
    'Test-CacheValidity',
    'Clear-ReferenceCache',
    'Get-FileWithReferences',
    'Build-ReferenceCache'
)
