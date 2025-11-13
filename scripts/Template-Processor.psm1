# =============================================================================
# dotbot Template Processor Module
# Processes template variables and conditional blocks in markdown files
# =============================================================================

<#
.SYNOPSIS
Processes template variables and conditional blocks in content.

.DESCRIPTION
Handles:
- {{IF variable}}...{{ENDIF variable}} blocks
- {{UNLESS variable}}...{{ENDUNLESS variable}} blocks
- Nested conditionals
- {{variable}} substitution

.EXAMPLE
$context = @{ warp_commands = $true; standards_as_warp_rules = $false }
$processed = Invoke-ProcessConditionals -Content $content -Variables $context
#>

# Process conditional blocks ({{IF}}, {{UNLESS}}, {{ENDIF}}, {{ENDUNLESS}})
function Invoke-ProcessConditionals {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Variables
    )
    
    $result = @()
    $lines = $Content -split "`n"
    $nestingLevel = 0
    $shouldIncludeStack = @($true)  # Start with true (root level)
    $shouldInclude = $true
    
    foreach ($line in $lines) {
        # Check for {{IF variable_name}}
        if ($line -match '^\s*\{\{IF\s+([a-z_]+)\s*\}\}') {
            $variableName = $matches[1]
            
            # Evaluate condition
            $conditionMet = $false
            if ($Variables.ContainsKey($variableName)) {
                $conditionMet = $Variables[$variableName] -eq $true
            } else {
                Write-Warning "Unknown variable in IF block: $variableName"
            }
            
            # Push current state onto stack
            $shouldIncludeStack += $shouldInclude
            
            # Update should_include based on parent's state AND current condition
            $shouldInclude = ($shouldInclude -and $conditionMet)
            
            $nestingLevel++
            continue
        }
        
        # Check for {{UNLESS variable_name}}
        if ($line -match '^\s*\{\{UNLESS\s+([a-z_]+)\s*\}\}') {
            $variableName = $matches[1]
            
            # Evaluate condition (opposite of IF)
            $conditionMet = $false
            if ($Variables.ContainsKey($variableName)) {
                $conditionMet = $Variables[$variableName] -ne $true
            } else {
                Write-Warning "Unknown variable in UNLESS block: $variableName"
            }
            
            # Push current state onto stack
            $shouldIncludeStack += $shouldInclude
            
            # Update should_include based on parent's state AND current condition
            $shouldInclude = ($shouldInclude -and $conditionMet)
            
            $nestingLevel++
            continue
        }
        
        # Check for {{ENDIF variable_name}}
        if ($line -match '^\s*\{\{ENDIF\s+([a-z_]+)\s*\}\}') {
            $nestingLevel--
            
            # Pop should_include from stack
            if ($shouldIncludeStack.Count -gt 0) {
                $shouldInclude = $shouldIncludeStack[-1]
                $shouldIncludeStack = $shouldIncludeStack[0..($shouldIncludeStack.Count - 2)]
            } else {
                $shouldInclude = $true
            }
            
            continue
        }
        
        # Check for {{ENDUNLESS variable_name}}
        if ($line -match '^\s*\{\{ENDUNLESS\s+([a-z_]+)\s*\}\}') {
            $nestingLevel--
            
            # Pop should_include from stack
            if ($shouldIncludeStack.Count -gt 0) {
                $shouldInclude = $shouldIncludeStack[-1]
                $shouldIncludeStack = $shouldIncludeStack[0..($shouldIncludeStack.Count - 2)]
            } else {
                $shouldInclude = $true
            }
            
            continue
        }
        
        # Output line if we should include it
        if ($shouldInclude) {
            $result += $line
        }
    }
    
    # Join lines back together
    return $result -join "`n"
}

<#
.SYNOPSIS
Processes variable substitution (e.g., {{variable_name}}).

.DESCRIPTION
Replaces {{variable_name}} with the corresponding value from the variables hashtable.

.EXAMPLE
$context = @{ profile = "default"; version = "1.0.0" }
$processed = Invoke-ProcessVariableSubstitution -Content $content -Variables $context
#>
function Invoke-ProcessVariableSubstitution {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Variables
    )
    
    $result = $Content
    
    foreach ($key in $Variables.Keys) {
        $value = $Variables[$key]
        $placeholder = "{{$key}}"
        
        # Only substitute non-boolean values (booleans are for conditionals only)
        if ($value -isnot [bool]) {
            # Escape both placeholder and value for safe regex replacement
            $escapedPlaceholder = [regex]::Escape($placeholder)
            $escapedValue = $value -replace '\$', '$$$$'  # Escape $ for replacement string
            $result = $result -replace $escapedPlaceholder, $escapedValue
        }
    }
    
    return $result
}

<#
.SYNOPSIS
Processes file references (e.g., {{workflows/path/to/file}}).

.DESCRIPTION
Finds and replaces file references with the actual file content.
References are relative to the profile directory.

.EXAMPLE
$processed = Invoke-ProcessFileReferences -Content $content -Profile "default" -BaseDir "C:\Users\user\dotbot"
#>
function Invoke-ProcessFileReferences {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,
        
        [Parameter(Mandatory = $true)]
        [string]$Profile,
        
        [Parameter(Mandatory = $true)]
        [string]$BaseDir
    )
    
    $result = $Content
    
    # Find all file references: {{workflows/path/to/file}}, {{standards/path}}, etc.
    $references = [regex]::Matches($result, '\{\{((?:workflows|standards|commands|agents)/[^}]+)\}\}')
    
    foreach ($match in $references) {
        $reference = $match.Groups[1].Value  # e.g., "workflows/implementation/implement-tasks"
        $placeholder = $match.Groups[0].Value  # e.g., "{{workflows/implementation/implement-tasks}}"
        
        # Construct the file path
        $filePath = Join-Path $BaseDir "profiles" $Profile "$reference.md"
        
        if (Test-Path $filePath) {
            $fileContent = Get-Content $filePath -Raw
            # Escape special regex characters in placeholder
            $escapedPlaceholder = [regex]::Escape($placeholder)
            $result = $result -replace $escapedPlaceholder, $fileContent
        } else {
            Write-VerboseLog "File reference not found: $filePath"
            # Leave placeholder as-is or replace with warning message
            $warning = "⚠️ This file was not found: $reference"
            $escapedPlaceholder = [regex]::Escape($placeholder)
            $result = $result -replace $escapedPlaceholder, $warning
        }
    }
    
    return $result
}

<#
.SYNOPSIS
Processes all template variables and conditionals in content.

.DESCRIPTION
Main entry point that chains together:
1. Process conditionals ({{IF}}/{{UNLESS}})
2. Process file references ({{workflows/...}})
3. Process variable substitution ({{variable}})

.EXAMPLE
$context = @{ 
    warp_commands = $true
    standards_as_warp_rules = $false
    profile = "default"
    version = "1.0.0"
}
$processed = Invoke-ProcessTemplate -Content $content -Variables $context -Profile "default" -BaseDir $baseDir
#>
function Invoke-ProcessTemplate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Variables,
        
        [Parameter(Mandatory = $true)]
        [string]$Profile,
        
        [Parameter(Mandatory = $true)]
        [string]$BaseDir
    )
    
    # Step 1: Process conditionals first
    $result = Invoke-ProcessConditionals -Content $Content -Variables $Variables
    
    # Step 2: Process file references
    $result = Invoke-ProcessFileReferences -Content $result -Profile $Profile -BaseDir $BaseDir
    
    # Step 3: Process variable substitution
    $result = Invoke-ProcessVariableSubstitution -Content $result -Variables $Variables
    
    return $result
}

# Export functions
Export-ModuleMember -Function @(
    'Invoke-ProcessConditionals',
    'Invoke-ProcessVariableSubstitution',
    'Invoke-ProcessFileReferences',
    'Invoke-ProcessTemplate'
)
