# =============================================================================
# Template Processor Tests
# =============================================================================

Import-Module (Join-Path $PSScriptRoot ".." "scripts" "Template-Processor.psm1") -Force

# Test suite
Describe "Invoke-ProcessConditionals" {
    
    It "includes content when IF condition is true" {
        $content = @"
Before
{{IF warp_commands}}
This should be included
{{ENDIF warp_commands}}
After
"@
        $variables = @{ warp_commands = $true }
        $result = Invoke-ProcessConditionals -Content $content -Variables $variables
        $result.Contains("This should be included") | Should Be $true
        $result.Contains("Before") | Should Be $true
        $result.Contains("After") | Should Be $true
    }
    
    It "excludes content when IF condition is false" {
        $content = @"
Before
{{IF warp_commands}}
This should be excluded
{{ENDIF warp_commands}}
After
"@
        $variables = @{ warp_commands = $false }
        $result = Invoke-ProcessConditionals -Content $content -Variables $variables
        $result.Contains("This should be excluded") | Should Be $false
        $result.Contains("Before") | Should Be $true
        $result.Contains("After") | Should Be $true
    }
    
    It "includes content when UNLESS condition is false" {
        $content = @"
Before
{{UNLESS warp_commands}}
This should be included
{{ENDUNLESS warp_commands}}
After
"@
        $variables = @{ warp_commands = $false }
        $result = Invoke-ProcessConditionals -Content $content -Variables $variables
        $result.Contains("This should be included") | Should Be $true
    }
    
    It "excludes content when UNLESS condition is true" {
        $content = @"
Before
{{UNLESS warp_commands}}
This should be excluded
{{ENDUNLESS warp_commands}}
After
"@
        $variables = @{ warp_commands = $true }
        $result = Invoke-ProcessConditionals -Content $content -Variables $variables
        $result.Contains("This should be excluded") | Should Be $false
    }
    
    It "handles nested conditionals" {
        $content = @"
Outer start
{{IF warp_commands}}
Outer true start
{{IF standards_as_warp_rules}}
Both true
{{ENDIF standards_as_warp_rules}}
Outer true end
{{ENDIF warp_commands}}
Outer end
"@
        $variables = @{ warp_commands = $true; standards_as_warp_rules = $true }
        $result = Invoke-ProcessConditionals -Content $content -Variables $variables
        $result.Contains("Both true") | Should Be $true
        $result.Contains("Outer true start") | Should Be $true
        
        $variables = @{ warp_commands = $true; standards_as_warp_rules = $false }
        $result = Invoke-ProcessConditionals -Content $content -Variables $variables
        $result.Contains("Both true") | Should Be $false
        $result.Contains("Outer true start") | Should Be $true
    }
    
    It "removes block delimiters from output" {
        $content = @"
{{IF warp_commands}}
Content
{{ENDIF warp_commands}}
"@
        $variables = @{ warp_commands = $true }
        $result = Invoke-ProcessConditionals -Content $content -Variables $variables
        $result.Contains("{{IF") | Should Be $false
        $result.Contains("{{ENDIF") | Should Be $false
    }
}

Describe "Invoke-ProcessVariableSubstitution" {
    
    It "replaces simple variable placeholders" {
        $content = "Profile: {{profile}}, Version: {{version}}"
        $variables = @{ profile = "default"; version = "1.0.0" }
        $result = Invoke-ProcessVariableSubstitution -Content $content -Variables $variables
        $result | Should Be "Profile: default, Version: 1.0.0"
    }
    
    It "does not substitute boolean variables" {
        $content = "Should have: {{warp_commands}}"
        $variables = @{ warp_commands = $true }
        $result = Invoke-ProcessVariableSubstitution -Content $content -Variables $variables
        $result.Contains("{{warp_commands}}") | Should Be $true
    }
    
    It "handles multiple occurrences of same variable" {
        $content = "First: {{name}}, Second: {{name}}"
        $variables = @{ name = "dotbot" }
        $result = Invoke-ProcessVariableSubstitution -Content $content -Variables $variables
        $result | Should Be "First: dotbot, Second: dotbot"
    }
    
    It "handles special regex characters in values" {
        $content = "Path: {{path}}"
        $variables = @{ path = "C:\Users\test\.bot\*" }
        $result = Invoke-ProcessVariableSubstitution -Content $content -Variables $variables
        $result.Contains("C:\Users\test\.bot") | Should Be $true
    }
}

Describe "Invoke-ProcessTemplate" {
    
    It "processes conditionals, variables in correct order" {
        $content = @"
Profile: {{profile}}
{{IF warp_commands}}
Warp is enabled
{{ENDIF warp_commands}}
"@
        $variables = @{ warp_commands = $true; profile = "rails" }
        $result = Invoke-ProcessTemplate -Content $content -Variables $variables -Profile "default" -BaseDir "C:\temp"
        $result.Contains("Profile: rails") | Should Be $true
        $result.Contains("Warp is enabled") | Should Be $true
    }
    
    It "handles complex scenario with multiple conditions" {
        $content = @"
# Project Setup

Profile: {{profile}}

{{IF warp_commands}}
## Warp Commands
Warp slash commands are available.
{{ENDIF warp_commands}}

{{UNLESS standards_as_warp_rules}}
## Standards Files
Standards are stored as markdown files.
{{ENDUNLESS standards_as_warp_rules}}

Version: {{version}}
"@
        $variables = @{ 
            warp_commands = $true
            standards_as_warp_rules = $false
            profile = "default"
            version = "1.0.0"
        }
        $result = Invoke-ProcessTemplate -Content $content -Variables $variables -Profile "default" -BaseDir "C:\temp"
        $result.Contains("Profile: default") | Should Be $true
        $result.Contains("Warp Commands") | Should Be $true
        $result.Contains("Standards Files") | Should Be $true
        $result.Contains("Version: 1.0.0") | Should Be $true
    }
}
