# ═══════════════════════════════════════════════════════════════
# FRAMEWORK FILE — DO NOT MODIFY IN TARGET PROJECTS
# Managed by dotbot. Overwritten on 'dotbot init --force'.
# ═══════════════════════════════════════════════════════════════
param(
    [string]$TaskId,
    [string]$Category,
    [switch]$StagedOnly
)

# Scan repo for sensitive data before commit
$issues = @()
$details = @{
    files_scanned = 0
    violations = @()
}

# Patterns to detect
$patterns = @(
    # Local paths (Windows/macOS/Linux)
    @{ name = "windows_user_path"; pattern = '[A-Za-z]:[/\\]+Users[/\\]+\w+'; description = "Windows user path"; caseSensitive = $false }
    @{ name = "linux_home_path"; pattern = '/home/\w+'; description = "Linux home path"; caseSensitive = $true }
    @{ name = "macos_user_path"; pattern = '/Users/\w+'; description = "macOS user path"; caseSensitive = $true }

    # Secrets and credentials
    @{ name = "api_key_value"; pattern = '(?:api[_-]?key|apikey)\s*[=:]\s*["\u0027]?[A-Za-z0-9_\-]{20,}'; description = "API key value"; caseSensitive = $false }
    @{ name = "secret_value"; pattern = '(?:secret|password|passwd|pwd)\s*[=:]\s*["\u0027]?[^\s"]{8,}'; description = "Secret/password value"; caseSensitive = $false }
    @{ name = "bearer_token"; pattern = 'Bearer\s+[A-Za-z0-9_\-\.]{20,}'; description = "Bearer token"; caseSensitive = $false }
    @{ name = "connection_string"; pattern = '(?:Server|Data Source|mongodb\+srv|postgresql|mysql)://[^\s"]+'; description = "Connection string"; caseSensitive = $false }
    @{ name = "private_key"; pattern = '-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----'; description = "Private key"; caseSensitive = $true }
    @{ name = "connection_string_password"; pattern = '(?:Password|Pwd)\s*=\s*[^\s;]{4,}'; description = "Connection string with password"; caseSensitive = $false }

    # Cloud credentials
    @{ name = "aws_key"; pattern = 'AKIA[0-9A-Z]{16}'; description = "AWS access key"; caseSensitive = $true }
    @{ name = "azure_key"; pattern = '(?:AccountKey|SharedAccessSignature)\s*=\s*[A-Za-z0-9+/=]{40,}'; description = "Azure key"; caseSensitive = $false }
)

# Files/paths to exclude from scanning
$excludePatterns = @(
    '\.git[/\\]',
    'node_modules[/\\]',
    '\.vs[/\\]',
    'bin[/\\]',
    'obj[/\\]',
    '\.bot[/\\]\.control[/\\]',
    '\.bot[/\\]hooks[/\\]',
    '\.bot[/\\]systems[/\\]',
    '\.bot[/\\]defaults[/\\]',
    '\.bot[/\\]prompts[/\\]',
    '\.bot[/\\]workspace[/\\]tasks[/\\]',
    '\.bot[/\\]workspace[/\\]decisions[/\\]'
)

# Canonical placeholder values that signal documented examples rather than
# real secrets. Skipped at the line level so a doc or fixture can use
# `Password=hunter2;` without tripping the secret patterns.
$placeholderTokens = @(
    'hunter2',
    '<example>',
    '<placeholder>',
    'REPLACE_ME',
    '<your-password>'
)

# Binary extensions to skip
$binaryExtensions = @('.exe','.dll','.pdb','.zip','.tar','.gz','.7z','.rar',
    '.png','.jpg','.jpeg','.gif','.bmp','.ico','.svg','.webp',
    '.mp3','.mp4','.wav','.avi','.mov',
    '.woff','.woff2','.ttf','.eot',
    '.pdf','.doc','.docx','.xls','.xlsx',
    '.pyc','.class','.o','.so','.dylib','.nupkg','.snupkg')

# Max file size to scan (skip large files)
$maxFileSize = 1MB

$repoRoot = git rev-parse --show-toplevel 2>$null
if (-not $repoRoot) {
    $repoRoot = Get-Location
}

if ($StagedOnly) {
    # Pre-commit mode: only scan files being committed
    $allFiles = @(git -C $repoRoot diff --cached --name-only --diff-filter=ACM 2>$null) | Where-Object { $_ }
} else {
    # Verify-hook mode (e.g. task_mark_done): scope to files the active task
    # touched across its full branch history plus untracked working-tree files.
    # Using HEAD~1..HEAD alone misses earlier commits on a multi-commit task
    # branch.
    $diffFiles = @()
    $baseRef = $null

    $originHead = & git -C $repoRoot symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $originHead) {
        $baseRef = $originHead.Trim()
    } else {
        foreach ($candidate in @('origin/main', 'origin/master', 'main', 'master')) {
            $null = & git -C $repoRoot rev-parse --verify $candidate 2>$null
            if ($LASTEXITCODE -eq 0) {
                $baseRef = $candidate
                break
            }
        }
    }

    $mergeBase = $null
    if ($baseRef) {
        $mb = & git -C $repoRoot merge-base $baseRef HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $mb) {
            $mergeBase = $mb.Trim()
        }
    }

    # If HEAD is on the base branch itself (no remote, single-branch repo, or
    # PR scenario where the task branch was already fast-forwarded), the
    # merge-base equals HEAD and `mergeBase..HEAD` would be empty. Fall back
    # so verify-hook always scans something.
    $headSha = $null
    $h = & git -C $repoRoot rev-parse HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $h) { $headSha = $h.Trim() }

    if ($mergeBase -and $headSha -and $mergeBase -ne $headSha) {
        $diffFiles = @(git -C $repoRoot diff --name-only "$mergeBase..HEAD" --diff-filter=ACM 2>$null)
    } else {
        $null = git -C $repoRoot rev-parse --verify HEAD~1 2>$null
        if ($LASTEXITCODE -eq 0) {
            $diffFiles = @(git -C $repoRoot diff --name-only HEAD~1..HEAD --diff-filter=ACM 2>$null)
        } else {
            # No parent commit yet: fall back to the full tracked set so the
            # very first commit still gets scanned end-to-end.
            $diffFiles = @(git -C $repoRoot ls-files 2>$null)
        }
    }

    $untrackedFiles = @(git -C $repoRoot ls-files --others --exclude-standard 2>$null)
    $allFiles = @($diffFiles) + @($untrackedFiles) | Where-Object { $_ } | Sort-Object -Unique
}

foreach ($relativePath in $allFiles) {
    $fullPath = Join-Path $repoRoot $relativePath

    # Skip excluded paths
    $skip = $false
    foreach ($exclude in $excludePatterns) {
        if ($relativePath -match $exclude) {
            $skip = $true
            break
        }
    }
    if ($skip) { continue }

    # Skip binary extensions
    $ext = [System.IO.Path]::GetExtension($relativePath).ToLowerInvariant()
    if ($ext -and $ext -in $binaryExtensions) { continue }

    # Skip files that don't exist or exceed size limit
    if (-not (Test-Path $fullPath)) { continue }
    $fileInfo = Get-Item $fullPath -ErrorAction SilentlyContinue
    if (-not $fileInfo -or $fileInfo.Length -gt $maxFileSize) { continue }

    $details['files_scanned']++
    $content = Get-Content $fullPath -Raw -ErrorAction SilentlyContinue
    if (-not $content) { continue }

    $lineNumber = 0
    $lines = $content -split "`n"

    # Per-file accumulator keyed by line number so multiple patterns on the
    # same line collapse to one violation with a list of pattern names.
    # Hashtable enumeration order is not guaranteed; emit entries in
    # ascending line-number order at the end of the file scan so violations
    # follow the file → line traversal order.
    $perLine = @{}
    $prevLineHadMarker = $false

    foreach ($line in $lines) {
        $lineNumber++

        # Recognise the existing `noscan` marker plus the documented spelling
        # `privacy-scan: example` (either `#` or `//` comment). The marker may
        # sit on the same line or the line above the matched pattern.
        $thisLineHasMarker = ($line -match '(?://|#)\s*(?:noscan|privacy-scan\s*:\s*example)')
        if ($thisLineHasMarker -or $prevLineHadMarker) {
            $prevLineHadMarker = $thisLineHasMarker
            continue
        }
        $prevLineHadMarker = $thisLineHasMarker

        foreach ($patternDef in $patterns) {
            $matched = if ($patternDef.caseSensitive) {
                $line -cmatch $patternDef.pattern
            } else {
                $line -match $patternDef.pattern
            }
            if (-not $matched) { continue }

            # Treat the match as a documented example only when the matched
            # substring itself contains a canonical placeholder. Checking the
            # whole line was unsafe — a real secret on the same line as an
            # unrelated `<example>` would have been silently exempted.
            $matchText = "$($Matches[0])"
            $isPlaceholder = $false
            foreach ($token in $placeholderTokens) {
                if ($matchText.IndexOf($token, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $isPlaceholder = $true
                    break
                }
            }
            if ($isPlaceholder) { continue }

            if (-not $perLine.ContainsKey($lineNumber)) {
                $perLine[$lineNumber] = @{
                    file         = $relativePath
                    line         = $lineNumber
                    patterns     = @($patternDef.name)
                    descriptions = @($patternDef.description)
                    description  = $patternDef.description
                    snippet      = if ($line.Length -gt 100) { $line.Substring(0, 100) + "..." } else { $line.Trim() }
                }
            } else {
                $entry = $perLine[$lineNumber]
                if ($entry.patterns -notcontains $patternDef.name) {
                    $entry.patterns     += $patternDef.name
                    $entry.descriptions += $patternDef.description
                    $entry.description   = $entry.descriptions -join ', '
                }
            }
        }
    }

    foreach ($key in ($perLine.Keys | Sort-Object)) {
        $entry = $perLine[$key]
        $details['violations'] += $entry
        $patternList = $entry.patterns -join ', '
        $descList    = $entry.descriptions -join ', '
        $issues += @{
            issue    = "$descList in $($entry.file):$($entry.line)"
            severity = "error"
            context  = "Remove or redact sensitive data, or mark the line with `# privacy-scan: example` if it is a documented placeholder. Patterns: $patternList"
        }
    }
}

# Each line is already aggregated; preserve original (file → line) traversal
# order while dropping any accidental cross-file duplicates from upstream
# callers. Sort-Object -Unique would reorder lexicographically, which makes
# the report harder to read in long verify-hook scans.
$seenIssueKeys = @{}
$uniqueIssues = @(foreach ($entry in $issues) {
    $key = "$($entry.issue)"
    if (-not $seenIssueKeys.ContainsKey($key)) {
        $seenIssueKeys[$key] = $true
        $entry
    }
})

$details['scan_mode'] = if ($StagedOnly) { 'staged' } else { 'verify-hook' }

if ($StagedOnly -and $uniqueIssues.Count -gt 0) {
    [Console]::Error.WriteLine("")
    [Console]::Error.WriteLine("dotbot privacy scan: $($uniqueIssues.Count) violation(s) in staged files:")
    foreach ($v in $details['violations']) {
        [Console]::Error.WriteLine("  $($v.file):$($v.line) - $($v.description)")
    }
    [Console]::Error.WriteLine("")
    [Console]::Error.WriteLine("Remove or redact sensitive data before committing.")
}

@{
    success = ($uniqueIssues.Count -eq 0)
    script = "00-privacy-scan.ps1"
    message = if ($uniqueIssues.Count -eq 0) { "No sensitive data detected" } else { "$($uniqueIssues.Count) privacy violation(s) found" }
    details = $details
    failures = @($uniqueIssues)
} | ConvertTo-Json -Depth 10
