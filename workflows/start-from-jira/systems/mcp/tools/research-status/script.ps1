function Invoke-ResearchStatus {
    param([hashtable]$Arguments)

    $briefingDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\product\briefing"
    $productDir  = Join-Path $global:DotbotProjectRoot ".bot\workspace\product"

    # ---------------------------------------------------------------------------
    # Check core artifacts
    # ---------------------------------------------------------------------------
    $coreArtifacts = @(
        @{ Name = "jira-context.md"; Dir = "briefing"; Phase = "Phase 0";  Required = $true  }
    )

    # Research outputs live in the product dir, not briefing
    $researchArtifacts = @(
        @{ Name = "research-internet.md";    Dir = "product"; Phase = "Phase 1";  Required = $true  }
        @{ Name = "research-documents.md";   Dir = "product"; Phase = "Phase 1";  Required = $true  }
        @{ Name = "research-repos.md";       Dir = "product"; Phase = "Phase 1";  Required = $true  }
    )

    $artifacts = @()
    $existCount = 0
    $requiredMissing = @()

    # Check briefing artifacts
    foreach ($a in $coreArtifacts) {
        $dir = if ($a.Dir -eq "product") { $productDir } else { $briefingDir }
        $path = Join-Path $dir $a.Name
        $exists = Test-Path $path
        if ($exists) { $existCount++ }
        if ($a.Required -and -not $exists) { $requiredMissing += $a.Name }

        $artifacts += @{
            name     = $a.Name
            phase    = $a.Phase
            exists   = $exists
            required = $a.Required
        }
    }

    # Check research artifacts
    foreach ($a in $researchArtifacts) {
        $path = Join-Path $productDir $a.Name
        $exists = Test-Path $path
        if ($exists) { $existCount++ }
        if ($a.Required -and -not $exists) { $requiredMissing += $a.Name }

        $artifacts += @{
            name     = $a.Name
            phase    = $a.Phase
            exists   = $exists
            required = $a.Required
        }
    }

    # ---------------------------------------------------------------------------
    # Check product docs
    # ---------------------------------------------------------------------------
    $productDocs = @(
        @{ Name = "mission.md";           Phase = "Phase 0.5" }
        @{ Name = "roadmap-overview.md";  Phase = "Phase 0.5" }
        @{ Name = "tech-stack.md";        Phase = "Phase 3"   }
    )

    $productArtifacts = @()
    foreach ($d in $productDocs) {
        $path = Join-Path $productDir $d.Name
        $productArtifacts += @{
            name   = $d.Name
            phase  = $d.Phase
            exists = Test-Path $path
        }
    }

    # ---------------------------------------------------------------------------
    # Check deep dive reports
    # ---------------------------------------------------------------------------
    # Check deep dive reports — look in product dir with naming convention
    $deepDives = @()
    $indexExists = $false
    $summaryFiles = Get-ChildItem -Path $productDir -Filter "research-repo-*-summary.md" -File -ErrorAction SilentlyContinue
    foreach ($f in $summaryFiles) {
        $repoName = $f.BaseName -replace '^research-repo-', '' -replace '-summary$', ''
        $deepDives += @{
            repo = $repoName
            path = $f.FullName
        }
    }

    # Also check legacy location (briefing/repos/) for backward compatibility
    $reposDir = Join-Path $briefingDir "repos"
    if (Test-Path $reposDir) {
        $files = Get-ChildItem -Path $reposDir -Filter "*.md" -File -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            if ($f.Name -eq "00_INDEX.md") {
                $indexExists = $true
            } else {
                $deepDives += @{
                    repo = $f.BaseName
                    path = $f.FullName
                }
            }
        }
    }

    # ---------------------------------------------------------------------------
    # Determine overall phase
    # ---------------------------------------------------------------------------
    $phase = "not-started"
    $initiativeExists = Test-Path (Join-Path $briefingDir "jira-context.md")
    $missionExists    = Test-Path (Join-Path $productDir "mission.md")
    $researchComplete = (Test-Path (Join-Path $productDir "research-internet.md")) -and
                        (Test-Path (Join-Path $productDir "research-documents.md")) -and
                        (Test-Path (Join-Path $productDir "research-repos.md"))
    $implResearchExists = Test-Path (Join-Path $briefingDir "04_IMPLEMENTATION_RESEARCH.md")

    if ($initiativeExists) { $phase = "started" }
    if ($missionExists)    { $phase = "planned" }
    if ($researchComplete) { $phase = "research-complete" }
    if ($deepDives.Count -gt 0) { $phase = "deep-dives-in-progress" }
    if ($implResearchExists) { $phase = "implementation-research-complete" }
    if ($indexExists)      { $phase = "refined" }

    # ---------------------------------------------------------------------------
    # Return result
    # ---------------------------------------------------------------------------
    return @{
        success           = $true
        phase             = $phase
        core_artifacts    = $artifacts
        product_docs      = $productArtifacts
        deep_dives        = $deepDives
        deep_dive_count   = $deepDives.Count
        index_exists      = $indexExists
        artifacts_found   = $existCount
        artifacts_total   = $coreArtifacts.Count + $researchArtifacts.Count
        required_missing  = $requiredMissing
        message           = if ($requiredMissing.Count -eq 0) {
            "All required artifacts present. Phase: $phase. $($deepDives.Count) deep dive(s) complete."
        } else {
            "Missing required: $($requiredMissing -join ', '). Phase: $phase."
        }
    }
}
