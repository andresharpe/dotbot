@echo off
REM dotbot - standalone PATH shim (Windows cmd).
REM
REM This is the only machine-wide dotbot artifact. It reads DOTBOT_HOME
REM and execs into that checkout's CLI. It contains no framework code.
REM
REM Per design decision D1: DOTBOT_HOME must be set explicitly. There is
REM no fallback to %USERPROFILE%\dotbot.

setlocal

if "%DOTBOT_HOME%"=="" (
  echo dotbot: DOTBOT_HOME is not set. 1>&2
  echo. 1>&2
  echo Set it to a dotbot checkout, then re-run. For example: 1>&2
  echo   set DOTBOT_HOME=%%USERPROFILE%%\code\dotbot 1>&2
  exit /b 1
)

if not exist "%DOTBOT_HOME%\bin\dotbot.ps1" (
  echo dotbot: DOTBOT_HOME='%DOTBOT_HOME%' does not look like a dotbot checkout ^(missing bin\dotbot.ps1^). 1>&2
  exit /b 1
)

pwsh -NoProfile -File "%DOTBOT_HOME%\bin\dotbot.ps1" %*
exit /b %ERRORLEVEL%
