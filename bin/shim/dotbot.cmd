@echo off
REM dotbot - standalone PATH shim (Windows cmd).
REM
REM This is the only machine-wide dotbot artifact. It prefers a project-local
REM .bot\vendor\dotbot checkout when present, otherwise reads DOTBOT_HOME and
REM execs into that checkout's CLI. It contains no framework code.
REM
REM DOTBOT_HOME must be set explicitly unless the current directory is inside
REM a project that vendors dotbot under .bot\vendor\dotbot.

setlocal

set "SEARCH_DIR=%CD%"

:find_vendored_dotbot
if exist "%SEARCH_DIR%\.bot\" (
  if exist "%SEARCH_DIR%\.bot\vendor\dotbot\bin\dotbot.ps1" (
    if exist "%SEARCH_DIR%\.bot\vendor\dotbot\content\workspace-template\" (
      if not "%DOTBOT_HOME%"=="" set "DOTBOT_MACHINE_HOME=%DOTBOT_HOME%"
      set "DOTBOT_HOME=%SEARCH_DIR%\.bot\vendor\dotbot"
      goto dotbot_home_resolved
    )
  )
  goto dotbot_home_resolved
)

if exist "%SEARCH_DIR%\.git" goto dotbot_home_resolved

for %%I in ("%SEARCH_DIR%\..") do set "PARENT_DIR=%%~fI"
if "%PARENT_DIR%"=="%SEARCH_DIR%" goto dotbot_home_resolved
set "SEARCH_DIR=%PARENT_DIR%"
goto find_vendored_dotbot

:dotbot_home_resolved
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
