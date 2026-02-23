@echo off
set "SCRIPT=%~dp0\install.ps1"

rem Prefer PowerShell Core (pwsh) if installed, otherwise Windows PowerShell
where pwsh >nul 2>&1
if %ERRORLEVEL%==0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
)