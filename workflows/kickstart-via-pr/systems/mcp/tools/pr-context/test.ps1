# Test pr-context tool with mocked GitHub data.

. "$PSScriptRoot\script.ps1"

Write-Host "Testing pr-context..." -ForegroundColor Cyan

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dotbot-pr-context-test-" + [guid]::NewGuid().ToString("N"))
New-Item -Path $testRoot -ItemType Directory -Force | Out-Null
$global:DotbotProjectRoot = $testRoot

try {
    Set-Content -Path (Join-Path $testRoot ".env.local") -Value "GITHUB_TOKEN=test-token" -Encoding UTF8

    $result = & {
        function Invoke-RestMethod {
            param(
                [string]$Method = "Get",
                [string]$Uri,
                $Headers
            )

            if ($Uri -eq "https://api.github.com/repos/acme/widgets/pulls/1") {
                return [pscustomobject]@{
                    number = 1
                    title = "Sample PR"
                    body = "Fixes #9"
                    html_url = "https://github.com/acme/widgets/pull/1"
                    state = "open"
                    user = [pscustomobject]@{ login = "octocat" }
                    head = [pscustomobject]@{ ref = "feature/sample" }
                    base = [pscustomobject]@{ ref = "main" }
                }
            }

            if ($Uri -eq "https://api.github.com/repos/acme/widgets/pulls/1/files?per_page=100&page=1") {
                return @([pscustomobject]@{ filename = "src/Sample.cs"; status = "modified" })
            }

            if ($Uri -eq "https://api.github.com/repos/acme/widgets/pulls/1/files?per_page=100&page=2") {
                return @()
            }

            if ($Uri -eq "https://api.github.com/repos/acme/widgets/issues/9") {
                return [pscustomobject]@{
                    number = 9
                    title = "Linked issue"
                    state = "open"
                    html_url = "https://github.com/acme/widgets/issues/9"
                }
            }

            throw "Unexpected URI: $Uri"
        }

        Invoke-PrContext -Arguments @{ pr_url = "https://github.com/acme/widgets/pull/1" }
    }

    if ($result.provider -eq "github" -and $result.pull_request_id -eq 1 -and @($result.changed_files).Count -eq 1) {
        Write-Host "  PASS: GitHub PR context returned expected shape" -ForegroundColor Green
    } else {
        Write-Host "  FAIL: Unexpected GitHub PR context result" -ForegroundColor Red
    }
} finally {
    Remove-Item -Path $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

