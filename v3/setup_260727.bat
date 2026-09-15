@echo off
setlocal EnableExtensions

set "SCRIPT_DIR=%~dp0"
set "PS1_PATH=%SCRIPT_DIR%pipeline_gui_v3.ps1"

if not exist "%PS1_PATH%" (
    echo [ERROR] Script not found: "%PS1_PATH%"
    pause
    exit /b 1
)

:: 관리자 권한으로 실행하되, PowerShell 콘솔 창은 숨긴다 (-WindowStyle Hidden).
:: GUI는 별도로 표시되므로 콘솔의 텍스트 진행률 표시가 보이지 않는다.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process PowerShell -Verb RunAs -WindowStyle Hidden -ArgumentList '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""%PS1_PATH%""'"
if errorlevel 1 (
    echo [ERROR] Failed to request administrator permission.
    pause
    exit /b 1
)

exit /b 0