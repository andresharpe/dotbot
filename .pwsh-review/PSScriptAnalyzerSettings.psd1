@{
    # PSScriptAnalyzer settings for pwsh-code-review on dotbot.
    # Merged from the bootstrap template + dotbot's project-level
    # PSScriptAnalyzerSettings.psd1 at repo root. Project-specific overrides
    # go in this file directly; the plugin never modifies it once placed in
    # .pwsh-review/.

    Severity     = @('Error', 'Warning', 'Information')

    IncludeRules = @('*')

    ExcludeRules = @(
        # --- Inherited from project-root PSScriptAnalyzerSettings.psd1 ---

        'PSAvoidUsingWriteHost'
        # OK for CLI tooling and theme helpers. The dotbot output-hygiene rule
        # in standards.md handles this with project context (banned in framework
        # code, allowed in scripts that go through theme helpers).

        'PSUseShouldProcessForStateChangingFunctions'
        # Often false-positives on internal helpers and short scripts.

        'PSAvoidUsingPositionalParameters'
        # Too noisy for existing code.

        'PSUseBOMForUnicodeEncodedFile'
        # BOM-less UTF-8 is intentional for cross-platform tooling.

        'PSAvoidGlobalVars'
        # $global:DotbotProjectRoot is architectural.

        'PSAvoidAssignmentToAutomaticVariable'
        # $event used intentionally in stream processing.

        'PSReviewUnusedParameter'
        # Some params reserved for future use.

        'PSUseDeclaredVarsMoreThanAssignments'
        # Variables used in dynamic scopes.

        # --- From the bootstrap template ---

        'PSUseToExportFieldsInManifest'
        # Checked by the conventions agent with project context.
    )

    Rules = @{
        PSAvoidUsingEmptyCatchBlock = @{
            Enable = $true
        }

        PSPlaceOpenBrace = @{
            Enable             = $true
            OnSameLine         = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
        }

        PSPlaceCloseBrace = @{
            Enable             = $true
            NoEmptyLineBefore  = $false
            IgnoreOneLineBlock = $true
            NewLineAfter       = $true
        }

        PSUseConsistentIndentation = @{
            Enable              = $true
            Kind                = 'space'
            IndentationSize     = 4
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
        }

        PSUseConsistentWhitespace = @{
            Enable                                  = $true
            CheckInnerBrace                         = $true
            CheckOpenBrace                          = $true
            CheckOpenParen                          = $true
            CheckOperator                           = $true
            CheckPipe                               = $true
            CheckPipeForRedundantWhitespace         = $false
            CheckSeparator                          = $true
            CheckParameter                          = $false
            IgnoreAssignmentOperatorInsideHashTable = $true
        }

        PSAlignAssignmentStatement = @{
            Enable         = $true
            CheckHashtable = $true
        }

        PSAvoidLongLines = @{
            Enable            = $true
            MaximumLineLength = 140
        }

        PSAvoidSemicolonsAsLineTerminators = @{
            Enable = $true
        }

        # Compatibility: dotbot targets pwsh 7.0+ (manifest) and 7.4 (CI).
        # Use 7.4 as the floor for the analyzer since CI runs 7.4.
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('7.4')
        }

        PSUseCompatibleCmdlets = @{
            Enable        = $true
            compatibility = @(
                'core-7.4-windows',
                'core-7.4-linux',
                'core-7.4-macos'
            )
        }

        PSUseCompatibleCommands = @{
            Enable         = $true
            TargetProfiles = @(
                'core-7.4-windows-framework',
                'core-7.4-linux',
                'core-7.4-macos'
            )
        }

        PSUseCompatibleTypes = @{
            Enable         = $true
            TargetProfiles = @(
                'core-7.4-windows-framework',
                'core-7.4-linux',
                'core-7.4-macos'
            )
        }
    }
}
