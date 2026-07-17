#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 2: Dotbot.TeamRegistry module + CLI smoke coverage.
.DESCRIPTION
    Exercises the team registry (.bot/team-registry.json):
      - Read on missing file returns an empty envelope
      - Add creates the file with schema_version=1 and one entry
      - Email is required; invalid email is rejected
      - Role is optional; must be one of {developer,lead,reviewer,qa}
      - Add rejects duplicate names case-insensitively
      - Add rejects invalid names
      - Get and List round-trip; get is case-insensitive
      - Schema-version mismatch on read throws
      - Atomic write leaves no .tmp file behind
      - Concurrent adds are serialized under the file-scoped mutex — no lost writes
    Plus a CLI smoke pass parsing each script + verifying the dispatcher wiring.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$repoRoot = Get-RepoRoot

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Team Registry" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

Import-Module (Join-Path $repoRoot "src/runtime/Modules/Dotbot.TeamRegistry/Dotbot.TeamRegistry.psd1") -Force -DisableNameChecking -Global

# Local test scaffolding — same shape as Test-Runtime.ps1's helper.
function New-TestBotRoot {
    $base = Join-Path ([System.IO.Path]::GetTempPath()) ("dotbot-team-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $bot  = Join-Path $base '.bot'
    New-Item -ItemType Directory -Path $bot | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $bot '.control') | Out-Null
    return $bot
}

function Remove-TestBotRoot {
    param([Parameter(Mandatory)][string]$BotRoot)
    $project = Split-Path -Parent $BotRoot
    try { Remove-Item -Recurse -Force $project } catch { $null = $_ }
}

# ═══════════════════════════════════════════════════════════════════════════
# Module: read path (missing / valid / malformed / schema mismatch)
# ═══════════════════════════════════════════════════════════════════════════

Write-Host "  Module: read behavior" -ForegroundColor Cyan
Write-Host "  ──────────────────────────────────────────────────" -ForegroundColor DarkGray

$bot = New-TestBotRoot
try {
    $reg = Read-DotbotTeamRegistry -BotRoot $bot
    Assert-Equal -Name "Missing-file read returns schema_version = 1"      -Expected 1 -Actual $reg.schema_version
    Assert-Equal -Name "Missing-file read returns an empty members array"  -Expected 0 -Actual @($reg.members).Count

    $path = Get-DotbotTeamRegistryPath -BotRoot $bot
    Assert-Equal -Name "Registry path lands directly under .bot/" `
        -Expected (Join-Path $bot 'team-registry.json') `
        -Actual   $path
    Assert-True  -Name "Missing-file read does NOT create the file" -Condition (-not (Test-Path -LiteralPath $path))

    # Malformed JSON should throw
    Set-Content -Path $path -Value '{ not json' -Encoding utf8NoBOM
    $threw = $false
    try { Read-DotbotTeamRegistry -BotRoot $bot } catch { $threw = $true }
    Assert-True -Name "Malformed JSON throws from Read-DotbotTeamRegistry" -Condition $threw

    # Schema-version mismatch should throw
    Set-Content -Path $path -Value '{"schema_version":999,"members":[]}' -Encoding utf8NoBOM
    $threw = $false
    try { Read-DotbotTeamRegistry -BotRoot $bot } catch { $threw = $true }
    Assert-True -Name "Unknown schema_version throws from Read-DotbotTeamRegistry" -Condition $threw
} finally {
    Remove-TestBotRoot -BotRoot $bot
}

# ═══════════════════════════════════════════════════════════════════════════
# Module: add / list / get happy path
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  Module: add / list / get" -ForegroundColor Cyan
Write-Host "  ──────────────────────────────────────────────────" -ForegroundColor DarkGray

$bot = New-TestBotRoot
try {
    $m1 = Add-DotbotTeamMember -BotRoot $bot -Name 'ana-smith' -Email 'ana@example.com' -Role 'developer'
    Assert-Equal -Name "Add returns member with the requested name"                 -Expected 'ana-smith'      -Actual $m1.name
    Assert-Equal -Name "Add returns member with the requested email"                -Expected 'ana@example.com' -Actual $m1.email
    Assert-Equal -Name "Add returns member with the requested role"                 -Expected 'developer'      -Actual $m1.role
    Assert-True  -Name "Add returns id with 'tm_' prefix + 8 chars"                 -Condition ($m1.id -match '^tm_[A-Za-z0-9]{8}$')
    Assert-True  -Name "Add stamps created_at with an RFC3339-Z-ish string"         -Condition ($m1.created_at -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$')
    Assert-Equal -Name "Add stamps created_by = 'cli' by default"                   -Expected 'cli' -Actual $m1.created_by

    $path = Get-DotbotTeamRegistryPath -BotRoot $bot
    Assert-True -Name "Add writes the registry file"       -Condition (Test-Path -LiteralPath $path)
    Assert-True -Name "Atomic write leaves no .tmp behind" -Condition (-not (Test-Path -LiteralPath "$path.tmp"))

    # Second add — different name, appends.
    $m2 = Add-DotbotTeamMember -BotRoot $bot -Name 'ben' -Email 'ben@example.com' -Role 'reviewer'
    $members = Get-DotbotTeamMembers -BotRoot $bot
    Assert-Equal -Name "List after two adds returns two members" -Expected 2 -Actual @($members).Count
    Assert-True  -Name "List preserves insertion order"          -Condition ($members[0].name -eq 'ana-smith' -and $members[1].name -eq 'ben')

    # Get — case-insensitive
    $lookup = Get-DotbotTeamMember -BotRoot $bot -Name 'ANA-SMITH'
    Assert-True  -Name "Get is case-insensitive"                            -Condition ($null -ne $lookup)
    Assert-Equal -Name "Get returns the correct member (case-insensitive)"  -Expected $m1.id -Actual $lookup.id

    Assert-True -Name "Get on missing name returns \$null" -Condition ($null -eq (Get-DotbotTeamMember -BotRoot $bot -Name 'nobody'))

    # Omitted --role → role is $null (not an empty string)
    $m3 = Add-DotbotTeamMember -BotRoot $bot -Name 'no-role-user' -Email 'no-role@example.com'
    Assert-True -Name "Add without --role stores role as null" -Condition ($null -eq $m3.role)
} finally {
    Remove-TestBotRoot -BotRoot $bot
}

# ═══════════════════════════════════════════════════════════════════════════
# Module: email + role validation
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  Module: email + role validation" -ForegroundColor Cyan
Write-Host "  ──────────────────────────────────────────────────" -ForegroundColor DarkGray

$bot = New-TestBotRoot
try {
    # Missing email → PowerShell parameter binding rejects with a clear error
    $threw = $false
    try { Add-DotbotTeamMember -BotRoot $bot -Name 'ana' } catch { $threw = $true }
    Assert-True -Name "Add without -Email throws (parameter is mandatory)" -Condition $threw

    # Malformed email — module-level validation
    foreach ($bad in @('no-at-sign', 'foo@', '@bar', 'foo bar@baz.com')) {
        $threw = $false
        try { Add-DotbotTeamMember -BotRoot $bot -Name "user-$([guid]::NewGuid().ToString('N').Substring(0,4))" -Email $bad } catch { $threw = $true }
        Assert-True -Name "Malformed email is rejected: '$bad'" -Condition $threw
    }

    # Each valid role accepted
    $validRoles = @('developer','lead','reviewer','qa')
    for ($i = 0; $i -lt $validRoles.Count; $i++) {
        $r = $validRoles[$i]
        $m = Add-DotbotTeamMember -BotRoot $bot -Name "role-user-$i" -Email "role$i@example.com" -Role $r
        Assert-Equal -Name "Role '$r' is accepted" -Expected $r -Actual $m.role
    }

    # Invalid roles rejected
    foreach ($bad in @('devops', 'admin', 'Developer', 'developer ', '')) {
        if ([string]::IsNullOrWhiteSpace($bad)) { continue }   # empty role is treated as "not set"; covered above
        $threw = $false; $err = ''
        try { Add-DotbotTeamMember -BotRoot $bot -Name "bad-$([guid]::NewGuid().ToString('N').Substring(0,4))" -Email 'x@example.com' -Role $bad } catch { $threw = $true; $err = $_.Exception.Message }
        Assert-True -Name "Invalid role rejected: '$bad'"                    -Condition $threw
        Assert-True -Name "Invalid-role error names the allowed roles: '$bad'" -Condition ($err -match 'developer' -and $err -match 'qa')
    }
} finally {
    Remove-TestBotRoot -BotRoot $bot
}

# ═══════════════════════════════════════════════════════════════════════════
# Module: rejection cases (duplicates + malformed inputs)
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  Module: rejection cases" -ForegroundColor Cyan
Write-Host "  ──────────────────────────────────────────────────" -ForegroundColor DarkGray

$bot = New-TestBotRoot
try {
    Add-DotbotTeamMember -BotRoot $bot -Name 'ana' -Email 'ana@example.com' -Role 'developer' | Out-Null

    # Exact-case duplicate
    $threw = $false; $err = ''
    try { Add-DotbotTeamMember -BotRoot $bot -Name 'ana' -Email 'other@example.com' } catch { $threw = $true; $err = $_.Exception.Message }
    Assert-True -Name "Duplicate name (same case) throws"                              -Condition $threw
    Assert-True -Name "Duplicate error mentions the offending name"                    -Condition ($err -match 'ana')

    # Case-insensitive duplicate
    $threw = $false
    try { Add-DotbotTeamMember -BotRoot $bot -Name 'ANA' -Email 'other@example.com' } catch { $threw = $true }
    Assert-True -Name "Duplicate name (different case) throws"                         -Condition $threw

    # Invalid name — starts with dash
    $threw = $false
    try { Add-DotbotTeamMember -BotRoot $bot -Name '-invalid' -Email 'x@example.com' } catch { $threw = $true }
    Assert-True -Name "Name starting with '-' is rejected"                             -Condition $threw

    # Invalid name — spaces
    $threw = $false
    try { Add-DotbotTeamMember -BotRoot $bot -Name 'has space' -Email 'x@example.com' } catch { $threw = $true }
    Assert-True -Name "Name containing spaces is rejected"                             -Condition $threw

    # Assert-DotbotTeamMember on incomplete input
    $threw = $false
    try {
        Assert-DotbotTeamMember -Member @{ name = 'x' }  # missing id, email, created_at, created_by
    } catch { $threw = $true }
    Assert-True -Name "Assert-DotbotTeamMember rejects a member missing required fields" -Condition $threw
} finally {
    Remove-TestBotRoot -BotRoot $bot
}

# ═══════════════════════════════════════════════════════════════════════════
# Module: concurrent-add serialization (file lock exists and works)
# ═══════════════════════════════════════════════════════════════════════════
# Reviewer feedback on #630: atomic temp-file rename prevents corruption but
# not lost updates. Two concurrent `dotbot team add` calls can both read the
# registry, both append their entry, and one silently overwrites the other.
# `Add-DotbotTeamMember` now serializes read-modify-write under a named
# Mutex. This test spawns two add jobs racing on the same bot root and
# asserts both entries survive.

Write-Host ""
Write-Host "  Module: concurrent adds don't lose writes" -ForegroundColor Cyan
Write-Host "  ──────────────────────────────────────────────────" -ForegroundColor DarkGray

$bot = New-TestBotRoot
try {
    # Repeat a few times because a race that never fires under lock could
    # look like a passing test on a slow machine. 5 rounds keeps the test
    # under ~2 seconds while catching a broken lock reliably.
    $rounds       = 5
    $observedBoth = 0
    for ($r = 0; $r -lt $rounds; $r++) {
        # Wipe the registry between rounds so each round starts empty.
        $regPath = Get-DotbotTeamRegistryPath -BotRoot $bot
        if (Test-Path -LiteralPath $regPath) { Remove-Item -LiteralPath $regPath -Force }

        $repo = $repoRoot
        $b    = $bot
        $suffix = "$r"
        $job1 = Start-ThreadJob -ScriptBlock {
            param($repo, $bot, $suffix)
            Import-Module (Join-Path $repo 'src/runtime/Modules/Dotbot.TeamRegistry/Dotbot.TeamRegistry.psd1') -Force -DisableNameChecking
            Add-DotbotTeamMember -BotRoot $bot -Name "racer-a-$suffix" -Email "a-$suffix@example.com" -Role 'developer' | Out-Null
        } -ArgumentList $repo, $b, $suffix
        $job2 = Start-ThreadJob -ScriptBlock {
            param($repo, $bot, $suffix)
            Import-Module (Join-Path $repo 'src/runtime/Modules/Dotbot.TeamRegistry/Dotbot.TeamRegistry.psd1') -Force -DisableNameChecking
            Add-DotbotTeamMember -BotRoot $bot -Name "racer-b-$suffix" -Email "b-$suffix@example.com" -Role 'reviewer' | Out-Null
        } -ArgumentList $repo, $b, $suffix

        Wait-Job -Job @($job1, $job2) -Timeout 15 | Out-Null
        Receive-Job -Job $job1 -ErrorAction SilentlyContinue | Out-Null
        Receive-Job -Job $job2 -ErrorAction SilentlyContinue | Out-Null
        Remove-Job  -Job @($job1, $job2) -Force -ErrorAction SilentlyContinue

        $members = Get-DotbotTeamMembers -BotRoot $bot
        $names   = @($members | ForEach-Object { [string]$_.name })
        if ($names -contains "racer-a-$suffix" -and $names -contains "racer-b-$suffix") {
            $observedBoth++
        }
    }
    Assert-Equal -Name "Both racers persist across all rounds (no lost write under file lock)" `
        -Expected $rounds -Actual $observedBoth
} finally {
    Remove-TestBotRoot -BotRoot $bot
}

# ═══════════════════════════════════════════════════════════════════════════
# CLI smoke: syntax check + dispatch (parses each script, no execution)
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  CLI: script parses + declares expected params" -ForegroundColor Cyan
Write-Host "  ──────────────────────────────────────────────────" -ForegroundColor DarkGray

$cliDir  = Join-Path $repoRoot 'src/cli'
$scripts = @('team-add.ps1', 'team-list.ps1', 'team-get.ps1')

foreach ($s in $scripts) {
    $path = Join-Path $cliDir $s
    Assert-True -Name "CLI script exists: $s" -Condition (Test-Path -LiteralPath $path)

    # Parse the script — Layer 1 handles broader syntax, but for these
    # specific files we want a fast, in-suite check.
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    Assert-Equal -Name "CLI script parses without errors: $s" -Expected 0 -Actual @($errors).Count
}

# Verify the dispatcher branch in bin/dotbot.ps1 references the team scripts.
$dispatcher = Get-Content -LiteralPath (Join-Path $repoRoot 'bin/dotbot.ps1') -Raw
Assert-True -Name "Dispatcher registers 'team' command" -Condition ($dispatcher -match '"team"\s*\{\s*Invoke-Team\s*\}')
Assert-True -Name "Dispatcher defines Invoke-Team"      -Condition ($dispatcher -match 'function\s+Invoke-Team')

Write-TestSummary -LayerName "TeamRegistry"

if ((Get-TestResults).Failed -gt 0) { exit 1 } else { exit 0 }
