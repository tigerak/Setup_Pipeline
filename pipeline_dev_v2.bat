@echo off
setlocal enabledelayedexpansion

set /p setupVer="Setup Pipeline version (example: 260519): "
set "SCRIPT_PATH=%~dp0pipeline_dev_v2.ps1"

echo.
echo Setup Pipeline Ver: !setupVer!

if not exist "!SCRIPT_PATH!" (
    echo [ERROR] Script not found: !SCRIPT_PATH!
    exit /b 1
)

echo [RUN] Starting !SCRIPT_PATH! as administrator...
powershell.exe -NoProfile -ExecutionPolicy Bypass ^
  -Command "Start-Process powershell.exe -ArgumentList '-NoExit', '-NoProfile', '-ExecutionPolicy Bypass', '-File', '!SCRIPT_PATH!', '-ScriptVer', '!setupVer!' -Verb RunAs"

endlocal
exit /b %errorlevel%
