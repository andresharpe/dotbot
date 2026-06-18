@echo off
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0mock-opencode.ps1" %*
