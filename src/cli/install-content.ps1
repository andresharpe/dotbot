#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Install dotbot content into the current project or DOTBOT_HOME content.

.DESCRIPTION
    Installs agents, prompts, and skills from built-in content, a local path, a
    registered dotbot registry alias, or a GitHub repository path. GitHub and
    registry sources may point at an entity directory that contains vN
    subdirectories; the latest version is selected unless -Version is supplied
    or the source ends in :vN.

.PARAMETER Type
    Content entity type: agent(s), prompt(s), or skill(s).

.PARAMETER Source
    Built-in name, local file/directory, registry alias, or GitHub URL/path.

.PARAMETER From
    Alias source argument, matching dotbot install runtime --from.

.PARAMETER Version
    Optional numeric or vN version to select from versioned entity folders.

.PARAMETER GlobalInstall
    Install under <DOTBOT_HOME>/content instead of the current project's .bot/.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('agent','agents','prompt','prompts','skill','skills')]
    [string]$Type,

    [Parameter(Position = 1)]
    [string]$Source,

    [string]$From,

    [string]$Version,

    [Alias('global')]
    [switch]$GlobalInstall,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

Import-Module (Join-Path $PSScriptRoot '..' 'runtime' 'Modules' 'Dotbot.Core' 'Dotbot.Core.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Platform-Functions.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..' 'runtime' 'Modules' 'Dotbot.Theme' 'Dotbot.Theme.psd1') -Force -DisableNameChecking

$script:TemporaryInstallRoots = @()

function ConvertTo-DotbotContentType {
    param([Parameter(Mandatory)][string]$Value)

    switch ($Value.ToLowerInvariant()) {
        'agent'  { return 'agents' }
        'agents' { return 'agents' }
        'prompt' { return 'prompts' }
        'prompts' { return 'prompts' }
        'skill'  { return 'skills' }
        'skills' { return 'skills' }
    }
}

function Normalize-DotbotContentVersion {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $trimmed = $Value.Trim()
    if ($trimmed -match '^\d+$') { return "v$trimmed" }
    if ($trimmed -match '^v\d+$') { return $trimmed.ToLowerInvariant() }
    throw "Version must be numeric or vN, got '$Value'."
}

function Split-DotbotInstallSourceVersion {
    param(
        [Parameter(Mandatory)][string]$Value,
        [string]$ExplicitVersion
    )

    $sourceValue = $Value.Trim()
    $versionValue = Normalize-DotbotContentVersion -Value $ExplicitVersion
    if (-not $versionValue -and $sourceValue -match '^(?<base>.+):(?<version>v?\d+)$') {
        $sourceValue = $Matches.base
        $versionValue = Normalize-DotbotContentVersion -Value $Matches.version
    }

    [pscustomobject]@{
        Source  = $sourceValue
        Version = $versionValue
    }
}

function Expand-DotbotContentPath {
    param([Parameter(Mandatory)][string]$Path)

    $expanded = $Path.Trim()
    if ($expanded -eq '~') {
        $expanded = $HOME
    } elseif ($expanded.StartsWith('~/') -or $expanded.StartsWith('~\')) {
        $expanded = Join-Path $HOME $expanded.Substring(2)
    }

    try {
        return [System.IO.Path]::GetFullPath($expanded)
    } catch {
        return $expanded
    }
}

function Find-DotbotProjectBotDir {
    param([string]$StartDir)

    $dir = [System.IO.Path]::GetFullPath($StartDir)
    while (-not [string]::IsNullOrWhiteSpace($dir)) {
        $candidate = Join-Path $dir '.bot'
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }

        if (Test-Path -LiteralPath (Join-Path $dir '.git')) { break }

        $parent = Split-Path -Parent $dir
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $dir) { break }
        $dir = $parent
    }

    return $null
}

function Test-GitHubContentSource {
    param([Parameter(Mandatory)][string]$Value)

    $trimmed = $Value.Trim()
    return ($trimmed -match '^(https?://)?github\.com/' -or
            $trimmed -match '^https?://raw\.githubusercontent\.com/')
}

function ConvertFrom-GitHubContentSource {
    param([Parameter(Mandatory)][string]$Value)

    $url = $Value.Trim()
    if ($url.StartsWith('github.com/')) {
        $url = "https://$url"
    }

    try {
        $uri = [System.Uri]::new($url)
    } catch {
        throw "GitHub source is not a valid URL: $Value"
    }

    $segments = @($uri.AbsolutePath.Trim('/') -split '/' | Where-Object { $_ -ne '' } | ForEach-Object {
        [System.Uri]::UnescapeDataString($_)
    })

    if ($uri.Host -eq 'raw.githubusercontent.com') {
        if ($segments.Count -lt 4) {
            throw "Raw GitHub source must include owner, repo, ref, and path: $Value"
        }
        $owner = $segments[0]
        $repo = $segments[1]
        $ref = $segments[2]
        $pathSegments = @($segments[3..($segments.Count - 1)])
        return [pscustomobject]@{
            CloneUrl = "https://github.com/$owner/$repo.git"
            Ref      = $ref
            Path     = ($pathSegments -join '/')
        }
    }

    if ($uri.Host -ne 'github.com') {
        throw "Only github.com sources are supported for URL installs."
    }
    if ($segments.Count -lt 2) {
        throw "GitHub source must include owner and repo: $Value"
    }

    $owner = $segments[0]
    $repo = $segments[1] -replace '\.git$', ''
    $ref = $null
    $pathSegments = @()

    if ($segments.Count -gt 2) {
        if ($segments[2] -in @('tree','blob')) {
            if ($segments.Count -lt 4) {
                throw "GitHub tree/blob source must include a ref: $Value"
            }
            $ref = $segments[3]
            if ($segments.Count -gt 4) {
                $pathSegments = @($segments[4..($segments.Count - 1)])
            }
        } else {
            $pathSegments = @($segments[2..($segments.Count - 1)])
        }
    }

    [pscustomobject]@{
        CloneUrl = "https://github.com/$owner/$repo.git"
        Ref      = $ref
        Path     = ($pathSegments -join '/')
    }
}

function Resolve-DotbotRegistrySourcePath {
    param(
        [Parameter(Mandatory)][string]$ContentType,
        [Parameter(Mandatory)][string]$RequestedSource
    )

    $trimmed = $RequestedSource.Trim()
    if ($trimmed -match '^[A-Za-z]:[\\/]') {
        return $null
    }
    if ($trimmed -notmatch '^(?<registry>[A-Za-z0-9._-]+)[:/](?<path>.+)$') {
        return $null
    }

    $registryName = $Matches.registry
    $relativePath = ($Matches.path -replace '\\','/').Trim('/')
    if ([string]::IsNullOrWhiteSpace($relativePath)) {
        throw "Registry alias '$RequestedSource' must include a path after '$registryName/'."
    }

    $segments = @($relativePath -split '/' | Where-Object { $_ -ne '' })
    if ($segments.Count -eq 0 -or @($segments | Where-Object { $_ -eq '..' }).Count -gt 0) {
        throw "Registry alias '$RequestedSource' contains an invalid path."
    }

    $dotbotBase = Get-DotbotInstallPath
    $registryRoot = Join-Path $dotbotBase 'registries' $registryName
    if (-not (Test-Path -LiteralPath $registryRoot -PathType Container)) {
        throw "Registry '$registryName' is not installed. Run 'dotbot registry add $registryName <source>' first."
    }

    $registryRootFull = (Resolve-Path -LiteralPath $registryRoot).Path.TrimEnd('\','/')
    $candidateSpecs = @()
    $candidateSpecs += ,([string[]]$segments)
    if ($ContentType -eq 'prompts' -and -not $segments[-1].EndsWith('.md')) {
        $promptSegments = @($segments)
        $promptSegments[-1] = "$($promptSegments[-1]).md"
        $candidateSpecs += ,([string[]]$promptSegments)
    }

    if ($segments[0] -ne $ContentType) {
        $typedSegments = @($ContentType) + $segments
        $candidateSpecs += ,([string[]]$typedSegments)
        if ($ContentType -eq 'prompts' -and -not $segments[-1].EndsWith('.md')) {
            $typedPromptSegments = @($ContentType) + $segments
            $typedPromptSegments[-1] = "$($typedPromptSegments[-1]).md"
            $candidateSpecs += ,([string[]]$typedPromptSegments)
        }
    }

    foreach ($candidateSegments in $candidateSpecs) {
        $candidate = $registryRootFull
        foreach ($segment in $candidateSegments) {
            $candidate = Join-Path $candidate $segment
        }

        try {
            $candidateFull = [System.IO.Path]::GetFullPath($candidate)
        } catch {
            continue
        }

        $prefix = "$registryRootFull$([System.IO.Path]::DirectorySeparatorChar)"
        if ($candidateFull -ne $registryRootFull -and
            -not $candidateFull.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Registry alias '$RequestedSource' resolved outside registry '$registryName'."
        }

        if (Test-Path -LiteralPath $candidateFull) {
            return (Resolve-Path -LiteralPath $candidateFull).Path
        }
    }

    throw "Registry source not found: $RequestedSource"
}

function Invoke-DotbotGitClone {
    param(
        [Parameter(Mandatory)][string]$CloneUrl,
        [string]$Ref
    )

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "git is required to install content from GitHub."
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-content-$([guid]::NewGuid().ToString('N'))"
    $script:TemporaryInstallRoots += $tempRoot

    $cloneArgs = @('clone', '--depth', '1')
    if ($Ref) {
        $cloneArgs += @('--branch', $Ref)
    }
    $cloneArgs += @($CloneUrl, $tempRoot)

    $output = & git @cloneArgs 2>&1
    if ($LASTEXITCODE -eq 0) {
        return $tempRoot
    }

    if ($Ref) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        $output = & git clone $CloneUrl $tempRoot 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "git clone failed for $CloneUrl. $($output -join "`n")"
        }
        $checkoutOutput = & git -C $tempRoot checkout $Ref 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "git checkout '$Ref' failed for $CloneUrl. $($checkoutOutput -join "`n")"
        }
        return $tempRoot
    }

    throw "git clone failed for $CloneUrl. $($output -join "`n")"
}

function Resolve-DotbotInstallSourcePath {
    param(
        [Parameter(Mandatory)][string]$ContentType,
        [Parameter(Mandatory)][string]$RequestedSource
    )

    if (Test-GitHubContentSource -Value $RequestedSource) {
        $parsed = ConvertFrom-GitHubContentSource -Value $RequestedSource
        $cloneRoot = Invoke-DotbotGitClone -CloneUrl $parsed.CloneUrl -Ref $parsed.Ref
        $candidate = if ($parsed.Path) { Join-Path $cloneRoot $parsed.Path } else { $cloneRoot }
        if (-not (Test-Path -LiteralPath $candidate)) {
            throw "GitHub source path not found after clone: $($parsed.Path)"
        }
        return (Resolve-Path -LiteralPath $candidate).Path
    }

    $localPath = Expand-DotbotContentPath -Path $RequestedSource
    if (Test-Path -LiteralPath $localPath) {
        return (Resolve-Path -LiteralPath $localPath).Path
    }

    $registryPath = Resolve-DotbotRegistrySourcePath -ContentType $ContentType -RequestedSource $RequestedSource
    if ($registryPath) {
        return $registryPath
    }

    $dotbotBase = Get-DotbotInstallPath
    $candidates = @()
    if ($ContentType -eq 'prompts') {
        $promptName = if ($RequestedSource.EndsWith('.md')) { $RequestedSource } else { "$RequestedSource.md" }
        $candidates += (Join-Path $dotbotBase 'content' 'prompts' $promptName)
    } else {
        $candidates += (Join-Path $dotbotBase 'content' $ContentType $RequestedSource)
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw "Content source not found: $RequestedSource"
}

function Test-DotbotVersionSegment {
    param([string]$Name)

    return ($Name -match '^v\d+$')
}

function Get-DotbotVersionNumber {
    param([string]$Name)

    if ($Name -match '^v(?<n>\d+)$') { return [int]$Matches.n }
    return -1
}

function Get-DotbotContentNameFromVersionedDir {
    param([Parameter(Mandatory)][string]$Dir)

    $leaf = Split-Path $Dir -Leaf
    if (Test-DotbotVersionSegment -Name $leaf) {
        return (Split-Path (Split-Path $Dir -Parent) -Leaf)
    }
    return $leaf
}

function Read-DotbotMarkdownFrontMatter {
    param([Parameter(Mandatory)][string]$Path)

    $result = @{}
    try {
        $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    } catch {
        return $result
    }

    $match = [regex]::Match($text, "^\s*---\r?\n(?<body>.*?)\r?\n---", [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $match.Success) { return $result }

    $reader = [System.IO.StringReader]::new($match.Groups['body'].Value)
    try {
        while ($true) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { break }
            if ($line -match '^\s*(?<key>[A-Za-z0-9_-]+)\s*:\s*(?<value>.+?)\s*$') {
                $value = $Matches.value.Trim()
                if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
                    ($value.StartsWith("'") -and $value.EndsWith("'"))) {
                    $value = $value.Substring(1, $value.Length - 2)
                }
                $result[$Matches.key] = $value
            }
        }
    } finally {
        $reader.Dispose()
    }

    return $result
}

function Test-DotbotEntityContentDir {
    param(
        [Parameter(Mandatory)][string]$ContentType,
        [Parameter(Mandatory)][string]$Dir
    )

    switch ($ContentType) {
        'skills'  { return (Test-Path -LiteralPath (Join-Path $Dir 'SKILL.md') -PathType Leaf) }
        'agents'  {
            if (Test-Path -LiteralPath (Join-Path $Dir 'AGENT.md') -PathType Leaf) { return $true }
            return (@(Get-ChildItem -LiteralPath $Dir -Filter '*.md' -File -ErrorAction SilentlyContinue).Count -gt 0)
        }
        'prompts' {
            return (@(Get-ChildItem -LiteralPath $Dir -Filter '*.md' -File -ErrorAction SilentlyContinue).Count -gt 0)
        }
    }
}

function Resolve-DotbotVersionedContentDir {
    param(
        [Parameter(Mandatory)][string]$ContentType,
        [Parameter(Mandatory)][string]$Dir,
        [string]$Version
    )

    $selected = (Resolve-Path -LiteralPath $Dir).Path
    $leaf = Split-Path $selected -Leaf

    if ($Version) {
        if ((Test-DotbotVersionSegment -Name $leaf) -and $leaf.ToLowerInvariant() -eq $Version) {
            return $selected
        }

        $versionDir = Join-Path $selected $Version
        if (Test-Path -LiteralPath $versionDir -PathType Container) {
            return (Resolve-Path -LiteralPath $versionDir).Path
        }

        throw "Version '$Version' not found under $Dir."
    }

    if (Test-DotbotEntityContentDir -ContentType $ContentType -Dir $selected) {
        return $selected
    }

    $versions = @(Get-ChildItem -LiteralPath $selected -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-DotbotVersionSegment -Name $_.Name } |
        Sort-Object @{ Expression = { Get-DotbotVersionNumber -Name $_.Name }; Descending = $true })

    if ($versions.Count -gt 0) {
        return $versions[0].FullName
    }

    return $selected
}

function Resolve-DotbotPromptFile {
    param([Parameter(Mandatory)][string]$Dir)

    $nameHint = Get-DotbotContentNameFromVersionedDir -Dir $Dir
    $preferred = Join-Path $Dir "$nameHint.md"
    if (Test-Path -LiteralPath $preferred -PathType Leaf) {
        return (Resolve-Path -LiteralPath $preferred).Path
    }

    $files = @(Get-ChildItem -LiteralPath $Dir -Filter '*.md' -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 1) {
        return $files[0].FullName
    }
    if ($files.Count -gt 1) {
        throw "Prompt directory '$Dir' contains multiple markdown files. Name the prompt file '$nameHint.md' or install a specific file."
    }

    throw "Prompt source '$Dir' does not contain a markdown file."
}

function Resolve-DotbotAgentFile {
    param([Parameter(Mandatory)][string]$Dir)

    $canonical = Join-Path $Dir 'AGENT.md'
    if (Test-Path -LiteralPath $canonical -PathType Leaf) {
        return (Resolve-Path -LiteralPath $canonical).Path
    }

    $nameHint = Get-DotbotContentNameFromVersionedDir -Dir $Dir
    $preferred = Join-Path $Dir "$nameHint.md"
    if (Test-Path -LiteralPath $preferred -PathType Leaf) {
        return (Resolve-Path -LiteralPath $preferred).Path
    }

    $files = @(Get-ChildItem -LiteralPath $Dir -Filter '*.md' -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 1) {
        return $files[0].FullName
    }
    if ($files.Count -gt 1) {
        throw "Agent directory '$Dir' contains multiple markdown files. Name the agent file 'AGENT.md' or '$nameHint.md'."
    }

    throw "Agent source '$Dir' does not contain a markdown file."
}

function Assert-DotbotContentName {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Source
    )

    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -notmatch '^[A-Za-z0-9._-]+$') {
        throw "Invalid content name '$Name' from $Source. Names may contain letters, numbers, dot, underscore, and dash."
    }
}

function Resolve-DotbotContentPayload {
    param(
        [Parameter(Mandatory)][string]$ContentType,
        [Parameter(Mandatory)][string]$SourcePath,
        [string]$Version
    )

    $item = Get-Item -LiteralPath $SourcePath -Force -ErrorAction Stop
    if (-not $item.PSIsContainer) {
        if ($ContentType -eq 'prompts') {
            if ($item.Extension -ne '.md') { throw "Prompt source must be a markdown file: $SourcePath" }
            $name = [System.IO.Path]::GetFileNameWithoutExtension($item.Name)
            Assert-DotbotContentName -Name $name -Source $SourcePath
            return [pscustomobject]@{
                Type       = $ContentType
                Name       = $name
                SourcePath = $item.FullName
                CopyMode   = 'prompt-file'
            }
        }

        if ($ContentType -eq 'agents' -and $item.Extension -eq '.md') {
            $frontMatter = Read-DotbotMarkdownFrontMatter -Path $item.FullName
            $name = if ($frontMatter.ContainsKey('name')) { [string]$frontMatter['name'] } else { [System.IO.Path]::GetFileNameWithoutExtension($item.Name) }
            Assert-DotbotContentName -Name $name -Source $SourcePath
            return [pscustomobject]@{
                Type       = $ContentType
                Name       = $name
                SourcePath = $item.FullName
                CopyMode   = 'agent-file'
            }
        }

        throw "Source file '$SourcePath' is not valid for $ContentType."
    }

    $selectedDir = Resolve-DotbotVersionedContentDir -ContentType $ContentType -Dir $item.FullName -Version $Version

    switch ($ContentType) {
        'prompts' {
            $promptFile = Resolve-DotbotPromptFile -Dir $selectedDir
            $name = [System.IO.Path]::GetFileNameWithoutExtension((Split-Path $promptFile -Leaf))
            Assert-DotbotContentName -Name $name -Source $promptFile
            return [pscustomobject]@{
                Type       = $ContentType
                Name       = $name
                SourcePath = $promptFile
                CopyMode   = 'prompt-file'
            }
        }
        'skills' {
            $skillFile = Join-Path $selectedDir 'SKILL.md'
            if (-not (Test-Path -LiteralPath $skillFile -PathType Leaf)) {
                throw "Skill source '$selectedDir' does not contain SKILL.md."
            }
            $frontMatter = Read-DotbotMarkdownFrontMatter -Path $skillFile
            $name = if ($frontMatter.ContainsKey('name')) { [string]$frontMatter['name'] } else { Get-DotbotContentNameFromVersionedDir -Dir $selectedDir }
            Assert-DotbotContentName -Name $name -Source $skillFile
            return [pscustomobject]@{
                Type       = $ContentType
                Name       = $name
                SourcePath = $selectedDir
                CopyMode   = 'directory'
            }
        }
        'agents' {
            $agentFile = Resolve-DotbotAgentFile -Dir $selectedDir
            $frontMatter = Read-DotbotMarkdownFrontMatter -Path $agentFile
            $name = if ($frontMatter.ContainsKey('name')) { [string]$frontMatter['name'] } else {
                $leaf = Split-Path $agentFile -Leaf
                if ($leaf -eq 'AGENT.md') { Get-DotbotContentNameFromVersionedDir -Dir $selectedDir } else { [System.IO.Path]::GetFileNameWithoutExtension($leaf) }
            }
            Assert-DotbotContentName -Name $name -Source $agentFile
            $copyMode = if ((Split-Path $agentFile -Leaf) -eq 'AGENT.md') { 'directory' } else { 'agent-file' }
            return [pscustomobject]@{
                Type       = $ContentType
                Name       = $name
                SourcePath = if ($copyMode -eq 'directory') { $selectedDir } else { $agentFile }
                CopyMode   = $copyMode
            }
        }
    }
}

function Copy-DotbotDirectoryContents {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }

    Get-ChildItem -LiteralPath $Source -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @('.git', '.github') } |
        ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force -ErrorAction Stop
        }
}

function Confirm-DotbotContentReplacement {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )

    if ($Force) { return $true }
    if (-not (Test-Path -LiteralPath $Path)) { return $true }

    Write-DotbotWarning "$Label already exists: $Path"
    return (Read-DotbotConfirmation -Message 'Replace the installed content?' -Default $false)
}

function Install-DotbotContentPayload {
    param(
        [Parameter(Mandatory)]$Payload,
        [Parameter(Mandatory)][string]$DestinationContentRoot
    )

    $typeRoot = Join-Path $DestinationContentRoot $Payload.Type
    New-Item -ItemType Directory -Path $typeRoot -Force | Out-Null

    if ($Payload.Type -eq 'prompts') {
        $targetPath = Join-Path $typeRoot "$($Payload.Name).md"
        if (-not (Confirm-DotbotContentReplacement -Path $targetPath -Label 'Prompt')) {
            Write-DotbotCommand "Prompt install unchanged."
            return [pscustomobject]@{ Changed = $false; Path = $targetPath }
        }
        Copy-Item -LiteralPath $Payload.SourcePath -Destination $targetPath -Force
        return [pscustomobject]@{ Changed = $true; Path = $targetPath }
    }

    $targetDir = Join-Path $typeRoot $Payload.Name
    if (-not (Confirm-DotbotContentReplacement -Path $targetDir -Label ($Payload.Type.TrimEnd('s')))) {
        Write-DotbotCommand "Content install unchanged."
        return [pscustomobject]@{ Changed = $false; Path = $targetDir }
    }

    if (Test-Path -LiteralPath $targetDir) {
        Remove-Item -LiteralPath $targetDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null

    if ($Payload.CopyMode -eq 'directory') {
        Copy-DotbotDirectoryContents -Source $Payload.SourcePath -Destination $targetDir
    } elseif ($Payload.CopyMode -eq 'agent-file') {
        Copy-Item -LiteralPath $Payload.SourcePath -Destination (Join-Path $targetDir 'AGENT.md') -Force
    } else {
        throw "Unsupported copy mode: $($Payload.CopyMode)"
    }

    return [pscustomobject]@{ Changed = $true; Path = $targetDir }
}

$requestedSource = if (-not [string]::IsNullOrWhiteSpace($From)) { $From } else { $Source }
if ([string]::IsNullOrWhiteSpace($requestedSource)) {
    Write-DotbotWarning "Usage: dotbot install <agent|prompt|skill> <name-or-source> [--from <path|registry/path|github-url>] [--version <vN>] [--global] [--force]"
    exit 1
}

try {
    $contentType = ConvertTo-DotbotContentType -Value $Type
    $sourceRequest = Split-DotbotInstallSourceVersion -Value $requestedSource -ExplicitVersion $Version
    $sourcePath = Resolve-DotbotInstallSourcePath -ContentType $contentType -RequestedSource $sourceRequest.Source
    $payload = Resolve-DotbotContentPayload -ContentType $contentType -SourcePath $sourcePath -Version $sourceRequest.Version

    $botDir = $null
    if (-not $GlobalInstall) {
        $botDir = Find-DotbotProjectBotDir -StartDir (Get-Location).Path
        if (-not $botDir) {
            Write-DotbotError "Project is not initialized."
            Write-DotbotCommand "Run 'dotbot init' first, or add --global to install into DOTBOT_HOME content."
            exit 1
        }
    }

    $destinationRoot = if ($GlobalInstall) {
        Get-DotbotUserContentPath
    } else {
        Join-Path $botDir 'content'
    }

    Write-DotbotBanner -Title 'D O T B O T' -Subtitle 'Content Install'
    Write-Status "Entity: $contentType/$($payload.Name)"
    Write-DotbotCommand "Source: $sourcePath"
    Write-DotbotCommand "Target: $destinationRoot"
    if ($GlobalInstall) {
        Write-DotbotCommand "Scope: DOTBOT_HOME content"
    } else {
        Write-DotbotCommand "Scope: project"
    }

    $result = Install-DotbotContentPayload -Payload $payload -DestinationContentRoot $destinationRoot
    if ($result.Changed) {
        $relative = if ($GlobalInstall) {
            $result.Path
        } else {
            [System.IO.Path]::GetRelativePath($botDir, $result.Path)
        }
        Write-Success "Installed $contentType/$($payload.Name) at $relative"
    }
} catch {
    Write-DotbotError "Failed to install content: $($_.Exception.Message)"
    exit 1
} finally {
    foreach ($tempRoot in $script:TemporaryInstallRoots) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
