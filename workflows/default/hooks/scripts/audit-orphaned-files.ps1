# Audit Orphaned Files Script
# Recursively parse references from .warp/workflows and identify orphaned files

$ErrorActionPreference = "Stop"

# Auto-detect project root by walking up from script location to find .git folder
$currentPath = $PSScriptRoot
while ($currentPath) {
    if (Test-Path (Join-Path $currentPath ".git")) {
        $projectRoot = $currentPath
        break
    }
    $parent = Split-Path $currentPath -Parent
    if ($parent -eq $currentPath) { break }
    $currentPath = $parent
}

if (-not $projectRoot) {
    Write-Host "Error: Could not find project root (.git folder)" -ForegroundColor Red
    exit 1
}

# Initialize tracking sets
$referencedFiles = @{}
$allBotFiles = @()
$brokenReferences = @()

# Function to normalize paths
function Normalize-Path {
    param([string]$path)
    
    # Remove leading ./ or .\
    $path = $path -replace '^\.[\\/]', ''
    
    # Convert forward slashes to backslashes for Windows
    $path = $path -replace '/', '\'
    
    # Build full path
    $fullPath = Join-Path $projectRoot $path
    
    return $fullPath
}

# Function to extract references from markdown files
function Extract-References {
    param(
        [string]$filePath,
        [string]$relativePath
    )
    
    if (-not (Test-Path $filePath)) {
        $script:brokenReferences += @{
            ReferencedBy = $relativePath
            MissingFile = $filePath
        }
        return @()
    }
    
    $content = Get-Content $filePath -Raw
    $references = @()
    
    # Pattern 1: `.bot/path/to/file.md` (in backticks)
    $pattern1 = '`\.bot/[^`]+\.md`'
    $matches1 = [regex]::Matches($content, $pattern1)
    foreach ($match in $matches1) {
        $ref = $match.Value -replace '`', ''
        $references += $ref
    }
    
    # Pattern 2: @.bot/path/to/file.md (with @ prefix)
    $pattern2 = '@\.bot/[^\s\)]+\.md'
    $matches2 = [regex]::Matches($content, $pattern2)
    foreach ($match in $matches2) {
        $ref = $match.Value -replace '@', ''
        $references += $ref
    }
    
    # Pattern 3: - .bot/path/to/file.md (in lists)
    $pattern3 = '-\s+\.bot/[^\s]+\.md'
    $matches3 = [regex]::Matches($content, $pattern3)
    foreach ($match in $matches3) {
        $ref = $match.Value -replace '^-\s+', ''
        $references += $ref
    }
    
    # Pattern 4: Follow: `.bot/path/to/file.md`
    $pattern4 = 'Follow[s]?:\s*`?\.bot/[^`\s]+\.md'
    $matches4 = [regex]::Matches($content, $pattern4)
    foreach ($match in $matches4) {
        $ref = $match.Value -replace 'Follow[s]?:\s*`?', '' -replace '`', ''
        $references += $ref
    }
    
    # Pattern 5: Execute .bot/commands/file.md
    $pattern5 = 'Execute\s+\.bot/[^\s]+\.md'
    $matches5 = [regex]::Matches($content, $pattern5)
    foreach ($match in $matches5) {
        $ref = $match.Value -replace 'Execute\s+', ''
        $references += $ref
    }
    
    # Pattern 6: **Agent:** @.bot/agents/file.md
    $pattern6 = '\*\*Agent:\*\*\s*@?\.bot/[^\s]+\.md'
    $matches6 = [regex]::Matches($content, $pattern6)
    foreach ($match in $matches6) {
        $ref = $match.Value -replace '\*\*Agent:\*\*\s*@?', ''
        $references += $ref
    }
    
    # Pattern 7: **Workflow:** or **Interaction Standard:**
    $pattern7 = '\*\*(?:Workflow|Interaction Standard):\*\*\s*(?:Follow\s+)?`?\.bot/[^`\s]+\.md'
    $matches7 = [regex]::Matches($content, $pattern7)
    foreach ($match in $matches7) {
        $ref = $match.Value -replace '\*\*(?:Workflow|Interaction Standard):\*\*\s*(?:Follow\s+)?`?', '' -replace '`', ''
        $references += $ref
    }
    
    return $references | Select-Object -Unique
}

# Function to recursively process a file
function Process-File {
    param(
        [string]$relativePath,
        [string]$referencedBy = "Entry Point"
    )
    
    $fullPath = Normalize-Path $relativePath
    
    # Skip if already processed
    if ($script:referencedFiles.ContainsKey($fullPath)) {
        return
    }
    
    # Mark as referenced
    $script:referencedFiles[$fullPath] = @{
        ReferencedBy = $referencedBy
        RelativePath = $relativePath
    }
    
    Write-Host "Processing: $relativePath" -ForegroundColor Cyan
    
    # Extract references from this file
    $references = Extract-References -filePath $fullPath -relativePath $relativePath
    
    # Recursively process each reference
    foreach ($ref in $references) {
        Process-File -relativePath $ref -referencedBy $relativePath
    }
}

# Step 1: Get all .md files in .bot directory
Write-Host "`n=== Scanning .bot directory ===" -ForegroundColor Yellow
$allBotFiles = Get-ChildItem -Path "$projectRoot\.bot" -Recurse -Filter "*.md" -File | 
    ForEach-Object { $_.FullName }

Write-Host "Found $($allBotFiles.Count) markdown files in .bot directory" -ForegroundColor Green

# Step 2: Parse all .warp/workflows/*.yaml files
Write-Host "`n=== Parsing .warp/workflows ===" -ForegroundColor Yellow
$workflowFiles = Get-ChildItem -Path "$projectRoot\.warp\workflows" -Filter "*.yaml" -File

foreach ($workflow in $workflowFiles) {
    Write-Host "`nProcessing workflow: $($workflow.Name)" -ForegroundColor Magenta
    
    $content = Get-Content $workflow.FullName -Raw
    
    # Extract command file path from YAML (look for .bot/commands/*.md)
    if ($content -match '\.bot/commands/[^\s]+\.md') {
        $commandPath = $matches[0]
        Write-Host "  Found command: $commandPath" -ForegroundColor Gray
        
        # Process this command file and all its recursive references
        Process-File -relativePath $commandPath -referencedBy ".warp/workflows/$($workflow.Name)"
    }
}

# Step 3: Identify orphaned files
Write-Host "`n=== Identifying Orphaned Files ===" -ForegroundColor Yellow
$orphanedFiles = @()

foreach ($file in $allBotFiles) {
    if (-not $script:referencedFiles.ContainsKey($file)) {
        $relativePath = $file -replace [regex]::Escape($projectRoot), '' -replace '^\\', '' -replace '\\', '/'
        $orphanedFiles += @{
            FullPath = $file
            RelativePath = $relativePath
        }
    }
}

Write-Host "Found $($orphanedFiles.Count) orphaned files" -ForegroundColor $(if ($orphanedFiles.Count -gt 0) { "Yellow" } else { "Green" })

# Step 4: Generate report
Write-Host "`n=== Generating Report ===" -ForegroundColor Yellow

$reportPath = "$projectRoot\.bot\audit"
if (-not (Test-Path $reportPath)) {
    New-Item -ItemType Directory -Path $reportPath | Out-Null
}

$reportFile = "$reportPath\orphaned-files-report.md"

$report = @"
# Orphaned Files Audit Report

Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

## Summary

- **Total .bot markdown files**: $($allBotFiles.Count)
- **Referenced files**: $($script:referencedFiles.Count)
- **Orphaned files**: $($orphanedFiles.Count)
- **Broken references**: $($script:brokenReferences.Count)

## Referenced Files

These files are properly linked from .warp/workflows entry points:

"@

# Add referenced files
$referencedSorted = $script:referencedFiles.GetEnumerator() | 
    Sort-Object { $_.Value.RelativePath }

foreach ($entry in $referencedSorted) {
    $relPath = $entry.Value.RelativePath
    $refBy = $entry.Value.ReferencedBy
    $report += "`n- ``$relPath``"
    $report += "`n  - Referenced by: ``$refBy``"
}

# Add orphaned files section
$report += "`n`n## Orphaned Files`n`n"

if ($orphanedFiles.Count -eq 0) {
    $report += "✅ **No orphaned files found!** All .bot markdown files are properly referenced.`n"
} else {
    $report += "The following files exist but are NOT referenced in the dependency tree from .warp/workflows:`n`n"
    
    # Group by directory
    $byDirectory = $orphanedFiles | Group-Object { Split-Path $_.RelativePath -Parent }
    
    foreach ($group in $byDirectory) {
        $report += "`n### $($group.Name)`n`n"
        foreach ($file in $group.Group) {
            $fileName = Split-Path $file.RelativePath -Leaf
            $report += "- ``$($file.RelativePath)```n"
        }
    }
}

# Add broken references section
$report += "`n`n## Broken References`n`n"

if ($script:brokenReferences.Count -eq 0) {
    $report += "✅ **No broken references found!** All referenced files exist.`n"
} else {
    $report += "The following files are referenced but do NOT exist:`n`n"
    
    foreach ($broken in $script:brokenReferences) {
        $report += "- ``$($broken.MissingFile)``"
        $report += "`n  - Referenced by: ``$($broken.ReferencedBy)``"
        $report += "`n"
    }
}

# Add recommendations
$report += @"

## Recommendations

### For Orphaned Files

1. **Determine relevance**: Review each orphaned file to see if it should be integrated
2. **Update command files**: Add references in appropriate `.bot/commands/*.md` files
3. **Document unused files**: If intentionally unused, document in `.bot/audit/unused-files.md`

### For Broken References

1. **Fix references**: Update referencing files to point to correct paths
2. **Create missing files**: If files should exist, create them
3. **Remove dead links**: If references are outdated, remove them

### Integration Steps

For each orphaned file:

1. **Agents** (`.bot/agents/*.md`):
   - Identify which commands should use this agent
   - Add to command file's "Agent" section: ``This command uses: .bot/agents/[name].md``

2. **Standards** (`.bot/standards/**/*.md`):
   - Determine applicability (backend/frontend/global/testing)
   - Add to relevant command files' "Standards" section
   - Consider adding to feature JSON applicable_standards arrays

3. **Workflows** (`.bot/workflows/**/*.md`):
   - Identify parent command
   - Add to command file's "Workflow" section: ``This command follows: .bot/workflows/[path].md``

4. **Other files**:
   - Evaluate if they serve a purpose
   - Either integrate or document as intentionally unused

## Next Steps

1. ✅ Review this report
2. ⏭️ Phase 2: Update Feature JSON Schema
3. ⏭️ Phase 3: Update Implement-Feature Command  
4. ⏭️ Phase 4: Update Command Files with Standard References
5. ⏭️ Phase 5: Link Orphaned Files

"@

# Write report
$report | Set-Content $reportFile -Encoding UTF8

Write-Host "`n✅ Report generated: .bot\audit\orphaned-files-report.md" -ForegroundColor Green

# Display summary
Write-Host "`n=== SUMMARY ===" -ForegroundColor Yellow
Write-Host "Referenced files: $($script:referencedFiles.Count)" -ForegroundColor Green
Write-Host "Orphaned files: $($orphanedFiles.Count)" -ForegroundColor $(if ($orphanedFiles.Count -gt 0) { "Yellow" } else { "Green" })
Write-Host "Broken references: $($script:brokenReferences.Count)" -ForegroundColor $(if ($script:brokenReferences.Count -gt 0) { "Red" } else { "Green" })

if ($orphanedFiles.Count -gt 0) {
    Write-Host "`nOrphaned files:" -ForegroundColor Yellow
    $orphanedFiles | Select-Object -First 10 | ForEach-Object {
        Write-Host "  - $($_.RelativePath)" -ForegroundColor Gray
    }
    if ($orphanedFiles.Count -gt 10) {
        Write-Host "  ... and $($orphanedFiles.Count - 10) more (see report)" -ForegroundColor Gray
    }
}

Write-Host "`nView full report at: .bot\audit\orphaned-files-report.md" -ForegroundColor Cyan
