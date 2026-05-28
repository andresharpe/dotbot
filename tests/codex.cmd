@echo off
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0mock-codex.ps1" %*
