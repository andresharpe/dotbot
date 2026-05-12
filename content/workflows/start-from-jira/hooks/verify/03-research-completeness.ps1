# 03-research-completeness.ps1
# Verify all required research artifacts exist before proceeding to implementation

$briefingDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\product\briefing"
$productDir  = Join-Path $global:DotbotProjectRoot ".bot\workspace\product"
$errors = @()
$warnings = @()

# ---------------------------------------------------------------------------
# Check required Phase 0 artifacts
# ---------------------------------------------------------------------------
$initiativePath = Join-Path $briefingDir "jira-context.md"
if (-not (Test-Path $initiativePath)) {
    $errors += "Missing: briefing/jira-context.md (Phase 0 not complete)"
}

$interviewPath = Join-Path $productDir "interview-summary.md"
if (-not (Test-Path $interviewPath)) {
    $warnings += "Missing: interview-summary.md (Phase 0 completion signal)"
}

# ---------------------------------------------------------------------------
# Check required Phase 0.5 artifacts
# ---------------------------------------------------------------------------
$missionPath = Join-Path $productDir "mission.md"
if (-not (Test-Path $missionPath)) {
    $warnings += "Missing: mission.md (Phase 0.5 product planning not complete)"
}

# ---------------------------------------------------------------------------
# Check required Phase 1 research artifacts
# ---------------------------------------------------------------------------
$requiredResearch = @(
    @{ File = "research-internet.md";    Dir = "product"; Name = "Internet research" }
    @{ File = "research-documents.md";   Dir = "product"; Name = "Atlassian document research" }
    @{ File = "research-repos.md";       Dir = "product"; Name = "Sourcebot repository research" }
)

foreach ($r in $requiredResearch) {
    $dir = if ($r.Dir -eq "product") { $productDir } else { $briefingDir }
    $path = Join-Path $dir $r.File
    if (-not (Test-Path $path)) {
        $warnings += "Missing: $($r.File) ($($r.Name) not complete)"
    }
}

# ---------------------------------------------------------------------------
# Check deep dive completeness (if 02 exists)
# ---------------------------------------------------------------------------
$reposAffectedPath = Join-Path $productDir "research-repos.md"
if (Test-Path $reposAffectedPath) {
    $reposDir = Join-Path $briefingDir "repos"
    if (-not (Test-Path $reposDir)) {
        $warnings += "No deep dive reports found (briefing/repos/ directory missing)"
    } else {
        $deepDives = Get-ChildItem -Path $reposDir -Filter "*.md" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne "00_INDEX.md" }
        if ($deepDives.Count -eq 0) {
            $warnings += "No deep dive reports found in briefing/repos/"
        }
    }
}

# ---------------------------------------------------------------------------
# Report results
# ---------------------------------------------------------------------------
if ($errors.Count -gt 0) {
    foreach ($e in $errors) {
        Write-Host "[FAIL] $e" -ForegroundColor Red
    }
    exit 1
}

if ($warnings.Count -gt 0) {
    foreach ($w in $warnings) {
        Write-Host "[WARN] $w" -ForegroundColor Yellow
    }
    Write-Host "[OK] Research completeness check passed with $($warnings.Count) warning(s)" -ForegroundColor Green
    exit 0
}

Write-Host "[OK] All research artifacts present" -ForegroundColor Green
exit 0
