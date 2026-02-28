<#
.SYNOPSIS
Product document management API module

.DESCRIPTION
Provides product document listing, retrieval, kickstart (Claude-driven doc creation),
and roadmap planning functionality.
Extracted from server.ps1 for modularity.
#>

$script:Config = @{
    BotRoot = $null
    ControlDir = $null
}

function Initialize-ProductAPI {
    param(
        [Parameter(Mandatory)] [string]$BotRoot,
        [Parameter(Mandatory)] [string]$ControlDir
    )
    $script:Config.BotRoot = $BotRoot
    $script:Config.ControlDir = $ControlDir
}

function Get-ProductList {
    $botRoot = $script:Config.BotRoot
    $productDir = Join-Path $botRoot "workspace\product"
    $docs = @()

    if (Test-Path $productDir) {
        $mdFiles = @(Get-ChildItem -Path $productDir -Filter "*.md" -ErrorAction SilentlyContinue)

        # Define priority order for product files
        $priorityOrder = [System.Collections.Generic.List[string]]@(
            'mission',
            'entity-model',
            'tech-stack',
            'roadmap',
            'roadmap-overview'
        )

        # Separate files into priority and non-priority
        $priorityFiles = [System.Collections.ArrayList]@()
        $otherFiles = [System.Collections.ArrayList]@()

        foreach ($file in $mdFiles) {
            if ($null -eq $file) { continue }
            $priorityIndex = $priorityOrder.IndexOf($file.BaseName)
            if ($priorityIndex -ge 0) {
                [void]$priorityFiles.Add([PSCustomObject]@{
                    File = $file
                    Priority = $priorityIndex
                })
            } else {
                [void]$otherFiles.Add($file)
            }
        }

        # Sort priority files by their priority index
        if ($priorityFiles.Count -gt 0) {
            $priorityFiles = @($priorityFiles | Sort-Object -Property Priority)
        }

        # Sort other files alphabetically
        if ($otherFiles.Count -gt 0) {
            $otherFiles = @($otherFiles | Sort-Object -Property BaseName)
        }

        # Build final docs array: priority first, then alphabetical
        foreach ($pf in $priorityFiles) {
            if ($null -eq $pf) { continue }
            $docs += @{
                name = $pf.File.BaseName
                filename = $pf.File.Name
            }
        }
        foreach ($file in $otherFiles) {
            if ($null -eq $file) { continue }
            $docs += @{
                name = $file.BaseName
                filename = $file.Name
            }
        }
    }

    return @{ docs = $docs }
}

function Get-ProductDocument {
    param(
        [Parameter(Mandatory)] [string]$Name
    )
    $botRoot = $script:Config.BotRoot
    $productDir = Join-Path $botRoot "workspace\product"
    $docPath = Join-Path $productDir "$Name.md"

    if (Test-Path $docPath) {
        $docContent = Get-Content -Path $docPath -Raw
        return @{
            success = $true
            name = $Name
            content = $docContent
        }
    } else {
        return @{
            _statusCode = 404
            success = $false
            error = "Document not found: $Name"
        }
    }
}

function Start-ProductKickstart {
    param(
        [Parameter(Mandatory)] [string]$UserPrompt,
        [array]$Files = @(),
        [bool]$NeedsInterview = $true
    )
    $botRoot = $script:Config.BotRoot

    # Create briefing directory
    $briefingDir = Join-Path $botRoot "workspace\product\briefing"
    if (-not (Test-Path $briefingDir)) {
        New-Item -Path $briefingDir -ItemType Directory -Force | Out-Null
    }

    # Decode and save files
    $savedFiles = @()
    foreach ($file in $Files) {
        if (-not $file -or -not $file.name -or -not $file.content) { continue }

        try {
            $decoded = [Convert]::FromBase64String($file.content)
            $safeName = $file.name -replace '[^\w\-\.]', '_'
            $filePath = Join-Path $briefingDir $safeName

            [System.IO.File]::WriteAllBytes($filePath, $decoded)
            $savedFiles += $filePath
        } catch {
            foreach ($savedFile in $savedFiles) {
                Remove-Item -LiteralPath $savedFile -Force -ErrorAction SilentlyContinue
            }

            return @{
                _statusCode = 400
                success = $false
                error = "Invalid base64 content for file '$($file.name)'"
            }
        }
    }

    # Launch kickstart as tracked process
    # Write prompt to a file and use a wrapper script to avoid Start-Process quoting issues
    $launcherPath = Join-Path $botRoot "systems\runtime\launch-process.ps1"
    $promptFile = Join-Path $briefingDir "kickstart-prompt.txt"
    $UserPrompt | Set-Content -Path $promptFile -Encoding UTF8 -NoNewline

    $wrapperPath = Join-Path $briefingDir "kickstart-launcher.ps1"
    $interviewLine = if ($NeedsInterview) { " -NeedsInterview" } else { "" }
    @"
`$prompt = Get-Content -LiteralPath '$promptFile' -Raw
& '$launcherPath' -Type kickstart -Prompt `$prompt -Description 'Kickstart: project setup'$interviewLine
"@ | Set-Content -Path $wrapperPath -Encoding UTF8

    $proc = Start-Process pwsh -ArgumentList "-NoProfile", "-File", $wrapperPath -WindowStyle Normal -PassThru

    # Find process_id by PID
    Start-Sleep -Milliseconds 500
    $processesDir = Join-Path $script:Config.ControlDir "processes"
    $launchedProcId = $null
    $procFiles = Get-ChildItem -Path $processesDir -Filter "*.json" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    foreach ($pf in $procFiles) {
        try {
            $pData = Get-Content $pf.FullName -Raw | ConvertFrom-Json
            if ($pData.pid -eq $proc.Id) {
                $launchedProcId = $pData.id
                break
            }
        } catch {}
    }

    Write-Status "Product kickstart launched (PID: $($proc.Id))" -Type Info

    return @{
        success = $true
        process_id = $launchedProcId
        message = "Kickstart initiated. Product documents, task groups, and task expansion will run in a tracked process."
    }
}

function Start-ProductAnalyse {
    param(
        [string]$UserPrompt = "",
        [ValidateSet('Opus', 'Sonnet', 'Haiku')]
        [string]$Model = "Sonnet"
    )
    $botRoot = $script:Config.BotRoot

    # Launch analyse as a tracked process via launch-process.ps1
    $launcherPath = Join-Path $botRoot "systems\runtime\launch-process.ps1"
    $launchArgs = @(
        "-File", "`"$launcherPath`"",
        "-Type", "analyse",
        "-Model", $Model,
        "-Description", "`"Analyse: existing project`""
    )
    if ($UserPrompt) {
        $escapedPrompt = $UserPrompt -replace '"', '\"'
        $launchArgs += @("-Prompt", "`"$escapedPrompt`"")
    }
    Start-Process pwsh -ArgumentList $launchArgs -WindowStyle Normal | Out-Null
    Write-Status "Product analyse launched as tracked process" -Type Info

    return @{
        success = $true
        message = "Analyse initiated. Product documents will be generated from your existing codebase."
    }
}

function Start-RoadmapPlanning {
    $botRoot = $script:Config.BotRoot

    # Validate product docs exist
    $productDir = Join-Path $botRoot "workspace\product"
    $requiredDocs = @("mission.md", "tech-stack.md", "entity-model.md")
    $missingDocs = @()
    foreach ($doc in $requiredDocs) {
        $docPath = Join-Path $productDir $doc
        if (-not (Test-Path $docPath)) {
            $missingDocs += $doc
        }
    }

    if ($missingDocs.Count -gt 0) {
        return @{
            _statusCode = 400
            success = $false
            error = "Missing required product docs: $($missingDocs -join ', '). Run kickstart first."
        }
    }

    # Launch via process manager
    $launcherPath = Join-Path $botRoot "systems\runtime\launch-process.ps1"
    $launchArgs = @("-File", "`"$launcherPath`"", "-Type", "planning", "-Model", "Sonnet", "-Description", "`"Plan project roadmap`"")
    Start-Process pwsh -ArgumentList $launchArgs -WindowStyle Normal | Out-Null
    Write-Status "Roadmap planning launched as tracked process" -Type Info

    return @{
        success = $true
        message = "Roadmap planning initiated via process manager."
    }
}

Export-ModuleMember -Function @(
    'Initialize-ProductAPI',
    'Get-ProductList',
    'Get-ProductDocument',
    'Start-ProductKickstart',
    'Start-ProductAnalyse',
    'Start-RoadmapPlanning'
)
