@echo off
setlocal EnableExtensions

set "SCRIPT_DIR=%~dp0"
set "PS1_PATH=%SCRIPT_DIR%src\pipeline_entry_v4.ps1"

if not exist "%PS1_PATH%" (
    echo [ERROR] Script not found: "%PS1_PATH%"
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process PowerShell -Verb RunAs -WindowStyle Hidden -ArgumentList '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""%PS1_PATH%""'"
if errorlevel 1 (
    echo [ERROR] Failed to request administrator permission.
    pause
    exit /b 1
)

exit /b 0