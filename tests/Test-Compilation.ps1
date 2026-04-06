#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 1b: Compilation and module validation tests for dotbot.
.DESCRIPTION
    Validates all .ps1 and .psm1 files in the source tree:
    1. Syntax parsing via AST parser (handles 'using namespace' correctly)
    2. Module export alignment (exported names match defined functions)
    3. Static import path resolution ($PSScriptRoot-relative paths exist on disk)
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$repoRoot = Get-RepoRoot

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Layer 1b: Compilation & Module Validation" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

# ─── Local Helper Functions ────────────────────────────────────────────

function Test-AstParse {
    <#
    .SYNOPSIS
        Parse a PowerShell file using the AST parser. Returns AST and errors.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$tokens,
        [ref]$parseErrors
    )

    return @{
        Ast    = $ast
        Errors = $parseErrors
    }
}

function Get-ExportedFunctionNames {
    <#
    .SYNOPSIS
        Extract function names from Export-ModuleMember -Function calls in file content.
        Handles array-literal @(...), comma-separated bare names, and inline single-line arrays.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Content
    )

    $names = [System.Collections.ArrayList]::new()

    # Pattern 1: Export-ModuleMember -Function @( ... ) — multi-line or single-line array
    # Capture everything between @( and the matching )
    $arrayPattern = '(?s)Export-ModuleMember\s+.*?-Function\s+@\(([^)]+)\)'
    $arrayMatches = [regex]::Matches($Content, $arrayPattern)
    foreach ($m in $arrayMatches) {
        $inner = $m.Groups[1].Value
        # Extract quoted strings
        $quotedMatches = [regex]::Matches($inner, "'([^']+)'")
        foreach ($q in $quotedMatches) {
            [void]$names.Add($q.Groups[1].Value)
        }
        # Also handle double-quoted strings
        $dqMatches = [regex]::Matches($inner, '"([^"]+)"')
        foreach ($q in $dqMatches) {
            [void]$names.Add($q.Groups[1].Value)
        }
    }

    # Pattern 2: Export-ModuleMember -Function Name1, Name2, ... (bare comma-separated, no @())
    # Only match if NOT followed by @( (already handled above)
    $barePattern = 'Export-ModuleMember\s+.*?-Function\s+(?!@\()([A-Za-z][\w-]+(?:\s*,\s*[A-Za-z][\w-]+)*)'
    $bareMatches = [regex]::Matches($Content, $barePattern)
    foreach ($m in $bareMatches) {
        $bareList = $m.Groups[1].Value
        $parts = $bareList -split '\s*,\s*'
        foreach ($p in $parts) {
            $trimmed = $p.Trim()
            if ($trimmed -and $trimmed -notin $names) {
                [void]$names.Add($trimmed)
            }
        }
    }

    return $names
}

function Get-DefinedFunctionNames {
    <#
    .SYNOPSIS
        Extract function names from AST FunctionDefinitionAst nodes.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.ScriptBlockAst]$Ast
    )

    $funcs = $Ast.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },
        $true
    )

    return @($funcs | ForEach-Object { $_.Name })
}

function Get-StaticImportPaths {
    <#
    .SYNOPSIS
        Extract static import/dot-source paths that use $PSScriptRoot.
        Returns objects with Pattern, RawPath, and ResolvedPath.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Content,
        [Parameter(Mandatory)]
        [string]$FileDir
    )

    $results = [System.Collections.ArrayList]::new()

    # Pattern 1: Import-Module "$PSScriptRoot\..." or Import-Module "$PSScriptRoot/..."
    $importStringPattern = 'Import-Module\s+"(\$PSScriptRoot[\\/][^"]+)"'
    foreach ($m in [regex]::Matches($Content, $importStringPattern)) {
        $raw = $m.Groups[1].Value
        $resolved = $raw -replace '\$PSScriptRoot', $FileDir
        [void]$results.Add(@{ Type = 'Import-Module'; RawPath = $raw; ResolvedPath = $resolved })
    }

    # Pattern 2: Import-Module (Join-Path $PSScriptRoot "...")
    $importJoinPattern = 'Import-Module\s+\(Join-Path\s+\$PSScriptRoot\s+"([^"]+)"\)'
    foreach ($m in [regex]::Matches($Content, $importJoinPattern)) {
        $relative = $m.Groups[1].Value
        $resolved = Join-Path $FileDir $relative
        [void]$results.Add(@{ Type = 'Import-Module (Join-Path)'; RawPath = "`$PSScriptRoot\$relative"; ResolvedPath = $resolved })
    }

    # Pattern 3: . "$PSScriptRoot\..." or . "$PSScriptRoot/..."
    $dotSourcePattern = '\.\s+"(\$PSScriptRoot[\\/][^"]+)"'
    foreach ($m in [regex]::Matches($Content, $dotSourcePattern)) {
        $raw = $m.Groups[1].Value
        $resolved = $raw -replace '\$PSScriptRoot', $FileDir
        [void]$results.Add(@{ Type = 'Dot-source'; RawPath = $raw; ResolvedPath = $resolved })
    }

    # Pattern 4: . (Join-Path $PSScriptRoot "...")
    $dotJoinPattern = '\.\s+\(Join-Path\s+\$PSScriptRoot\s+[''"]([^''"]+)[''"]\)'
    foreach ($m in [regex]::Matches($Content, $dotJoinPattern)) {
        $relative = $m.Groups[1].Value
        $resolved = Join-Path $FileDir $relative
        [void]$results.Add(@{ Type = 'Dot-source (Join-Path)'; RawPath = "`$PSScriptRoot\$relative"; ResolvedPath = $resolved })
    }

    return $results
}

# ─── Directories to Scan ───────────────────────────────────────────────

$scanDirs = @(
    @{ Name = "profiles/default"; Path = Join-Path $repoRoot "workflows\default" }
    @{ Name = "stacks/dotnet";  Path = Join-Path $repoRoot "stacks\dotnet" }
    @{ Name = "workflows/kickstart-via-jira"; Path = Join-Path $repoRoot "workflows\kickstart-via-jira" }
    @{ Name = "workflows/kickstart-via-pr"; Path = Join-Path $repoRoot "workflows\kickstart-via-pr" }
    @{ Name = "scripts";          Path = Join-Path $repoRoot "scripts" }
    @{ Name = "studio-ui";        Path = Join-Path $repoRoot "studio-ui" }
)

foreach ($dir in $scanDirs) {
    if (-not (Test-Path $dir.Path)) {
        Write-Host "  Skipping $($dir.Name) (not found)" -ForegroundColor Yellow
        continue
    }

    $ps1Files  = @(Get-ChildItem -Path $dir.Path -Filter "*.ps1"  -Recurse -ErrorAction SilentlyContinue)
    $psm1Files = @(Get-ChildItem -Path $dir.Path -Filter "*.psm1" -Recurse -ErrorAction SilentlyContinue)
    $allFiles  = @($ps1Files) + @($psm1Files)

    if ($allFiles.Count -eq 0) { continue }

    # ═══════════════════════════════════════════════════════════════════
    # SYNTAX PARSING
    # ═══════════════════════════════════════════════════════════════════

    Write-Host "  SYNTAX: $($dir.Name) ($($allFiles.Count) files)" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    foreach ($file in $allFiles) {
        $relPath = $file.FullName.Substring($repoRoot.Length + 1)
        $result = Test-AstParse -Path $file.FullName

        if ($result.Errors.Count -eq 0) {
            Write-TestResult -Name "Syntax: $relPath" -Status Pass
        } else {
            $firstError = $result.Errors[0]
            $line = $firstError.Extent.StartLineNumber
            $msg = "$($firstError.Message) (line $line)"
            Write-TestResult -Name "Syntax: $relPath" -Status Fail -Message $msg
        }
    }

    Write-Host ""

    # ═══════════════════════════════════════════════════════════════════
    # MODULE EXPORT ALIGNMENT
    # ═══════════════════════════════════════════════════════════════════

    if ($psm1Files.Count -gt 0) {
        Write-Host "  EXPORTS: $($dir.Name) ($($psm1Files.Count) modules)" -ForegroundColor Cyan
        Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

        foreach ($module in $psm1Files) {
            $relPath = $module.FullName.Substring($repoRoot.Length + 1)
            $content = Get-Content $module.FullName -Raw

            # Skip modules without Export-ModuleMember
            if ($content -notmatch 'Export-ModuleMember') {
                Write-TestResult -Name "Exports: $relPath" -Status Skip -Message "No Export-ModuleMember found"
                continue
            }

            $exportedNames = Get-ExportedFunctionNames -Content $content

            if ($exportedNames.Count -eq 0) {
                # Has Export-ModuleMember but no -Function names (e.g. only -Variable)
                Write-TestResult -Name "Exports: $relPath" -Status Skip -Message "No function exports to check"
                continue
            }

            # Parse AST to get defined functions
            $parseResult = Test-AstParse -Path $module.FullName
            if ($parseResult.Errors.Count -gt 0) {
                # Already reported as syntax error above — skip export check
                continue
            }

            $definedNames = Get-DefinedFunctionNames -Ast $parseResult.Ast
            $missingDefs = @()
            foreach ($exported in $exportedNames) {
                if ($exported -notin $definedNames) {
                    $missingDefs += $exported
                }
            }

            if ($missingDefs.Count -eq 0) {
                Write-TestResult -Name "Exports: $relPath ($($exportedNames.Count) functions)" -Status Pass
            } else {
                $msg = "Exported but not defined: $($missingDefs -join ', ')"
                Write-TestResult -Name "Exports: $relPath" -Status Fail -Message $msg
            }
        }

        Write-Host ""
    }

    # ═══════════════════════════════════════════════════════════════════
    # STATIC IMPORT PATH RESOLUTION
    # ═══════════════════════════════════════════════════════════════════

    Write-Host "  IMPORTS: $($dir.Name)" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    $importFilesChecked = 0
    foreach ($file in $allFiles) {
        $relPath = $file.FullName.Substring($repoRoot.Length + 1)
        $content = Get-Content $file.FullName -Raw
        $fileDir = Split-Path $file.FullName -Parent

        # Check for dynamic imports using variables other than $PSScriptRoot
        $hasDynamicImports = $content -match 'Import-Module\s+.*\$(?!PSScriptRoot)' -or
                             $content -match '\.\s+"?\$(?!PSScriptRoot)'

        # Get static import paths
        $imports = Get-StaticImportPaths -Content $content -FileDir $fileDir

        if ($imports.Count -eq 0 -and -not $hasDynamicImports) { continue }

        $importFilesChecked++

        foreach ($imp in $imports) {
            # Normalize the resolved path
            $resolved = $null
            try {
                $resolved = [System.IO.Path]::GetFullPath($imp.ResolvedPath)
            } catch {
                $resolved = $imp.ResolvedPath
            }

            if (Test-Path $resolved) {
                Write-TestResult -Name "Import: $relPath -> $($imp.RawPath)" -Status Pass
            } else {
                Write-TestResult -Name "Import: $relPath -> $($imp.RawPath)" -Status Fail `
                    -Message "Target not found: $resolved"
            }
        }

        # Check for external module imports (bare names without path separators)
        $externalPattern = 'Import-Module\s+(?:(?:-Name\s+)?)([\w-]+)(?:\s+-)'
        foreach ($m in [regex]::Matches($content, $externalPattern)) {
            $moduleName = $m.Groups[1].Value
            # Skip if it looks like a parameter name or common keywords
            if ($moduleName -in @('Force', 'ErrorAction', 'WarningAction', 'DisableNameChecking', 'PassThru')) { continue }
            # Skip if the line also has a path (already handled above)
            if ($m.Value -match '[\\/]') { continue }

            $available = Get-Module -ListAvailable $moduleName -ErrorAction SilentlyContinue
            if ($available) {
                Write-TestResult -Name "Import: $relPath -> $moduleName (external)" -Status Pass
            } else {
                Write-TestResult -Name "Import: $relPath -> $moduleName (external)" -Status Skip `
                    -Message "External module not installed"
            }
        }
    }

    if ($importFilesChecked -eq 0) {
        Write-TestResult -Name "Imports: $($dir.Name)" -Status Skip -Message "No static imports found"
    }

    Write-Host ""
}

# ═══════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════

$allPassed = Write-TestSummary -LayerName "Layer 1b: Compilation"

if (-not $allPassed) {
    exit 1
}
