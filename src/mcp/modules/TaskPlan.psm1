<#
.SYNOPSIS
Task plan persistence for MCP plan tools.

.DESCRIPTION
Plans are project artifacts stored under .bot/workspace/plans. The link from a
task to its plan is runner-owned metadata, so it lives at
extensions.runner.plan_path rather than as a top-level TaskInstance field.
#>

Import-Module (Join-Path $PSScriptRoot "TaskStore.psm1") -DisableNameChecking -Global
Import-Module (Join-Path $PSScriptRoot "TaskFile.psm1") -DisableNameChecking -Global

function Get-TaskPlanProperty {
    param(
        [Parameter(Mandatory)] $Object,
        [Parameter(Mandatory)] [string]$Name
    )
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    if ($Object.PSObject.Properties[$Name]) { return $Object.PSObject.Properties[$Name].Value }
    return $null
}

function Set-TaskPlanProperty {
    param(
        [Parameter(Mandatory)] $Object,
        [Parameter(Mandatory)] [string]$Name,
        $Value
    )
    if ($Object -is [System.Collections.IDictionary]) {
        $Object[$Name] = $Value
        return
    }
    if ($Object.PSObject.Properties[$Name]) {
        $Object.$Name = $Value
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
}

function Remove-TaskPlanProperty {
    param(
        [Parameter(Mandatory)] $Object,
        [Parameter(Mandatory)] [string]$Name
    )
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { $Object.Remove($Name) | Out-Null }
        return
    }
    if ($Object.PSObject.Properties[$Name]) {
        $Object.PSObject.Properties.Remove($Name)
    }
}

function Get-TaskPlanRunnerExtension {
    param([Parameter(Mandatory)] $Task)

    $extensions = Get-TaskPlanProperty -Object $Task -Name 'extensions'
    if ($null -eq $extensions -or
        ($extensions -isnot [System.Collections.IDictionary] -and $extensions -isnot [PSCustomObject])) {
        $extensions = [ordered]@{}
        Set-TaskPlanProperty -Object $Task -Name 'extensions' -Value $extensions
    }

    $runner = Get-TaskPlanProperty -Object $extensions -Name 'runner'
    if ($null -eq $runner -or
        ($runner -isnot [System.Collections.IDictionary] -and $runner -isnot [PSCustomObject])) {
        $runner = [ordered]@{}
        Set-TaskPlanProperty -Object $extensions -Name 'runner' -Value $runner
    }

    return $runner
}

function Get-TaskPlanPath {
    param([Parameter(Mandatory)] $Task)

    $extensions = Get-TaskPlanProperty -Object $Task -Name 'extensions'
    if ($extensions) {
        $runner = Get-TaskPlanProperty -Object $extensions -Name 'runner'
        if ($runner) {
            $runnerPlanPath = Get-TaskPlanProperty -Object $runner -Name 'plan_path'
            if ($runnerPlanPath) { return [string]$runnerPlanPath }
        }
    }

    $legacyPlanPath = Get-TaskPlanProperty -Object $Task -Name 'plan_path'
    if ($legacyPlanPath) { return [string]$legacyPlanPath }
    return $null
}

function Set-TaskPlanPath {
    param(
        [Parameter(Mandatory)] $Task,
        [Parameter(Mandatory)] [string]$PlanPath
    )

    $runner = Get-TaskPlanRunnerExtension -Task $Task
    Set-TaskPlanProperty -Object $runner -Name 'plan_path' -Value $PlanPath
    Remove-TaskPlanProperty -Object $Task -Name 'plan_path'
}

function Resolve-TaskPlanFullPath {
    param([Parameter(Mandatory)] [string]$PlanPath)

    if ([System.IO.Path]::IsPathRooted($PlanPath)) { return $PlanPath }
    return (Join-Path (Get-DotbotProjectRoot) $PlanPath)
}

function New-TaskPlan {
    param(
        [Parameter(Mandatory)] [string]$TaskId,
        [Parameter(Mandatory)] [string]$Content
    )

    $found = Find-TaskFileById -TaskId $TaskId
    if (-not $found) { throw "Task not found with ID: $TaskId" }

    $planFilename = $found.File.Name -replace '\.json$', '-plan.md'
    $plansDir = Join-Path (Join-Path (Get-DotbotProjectRoot) '.bot') (Join-Path 'workspace' 'plans')
    if (-not (Test-Path -LiteralPath $plansDir)) {
        New-Item -ItemType Directory -Force -Path $plansDir | Out-Null
    }

    $planFullPath = Join-Path $plansDir $planFilename
    Set-Content -Path $planFullPath -Value $Content -Encoding UTF8

    $relativePlanPath = ".bot/workspace/plans/$planFilename"
    $task = $found.Content
    Set-TaskPlanPath -Task $task -PlanPath $relativePlanPath
    Set-OrAddProperty -Object $task -Name 'updated_at' -Value ((Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"))

    Write-TaskFileAtomic -Path $found.File.FullName -Content $task -Depth 20 -TaskId $TaskId

    return @{
        success       = $true
        task_id       = $TaskId
        task_name     = $task.name
        plan_path     = $relativePlanPath
        plan_filename = $planFilename
        message       = "Plan created and linked to task '$($task.name)'"
    }
}

function Get-TaskPlan {
    param([Parameter(Mandatory)] [string]$TaskId)

    $found = Find-TaskFileById -TaskId $TaskId
    if (-not $found) { throw "Task not found with ID: $TaskId" }

    $task = $found.Content
    $planPath = Get-TaskPlanPath -Task $task
    if (-not $planPath) {
        return @{
            success   = $true
            has_plan  = $false
            task_id   = $TaskId
            task_name = $task.name
            message   = "No plan found for this task"
        }
    }

    $planFullPath = Resolve-TaskPlanFullPath -PlanPath $planPath
    if (-not (Test-Path -LiteralPath $planFullPath)) {
        return @{
            success   = $true
            has_plan  = $false
            task_id   = $TaskId
            task_name = $task.name
            plan_path = $planPath
            message   = "Plan file not found at: $planPath"
        }
    }

    return @{
        success   = $true
        has_plan  = $true
        task_id   = $TaskId
        task_name = $task.name
        plan_path = $planPath
        content   = Get-Content -LiteralPath $planFullPath -Raw
        message   = "Plan retrieved for task '$($task.name)'"
    }
}

function Update-TaskPlan {
    param(
        [Parameter(Mandatory)] [string]$TaskId,
        [Parameter(Mandatory)] [string]$Content
    )

    $found = Find-TaskFileById -TaskId $TaskId
    if (-not $found) { throw "Task not found with ID: $TaskId" }

    $task = $found.Content
    $planPath = Get-TaskPlanPath -Task $task
    if (-not $planPath) {
        throw "Task does not have a linked plan. Use plan_create to create one first."
    }

    $planFullPath = Resolve-TaskPlanFullPath -PlanPath $planPath
    if (-not (Test-Path -LiteralPath $planFullPath)) {
        throw "Plan file not found at: $planPath. Use plan_create to create a new plan."
    }

    Set-Content -Path $planFullPath -Value $Content -Encoding UTF8
    Set-TaskPlanPath -Task $task -PlanPath $planPath
    Set-OrAddProperty -Object $task -Name 'updated_at' -Value ((Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"))
    Write-TaskFileAtomic -Path $found.File.FullName -Content $task -Depth 20 -TaskId $TaskId

    return @{
        success   = $true
        task_id   = $TaskId
        task_name = $task.name
        plan_path = $planPath
        message   = "Plan updated for task '$($task.name)'"
    }
}

Export-ModuleMember -Function @(
    'New-TaskPlan',
    'Get-TaskPlan',
    'Update-TaskPlan',
    'Get-TaskPlanPath',
    'Set-TaskPlanPath'
)
