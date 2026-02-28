<#
.SYNOPSIS
    Loads .env.local into a $dotbotEnv hashtable.
.DESCRIPTION
    Dot-source this file to get $dotbotEnv (hashtable of key=value pairs)
    and $dotbotHeaders (X-Api-Key header) ready to use.
#>

$_envFile = Join-Path $PSScriptRoot '..\.env.local'
if (-not (Test-Path $_envFile)) {
    Write-Host "Missing .env.local — copy .env.example to .env.local and set values" -ForegroundColor Red
    throw "File not found: $_envFile"
}

$dotbotEnv = @{}
Get-Content $_envFile | Where-Object { $_ -match '^\s*[^#].*=' } | ForEach-Object {
    $key, $val = $_ -split '=', 2
    $dotbotEnv[$key.Trim()] = $val.Trim()
}

if (-not $dotbotEnv['DOTBOT_QNA_API_KEY']) {
    throw "DOTBOT_QNA_API_KEY not set in .env.local"
}

$dotbotHeaders = @{ 'X-Api-Key' = $dotbotEnv['DOTBOT_QNA_API_KEY'] }
