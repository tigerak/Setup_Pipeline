@echo off
setlocal enabledelayedexpansion
:: EUC-KR (cp949) 인코딩

set "SCRIPT_PATH=%~dp0pipeline_v1.ps1"

if not exist "!SCRIPT_PATH!" (
    echo [오류] 스크립트를 찾을 수 없습니다: !SCRIPT_PATH!
    exit /b 1
)

echo [진행] !SCRIPT_PATH! 실행 중...
powershell.exe -NoProfile -ExecutionPolicy Bypass ^
  -Command "Start-Process powershell.exe -ArgumentList '-NoExit', '-NoProfile', '-ExecutionPolicy Bypass', '-File', '!SCRIPT_PATH!' -Verb RunAs"

endlocal
exit /b %errorlevel%