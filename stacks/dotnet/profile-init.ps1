if (Get-Command dotnet -ErrorAction SilentlyContinue) {
    if (-not (Test-Path (Join-Path $ProjectDir ".gitignore"))) {
        dotnet new gitignore --output $ProjectDir 2>$null | Out-Null
        Write-Success "Generated .NET .gitignore"
    } else {
        Write-DotbotWarning ".gitignore already exists -- skipping dotnet gitignore"
    }
}
