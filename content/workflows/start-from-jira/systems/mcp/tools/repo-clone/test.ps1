# Test repo-clone tool helpers (Jira-key extraction + clone-completeness guard).
# The clone itself needs live ADO credentials, so it is not exercised here; these
# tests cover the pure parsing and the local git-state guard.

Import-Module $env:DOTBOT_TEST_HELPERS -Force
. "$PSScriptRoot\script.ps1"

Reset-TestResults

# --- Get-RepoCloneJiraKey -----------------------------------------------------

$canonical = @"
# Jira Context: Some Initiative

## Metadata

| Field | Value |
|-------|-------|
| Jira Key | CP-94926 |
| Summary | Do the thing |
"@
Assert-Equal -Name "jira-key: canonical row" -Expected "CP-94926" `
    -Actual (Get-RepoCloneJiraKey -Content $canonical)

$variant = @"
# Jira Context: ENHANCE Programme

| Field | Value |
|-------|-------|
| Primary Jira Keys | CP-94926, CP-94927, CP-94928 (stories in scope) |
| Parent Epic       | CP-94925 -- ENHANCE-9851 |
"@
Assert-Equal -Name "jira-key: Primary Jira Keys variant (first key)" -Expected "CP-94926" `
    -Actual (Get-RepoCloneJiraKey -Content $variant)

$parentOnly = @"
| Field | Value |
|-------|-------|
| Parent Epic | CP-94925 -- desc |
"@
Assert-Equal -Name "jira-key: Parent Epic variant" -Expected "CP-94925" `
    -Actual (Get-RepoCloneJiraKey -Content $parentOnly)

$h1Only = "# Jira Context: ENHANCE-9851 -- big programme`n`nNo metadata table here."
Assert-Equal -Name "jira-key: H1 title fallback" -Expected "ENHANCE-9851" `
    -Actual (Get-RepoCloneJiraKey -Content $h1Only)

Assert-True -Name "jira-key: null when no key present" `
    -Condition ($null -eq (Get-RepoCloneJiraKey -Content "# Title`n`nNothing key-shaped here.")) `
    -Message "Expected null for content with no key"

Assert-True -Name "jira-key: null for empty content" `
    -Condition ($null -eq (Get-RepoCloneJiraKey -Content "")) `
    -Message "Expected null for empty content"

# Case-sensitive: lower-case key-shaped tokens must NOT be treated as keys,
# otherwise tokens like `utf-8` / `sha-1` (or a stray lower-case key) would
# silently produce a wrong branch name.
Assert-True -Name "jira-key: lowercase key not matched (case-sensitive)" `
    -Condition ($null -eq (Get-RepoCloneJiraKey -Content "| Jira Key | cp-94926 |")) `
    -Message "Expected null for lowercase key"

Assert-True -Name "jira-key: 'utf-8'-style token not matched" `
    -Condition ($null -eq (Get-RepoCloneJiraKey -Content "Encoded as utf-8 with sha-1 digest.")) `
    -Message "Expected null for non-key hyphenated tokens"

# --- Test-RepoCloneComplete ---------------------------------------------------

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-test-repo-clone-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
New-Item -Path $testRoot -ItemType Directory -Force | Out-Null

try {
    $missing = Join-Path $testRoot "missing"
    Assert-True -Name "clone-complete: false for non-existent path" `
        -Condition (-not (Test-RepoCloneComplete -ClonePath $missing)) `
        -Message "Expected false"

    $emptyDir = Join-Path $testRoot "empty"
    New-Item -Path $emptyDir -ItemType Directory -Force | Out-Null
    Assert-True -Name "clone-complete: false for empty dir (no .git)" `
        -Condition (-not (Test-RepoCloneComplete -ClonePath $emptyDir)) `
        -Message "Expected false"

    $noRemote = Join-Path $testRoot "noremote"
    New-Item -Path $noRemote -ItemType Directory -Force | Out-Null
    & git -C $noRemote init --quiet 2>&1 | Out-Null
    Assert-True -Name "clone-complete: false for git repo with no origin remote" `
        -Condition (-not (Test-RepoCloneComplete -ClonePath $noRemote)) `
        -Message "Expected false"

    # A valid clone of an empty (commitless) remote has a work tree + origin but
    # no HEAD and no tracked files -- it must still count as complete so the tool
    # does not wedge re-clone attempts on empty repos.
    $emptyRemoteClone = Join-Path $testRoot "emptyremote"
    New-Item -Path $emptyRemoteClone -ItemType Directory -Force | Out-Null
    & git -C $emptyRemoteClone init --quiet 2>&1 | Out-Null
    & git -C $emptyRemoteClone remote add origin "https://example.invalid/x/_git/y" 2>&1 | Out-Null
    Assert-True -Name "clone-complete: true for empty repo with origin remote" `
        -Condition (Test-RepoCloneComplete -ClonePath $emptyRemoteClone) `
        -Message "Expected true (empty but valid clone)"

    $good = Join-Path $testRoot "good"
    New-Item -Path $good -ItemType Directory -Force | Out-Null
    & git -C $good init --quiet 2>&1 | Out-Null
    & git -C $good remote add origin "https://example.invalid/x/_git/y" 2>&1 | Out-Null
    & git -C $good config user.email "test@test.com" 2>&1 | Out-Null
    & git -C $good config user.name "Test" 2>&1 | Out-Null
    "readme" | Set-Content (Join-Path $good "README.md")
    & git -C $good add -A 2>&1 | Out-Null
    & git -C $good commit -m "init" --quiet 2>&1 | Out-Null
    Assert-True -Name "clone-complete: true for populated repo" `
        -Condition (Test-RepoCloneComplete -ClonePath $good) `
        -Message "Expected true"
} finally {
    if (Test-Path $testRoot) {
        Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$allPassed = Write-TestSummary -LayerName "repo-clone"
if (-not $allPassed) { exit 1 }
