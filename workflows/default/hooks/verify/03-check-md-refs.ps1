param(
    [string]$TaskId,
    [string]$Category,
    [switch]$StagedOnly,
    [string]$RepoRoot
)

# Validate .bot/recipes/ and .bot/workflows/.../recipes/ path references
# in markdown, JSON, and YAML source files against the actual source tree.
#
# At source time, runtime paths like .bot/recipes/agents/implementer/AGENT.md
# map to workflows/default/recipes/agents/implementer/AGENT.md (or any
# workflow/stack that provides the file).

$issues = @()
$totalRefs = 0
$validRefs = 0
$skippedRefs = 0
$filesScanned = 0

# Resolve repo root
if (-not $RepoRoot) {
    $RepoRoot = try { (git rev-parse --show-toplevel 2>$null) } catch { $null }
}
if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
}
$RepoRoot = (Resolve-Path $RepoRoot).Path

# ── Phase 1: Build file index ──────────────────────────────────────────────
# Map runtime keys → source paths. A runtime key is the path after stripping .bot/
# e.g., "recipes/agents/implementer/AGENT.md"

$fileIndex = @{}  # runtime-key → @(source-paths)

function Add-ToIndex {
    param([string]$RuntimeKey, [string]$SourcePath)
    $key = $RuntimeKey -replace '\\', '/'
    if (-not $fileIndex.ContainsKey($key)) {
        $fileIndex[$key] = [System.Collections.Generic.List[string]]::new()
    }
    $fileIndex[$key].Add($SourcePath)
}

# Scan workflows/*/recipes/ and workflows/*/workspace/
$workflowsDir = Join-Path $RepoRoot "workflows"
if (Test-Path $workflowsDir) {
    Get-ChildItem $workflowsDir -Directory | ForEach-Object {
        $wfName = $_.Name
        $recipesDir = Join-Path $_.FullName "recipes"
        if (Test-Path $recipesDir) {
            Get-ChildItem $recipesDir -File -Recurse | ForEach-Object {
                $relToRecipes = $_.FullName.Substring($recipesDir.Length + 1) -replace '\\', '/'
                # Maps to .bot/recipes/{relToRecipes}
                Add-ToIndex -RuntimeKey "recipes/$relToRecipes" -SourcePath $_.FullName
                # Also maps to .bot/workflows/{wfName}/recipes/{relToRecipes}
                Add-ToIndex -RuntimeKey "workflows/$wfName/recipes/$relToRecipes" -SourcePath $_.FullName
            }
        }
    }
}

# Scan stacks/*/recipes/
$stacksDir = Join-Path $RepoRoot "stacks"
if (Test-Path $stacksDir) {
    Get-ChildItem $stacksDir -Directory | ForEach-Object {
        $recipesDir = Join-Path $_.FullName "recipes"
        if (Test-Path $recipesDir) {
            Get-ChildItem $recipesDir -File -Recurse | ForEach-Object {
                $relToRecipes = $_.FullName.Substring($recipesDir.Length + 1) -replace '\\', '/'
                Add-ToIndex -RuntimeKey "recipes/$relToRecipes" -SourcePath $_.FullName
            }
        }
    }
}

# ── Phase 2: Determine files to scan ───────────────────────────────────────

$scanExtensions = @('.md', '.json', '.yaml', '.yml')
$scanDirs = @('workflows', 'stacks')

# If no workflows/ or stacks/ dirs exist, this is a target project, not the dotbot source repo.
# Skip validation — the hook only validates source-level references.
$hasSourceDirs = $scanDirs | Where-Object { Test-Path (Join-Path $RepoRoot $_) }
if (-not $hasSourceDirs) {
    @{
        success  = $true
        script   = "03-check-md-refs.ps1"
        message  = "Skipped — no workflows/ or stacks/ directory (not a dotbot source repo)"
        details  = @{ files_scanned = 0; references_found = 0; references_valid = 0; references_skipped = 0; references_broken = 0; scan_mode = if ($StagedOnly) { 'staged' } else { 'full' } }
        failures = @()
    } | ConvertTo-Json -Depth 10
    return
}

if ($StagedOnly) {
    $stagedFiles = git diff --cached --name-only --diff-filter=ACM 2>$null
    $filesToScan = @($stagedFiles | Where-Object {
        $file = $_
        $ext = [System.IO.Path]::GetExtension($file)
        ($ext -in $scanExtensions) -and ($scanDirs | Where-Object { $file.StartsWith("$_/") -or $file.StartsWith("$_\") })
    } | ForEach-Object { Join-Path $RepoRoot $_ })
} else {
    $filesToScan = @()
    foreach ($dir in $scanDirs) {
        $fullDir = Join-Path $RepoRoot $dir
        if (Test-Path $fullDir) {
            $filesToScan += @(Get-ChildItem $fullDir -File -Recurse | Where-Object {
                $_.Extension -in $scanExtensions
            } | ForEach-Object { $_.FullName })
        }
    }
}

# ── Phase 3: Scan and validate references ──────────────────────────────────

# Regex to capture .bot/recipes/... or .bot/workflows/.../recipes/... paths
$refPattern = '\.bot/((?:recipes|workflows)/[^\s"''`\]\)>]+\.(?:md|json|yaml|yml|ps1|psm1))'

foreach ($file in $filesToScan) {
    if (-not (Test-Path $file)) { continue }
    $filesScanned++
    $relFile = $file.Substring($RepoRoot.Length + 1) -replace '\\', '/'
    $lines = Get-Content $file -ErrorAction SilentlyContinue
    if (-not $lines) { continue }

    $inCodeBlock = $false
    $isMdFile = $relFile -match '\.md$'

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]

        # Track fenced code blocks in markdown files (``` or ~~~)
        if ($isMdFile -and $line -match '^\s*(`{3,}|~{3,})') {
            $inCodeBlock = -not $inCodeBlock
            continue
        }

        # Skip references inside code blocks — they are examples, not real refs
        if ($inCodeBlock) { continue }

        $matches = [regex]::Matches($line, $refPattern)
        foreach ($m in $matches) {
            $totalRefs++
            $runtimeKey = $m.Groups[1].Value

            # Skip template variables: {var}, {{VAR}}, {{TASK.xxx}}
            if ($runtimeKey -match '\{[^}]*\}') {
                $skippedRefs++
                continue
            }

            # Skip glob patterns
            if ($runtimeKey -match '\*') {
                $skippedRefs++
                continue
            }

            # Look up in index
            if ($fileIndex.ContainsKey($runtimeKey)) {
                $validRefs++
            } else {
                # Broken reference — try to suggest a fix
                $leafName = Split-Path $runtimeKey -Leaf
                $suggestions = @($fileIndex.Keys | Where-Object { $_ -like "*/$leafName" -or $_ -eq $leafName })

                $issue = @{
                    file      = $relFile
                    line      = $i + 1
                    reference = ".bot/$runtimeKey"
                    issue     = "Broken reference: .bot/$runtimeKey"
                    severity  = "error"
                }
                if ($suggestions.Count -gt 0) {
                    $issue['suggestion'] = "Did you mean: .bot/$($suggestions[0])"
                }
                $issues += $issue
            }
        }
    }
}

# ── Phase 4: Output ────────────────────────────────────────────────────────

$details = @{
    files_scanned      = $filesScanned
    references_found   = $totalRefs
    references_valid   = $validRefs
    references_skipped = $skippedRefs
    references_broken  = $issues.Count
    scan_mode          = if ($StagedOnly) { 'staged' } else { 'full' }
}

if ($StagedOnly -and $issues.Count -gt 0) {
    [Console]::Error.WriteLine("")
    [Console]::Error.WriteLine("dotbot reference check: $($issues.Count) broken reference(s) in staged files:")
    foreach ($v in $issues) {
        $msg = "  $($v.file):$($v.line) - $($v.reference)"
        if ($v.suggestion) { $msg += " ($($v.suggestion))" }
        [Console]::Error.WriteLine($msg)
    }
    [Console]::Error.WriteLine("")
    [Console]::Error.WriteLine("Fix the broken references before committing.")
}

@{
    success  = ($issues.Count -eq 0)
    script   = "03-check-md-refs.ps1"
    message  = if ($issues.Count -eq 0) { "All $totalRefs path references valid ($skippedRefs skipped)" }
               else { "$($issues.Count) broken reference(s) found out of $totalRefs" }
    details  = $details
    failures = @($issues)
} | ConvertTo-Json -Depth 10
