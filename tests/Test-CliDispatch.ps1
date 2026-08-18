#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 2: Tests for the bin/dotbot.ps1 dispatcher — flag binding and exit
    codes (issue #684).
.DESCRIPTION
    Exercises the three failure modes reported in #684:
      - kebab-case flags on multi-word parameters must bind (--older-than,
        --poll-interval-ms, --bot-root) instead of raising a raw
        ParameterBindingException,
      - unrecognised flags must be rejected, not silently dropped (doctor.ps1
        and tasks-run.ps1 are advanced scripts),
      - every error path must exit non-zero: unknown verb, missing required
        argument, binding failure, ValidateSet/ValidateRange violation.
    Also pins the help text against the dispatcher's real verb list and the
    studio path, and guards the compatibility spelling --mothership-key.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$dotbotDir = Get-DotbotInstallDir

Write-Host ""
Write-Host "-----------------------------------------------------------" -ForegroundColor Blue
Write-Host "  Layer 2: CLI Dispatch Tests (#684)" -ForegroundColor Blue
Write-Host "-----------------------------------------------------------" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

$dotbotCli = Join-Path $dotbotDir 'bin/dotbot.ps1'
$doctorScript = Join-Path $dotbotDir 'src/cli/doctor.ps1'

function Invoke-Cli {
    param(
        [Parameter(Mandatory)] [string]$Script,
        [Parameter(Mandatory)] [string]$WorkDir,
        [string[]]$CliArgs = @()
    )
    Push-Location $WorkDir
    try {
        $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File $Script @CliArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    return @{ Output = ($out | Out-String); Code = $code }
}

$proj = $null

try {
    Assert-True -Name "bin/dotbot.ps1 exists on disk" -Condition (Test-Path $dotbotCli) -Message "Not found: $dotbotCli"
    Assert-ValidPowerShellAst -Name "bin/dotbot.ps1 parses without syntax errors" -Path $dotbotCli

    $proj = New-TestProject

    $r = Invoke-Cli -Script $dotbotCli -WorkDir $proj -CliArgs @('prune-branches', '--older-than', '90d', '--dry-run')
    Assert-Equal -Name "prune-branches --older-than binds" -Expected 0 -Actual $r.Code -Message $r.Output
    Assert-True -Name "prune-branches --older-than is not a binding error" `
        -Condition ($r.Output -notmatch 'parameter cannot be found') -Message $r.Output
    Assert-True -Name "prune-branches --older-than reaches the reported window" `
        -Condition ($r.Output -match '90d') -Message $r.Output

    $r = Invoke-Cli -Script $dotbotCli -WorkDir $proj -CliArgs @('logs', '--poll-interval-ms', '500', '--tail', '2')
    Assert-True -Name "logs --poll-interval-ms binds" `
        -Condition ($r.Output -notmatch 'parameter cannot be found') -Message $r.Output

    $cliAst = [System.Management.Automation.Language.Parser]::ParseFile($dotbotCli, [ref]$null, [ref]$null)
    $normaliserAst = $cliAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'ConvertTo-DotbotParameterName'
    }, $true)
    Assert-True -Name "dispatcher defines ConvertTo-DotbotParameterName" -Condition ($null -ne $normaliserAst) `
        -Message "The kebab-to-PascalCase normaliser is what makes every multi-word flag bindable"

    if ($normaliserAst) {
        . ([scriptblock]::Create($normaliserAst.Extent.Text))

        Assert-Equal -Name "normaliser maps --older-than to OlderThan" -Expected 'OlderThan' -Actual (ConvertTo-DotbotParameterName 'older-than')
        Assert-Equal -Name "normaliser maps --poll-interval-ms to PollIntervalMs" -Expected 'PollIntervalMs' -Actual (ConvertTo-DotbotParameterName 'poll-interval-ms')
        Assert-Equal -Name "normaliser leaves an unhyphenated flag untouched" -Expected 'json' -Actual (ConvertTo-DotbotParameterName 'json')

        $serveCommand = Get-Command (Join-Path $dotbotDir 'src/cli/serve.ps1')
        $serveNames = @($serveCommand.Parameters.Keys) + @($serveCommand.Parameters.Values | ForEach-Object { $_.Aliases })
        foreach ($spelling in @('mothership-key', 'mothership-api-key')) {
            $normalised = ConvertTo-DotbotParameterName $spelling
            Assert-True -Name "serve binds the dispatcher's normalisation of --$spelling ($normalised)" `
                -Condition ($serveNames -contains $normalised) `
                -Message "serve.ps1 exposes: $($serveNames -join ', ')"
        }
    }

    $missingBot = Join-Path $proj 'no-such-bot'

    $direct = Invoke-Cli -Script $doctorScript -WorkDir $proj -CliArgs @('-BotRoot', $missingBot)
    $kebab = Invoke-Cli -Script $dotbotCli -WorkDir $proj -CliArgs @('doctor', '--bot-root', $missingBot)

    Assert-True -Name "doctor -BotRoot on a missing .bot exits non-zero (sanity)" `
        -Condition ($direct.Code -ne 0) -Message $direct.Output
    Assert-Equal -Name "doctor --bot-root exit matches -BotRoot (flag is honoured, not dropped)" `
        -Expected $direct.Code -Actual $kebab.Code -Message $kebab.Output
    Assert-True -Name "doctor --bot-root reports the directory it was given" `
        -Condition ($kebab.Output -match '\.bot directory not found') -Message $kebab.Output

    $r = Invoke-Cli -Script $dotbotCli -WorkDir $proj -CliArgs @('tasks', 'run', '--json')
    Assert-True -Name "tasks run rejects an unknown flag instead of ignoring it" `
        -Condition ($r.Code -ne 0) -Message $r.Output

    $errorCases = @(
        @{ Name = 'unknown verb';                Args = @('bogus-verb') }
        @{ Name = 'run without a workflow name'; Args = @('run') }
        @{ Name = 'workflow run without a name'; Args = @('workflow', 'run') }
        @{ Name = 'run with a mistyped flag';    Args = @('run', 'smoke-test', '--wathc') }
        @{ Name = 'logs --tail below range';     Args = @('logs', '--tail', '0') }
        @{ Name = 'prune-branches bad --match';  Args = @('prune-branches', '--match', 'bogus') }
        @{ Name = 'install with a bad subcommand'; Args = @('install', 'content') }
        @{ Name = 'tasks without a subcommand';  Args = @('tasks') }
        @{ Name = 'registry without a subcommand'; Args = @('registry') }
    )
    foreach ($case in $errorCases) {
        $r = Invoke-Cli -Script $dotbotCli -WorkDir $proj -CliArgs $case.Args
        Assert-True -Name "exit non-zero: $($case.Name)" -Condition ($r.Code -ne 0) -Message $r.Output
        Assert-True -Name "themed (no raw stack frame): $($case.Name)" `
            -Condition ($r.Output -notmatch 'dotbot\.ps1:\d+') -Message $r.Output
    }

    $r = Invoke-Cli -Script $dotbotCli -WorkDir $proj -CliArgs @('help')
    Assert-Equal -Name "help exits 0" -Expected 0 -Actual $r.Code -Message $r.Output

    Assert-True -Name "help advertises 'workflow scaffold'" `
        -Condition ($r.Output -match 'workflow scaffold') -Message $r.Output
    Assert-True -Name "help no longer advertises the non-existent 'install content'" `
        -Condition ($r.Output -notmatch 'install content') -Message $r.Output

    $cliText = Get-Content $dotbotCli -Raw
    Assert-True -Name "studio verb resolves src/studio-ui" `
        -Condition ($cliText -match '\$studioDir = Join-Path \$DotbotBase "src" "studio-ui"') `
        -Message "The studio directory moved to src/studio-ui (see tests/Test-StudioAPI.ps1)"
    Assert-True -Name "studio verb only calls theme helpers imported by the dispatcher" `
        -Condition ($cliText -notmatch 'Write-Status ') `
        -Message "Write-Status lives in Dotbot.Theme, which bin/dotbot.ps1 does not import"
}
finally {
    if ($proj) { Remove-TestProject -Path $proj }
}

$ok = Write-TestSummary -LayerName "Layer 2: CLI Dispatch (#684)"
if ($ok) { exit 0 } else { exit 1 }
