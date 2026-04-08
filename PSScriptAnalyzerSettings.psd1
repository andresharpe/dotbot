@{
    Severity = @('Error', 'Warning')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost'           # Intentional for CLI output
        'PSUseShouldProcessForStateChangingFunctions'  # Not applicable for scripts
        'PSAvoidUsingPositionalParameters' # Too noisy for existing code
        'PSUseBOMForUnicodeEncodedFile'   # BOM-less UTF-8 is intentional for cross-platform
        'PSAvoidGlobalVars'              # $global:DotbotProjectRoot is architectural
        'PSAvoidAssignmentToAutomaticVariable' # $event used intentionally in stream processing
        'PSReviewUnusedParameter'        # Some params reserved for future use
        'PSUseDeclaredVarsMoreThanAssignments' # Variables used in dynamic scopes
    )
    Rules = @{
        PSAvoidUsingEmptyCatchBlock = @{
            Enable = $true
        }
    }
}
