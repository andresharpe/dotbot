<#
.SYNOPSIS
TaskDefinition schema validation.

TaskDefinition shape (a single entry in workflow.json's `tasks` array):
  - name           : string, required
  - type           : string, required (executor plugin name — 'prompt'/'script'/'mcp' initially)
  - depends_on     : array of strings (other TaskDefinition names), optional
  - prompt         : string (path or inline text), optional
  - outputs        : array of strings, optional
  - priority       : int or named (low/normal/high/critical), optional
  - optional       : bool, optional (default false)

Rejected if present: skip_worktree, working_dir, external_repo, commit,
front_matter_docs, post_script. (post_script is a transition-hook concern.)
#>

$script:DotbotTaskDefFields = @(
    'name', 'type', 'depends_on', 'prompt', 'outputs', 'priority', 'optional'
)

# Fields that legacy manifests may still carry; explicitly rejected so a
# stale manifest fails loudly instead of being silently accepted.
$script:DotbotTaskDefRemovedFields = @(
    'skip_worktree', 'working_dir', 'external_repo', 'commit',
    'front_matter_docs', 'post_script'
)

$script:DotbotTaskDefRequired = @('name', 'type')

$script:DotbotPriorityNames = @('low', 'normal', 'high', 'critical')

function _Get-Prop {
    param($Bag, [string]$Name)
    if ($null -eq $Bag) { return $null }
    if ($Bag -is [System.Collections.IDictionary]) {
        if ($Bag.Contains($Name)) { return $Bag[$Name] }
        return $null
    }
    $prop = $Bag.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function _Has-Prop {
    param($Bag, [string]$Name)
    if ($null -eq $Bag) { return $false }
    if ($Bag -is [System.Collections.IDictionary]) { return $Bag.Contains($Name) }
    return $null -ne $Bag.PSObject.Properties[$Name]
}

function _Get-Keys {
    param($Bag)
    if ($null -eq $Bag) { return @() }
    if ($Bag -is [System.Collections.IDictionary]) { return @($Bag.Keys) }
    return @($Bag.PSObject.Properties.Name)
}

function Get-TaskDefinitionFields {
    return ,@($script:DotbotTaskDefFields)
}

function Get-TaskDefinitionRemovedFields {
    return ,@($script:DotbotTaskDefRemovedFields)
}

function Test-TaskDefinition {
    <#
    .SYNOPSIS
    Validate a TaskDefinition shape. Returns array of human-readable errors.

    .DESCRIPTION
    Rejects:
      - missing required fields (name, type)
      - any legacy-only field (skip_worktree, working_dir, external_repo,
        commit, front_matter_docs, post_script)
      - any other unknown top-level field

    Accepts hashtable / IDictionary / PSCustomObject.
    #>
    param(
        [Parameter(Mandatory)]
        $TaskDef
    )

    $errors = [System.Collections.ArrayList]::new()

    if ($null -eq $TaskDef) {
        [void]$errors.Add('task_definition: is null')
        return ,@($errors.ToArray())
    }
    if ($TaskDef -isnot [System.Collections.IDictionary] -and $TaskDef -isnot [PSCustomObject]) {
        [void]$errors.Add('task_definition: must be a hashtable or object')
        return ,@($errors.ToArray())
    }

    foreach ($k in (_Get-Keys $TaskDef)) {
        if ($script:DotbotTaskDefRemovedFields -contains $k) {
            [void]$errors.Add("$k`: rejected (not allowed in TaskDefinition)")
            continue
        }
        if ($script:DotbotTaskDefFields -notcontains $k) {
            [void]$errors.Add("$k`: is not a known TaskDefinition field")
        }
    }

    foreach ($f in $script:DotbotTaskDefRequired) {
        $v = _Get-Prop $TaskDef $f
        if ($null -eq $v -or ($v -is [string] -and [string]::IsNullOrWhiteSpace($v))) {
            [void]$errors.Add("$f`: is required")
        }
    }

    # depends_on — array of strings.
    # PowerShell unwraps single-element arrays through function returns AND
    # if-expressions, so we use explicit if/else blocks (not if-expressions).
    if (_Has-Prop $TaskDef 'depends_on') {
        if ($TaskDef -is [System.Collections.IDictionary]) {
            $depsRaw = $TaskDef['depends_on']
        } else {
            $depsRaw = $TaskDef.depends_on
        }
        if ($null -ne $depsRaw) {
            if ($depsRaw -is [string]) {
                [void]$errors.Add('depends_on: must be an array of TaskDefinition names, not a single string')
            } else {
                $i = 0
                foreach ($d in @($depsRaw)) {
                    if ($d -isnot [string] -or [string]::IsNullOrWhiteSpace($d)) {
                        [void]$errors.Add("depends_on[$i]: must be a non-empty string")
                    }
                    $i++
                }
            }
        }
    }

    # outputs — array of strings.
    if (_Has-Prop $TaskDef 'outputs') {
        if ($TaskDef -is [System.Collections.IDictionary]) {
            $outsRaw = $TaskDef['outputs']
        } else {
            $outsRaw = $TaskDef.outputs
        }
        if ($null -ne $outsRaw) {
            if ($outsRaw -is [string]) {
                [void]$errors.Add('outputs: must be an array of strings, not a single string')
            } else {
                $i = 0
                foreach ($o in @($outsRaw)) {
                    if ($o -isnot [string]) {
                        [void]$errors.Add("outputs[$i]: must be a string")
                    }
                    $i++
                }
            }
        }
    }

    # priority — int or named
    $priority = _Get-Prop $TaskDef 'priority'
    if ($null -ne $priority) {
        $isNamed = $priority -is [string] -and ($script:DotbotPriorityNames -contains $priority)
        $isInt   = ($priority -is [int]) -or ($priority -is [long])
        if (-not ($isNamed -or $isInt)) {
            [void]$errors.Add("priority: must be one of $($script:DotbotPriorityNames -join '/'), or an integer (got '$priority')")
        }
    }

    # optional — bool
    $optional = _Get-Prop $TaskDef 'optional'
    if ($null -ne $optional -and $optional -isnot [bool]) {
        [void]$errors.Add('optional: must be a boolean')
    }

    # name — string
    $name = _Get-Prop $TaskDef 'name'
    if ($null -ne $name -and $name -isnot [string]) {
        [void]$errors.Add('name: must be a string')
    }

    # type — string
    $type = _Get-Prop $TaskDef 'type'
    if ($null -ne $type -and $type -isnot [string]) {
        [void]$errors.Add('type: must be a string (executor plugin name, e.g. prompt/script/mcp)')
    }

    # prompt — string
    $prompt = _Get-Prop $TaskDef 'prompt'
    if ($null -ne $prompt -and $prompt -isnot [string]) {
        [void]$errors.Add('prompt: must be a string')
    }

    return ,@($errors.ToArray())
}

function Assert-TaskDefinition {
    <#
    .SYNOPSIS
    Throw if a TaskDefinition is invalid.
    #>
    param(
        [Parameter(Mandatory)]
        $TaskDef
    )
    $errs = Test-TaskDefinition -TaskDef $TaskDef
    if ($errs -and $errs.Count -gt 0) {
        throw "Invalid TaskDefinition:`n  - $($errs -join "`n  - ")"
    }
}

Export-ModuleMember -Function @(
    'Get-TaskDefinitionFields'
    'Get-TaskDefinitionRemovedFields'
    'Test-TaskDefinition'
    'Assert-TaskDefinition'
)
