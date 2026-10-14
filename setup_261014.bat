@echo off
setlocal EnableExtensions
cd /d "%~dp0"

REM ============================================================================
REM 관리자 권한 확인
REM ============================================================================

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] This script requires Administrator privileges.
    echo Please run as Administrator.
    pause
    exit /b 1
)

set "SCRIPT_DIR=%~dp0"
set "SRC_DIR=%SCRIPT_DIR%src"
set "LOCAL_CONFIG_PS1=%SCRIPT_DIR%local_config.ps1"
set "PIPELINE_ENTRY_PS1=%SRC_DIR%\pipeline_entry.ps1"

if not exist "%PIPELINE_ENTRY_PS1%" (
    echo [ERROR] Script not found: "%PIPELINE_ENTRY_PS1%"
    pause
    exit /b 1
)

REM ============================================================================
REM pipeline_entry.ps1 실행
REM ============================================================================
REM 배치 콘솔은 즉시 종료하고, 설치 GUI만 별도 프로세스로 띄운다.
REM 설치 창은 종료 시 자동으로 닫히지 않고 사용자가 직접 닫을 때까지 유지한다.
start "" /b powershell.exe -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File "%PIPELINE_ENTRY_PS1%"

exit /b 0