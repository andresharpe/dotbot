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
    '\.bot[/\\]prompts[/\\]'
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
    # Full repo scan
    $trackedFiles = git -C $repoRoot ls-files 2>$null
    $untrackedFiles = git -C $repoRoot ls-files --others --exclude-standard 2>$null
    $allFiles = @($trackedFiles) + @($untrackedFiles) | Where-Object { $_ } | Sort-Object -Unique
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

    foreach ($line in $lines) {
        $lineNumber++

        foreach ($patternDef in $patterns) {
            # Check if pattern matches (case-sensitive or case-insensitive)
            $matches = if ($patternDef.caseSensitive) {
                $line -cmatch $patternDef.pattern
            } else {
                $line -match $patternDef.pattern
            }

            if ($matches -and $line -notmatch '(?://|#)\s*noscan') {
                $violation = @{
                    file = $relativePath
                    line = $lineNumber
                    pattern = $patternDef.name
                    description = $patternDef.description
                    snippet = if ($line.Length -gt 100) { $line.Substring(0, 100) + "..." } else { $line.Trim() }
                }
                $details['violations'] += $violation

                $issues += @{
                    issue = "$($patternDef.description) in $relativePath`:$lineNumber"
                    severity = "error"
                    context = "Remove or redact sensitive data before committing"
                }
            }
        }
    }
}

# Deduplicate issues (same file/line can match multiple patterns)
$uniqueIssues = $issues | Sort-Object { "$($_.issue)" } -Unique

$details['scan_mode'] = if ($StagedOnly) { 'staged' } else { 'full' }

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
