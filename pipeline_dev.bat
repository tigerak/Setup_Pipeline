@echo off
setlocal enabledelayedexpansion
:: EUC-KR (cp949) 인코딩

set /p setupVer="Setup Pipeline 버전을 입력하시오. (예: 260519): "
set "SCRIPT_PATH=%~dp0pipeline_dev.ps1"

echo.
echo Setup Pipeline Ver: !setupVer!

if not exist "!SCRIPT_PATH!" (
    echo [오류] 스크립트를 찾을 수 없습니다: !SCRIPT_PATH!
    exit /b 1
)

echo [진행] !SCRIPT_PATH! 실행 중...
powershell.exe -NoProfile -ExecutionPolicy Bypass ^
  -Command "Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy Bypass', '-File', '!SCRIPT_PATH!', '-ScriptVer', '!setupVer!' -Verb RunAs"

endlocal
exit /b %errorlevel%
:: pause