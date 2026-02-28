@echo off
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0mock-gemini.ps1" %*
