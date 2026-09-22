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
set "SETUP_CONFIG_PS1=%SRC_DIR%\setup_config.ps1"
set "PIPELINE_ENTRY_PS1=%SRC_DIR%\pipeline_entry.ps1"

if not exist "%SETUP_CONFIG_PS1%" (
    echo [ERROR] Script not found: "%SETUP_CONFIG_PS1%"
    pause
    exit /b 1
)

if not exist "%PIPELINE_ENTRY_PS1%" (
    echo [ERROR] Script not found: "%PIPELINE_ENTRY_PS1%"
    pause
    exit /b 1
)

REM ============================================================================
REM 사용자 설정 입력 및 GUI 자동 시작
REM ============================================================================

powershell -NoProfile -ExecutionPolicy Bypass -NoExit -Command "& '%SETUP_CONFIG_PS1%' -PipelineEntry '%PIPELINE_ENTRY_PS1%'"

exit /b 0