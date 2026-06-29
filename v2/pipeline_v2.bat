@echo off
setlocal enabledelayedexpansion
:: EUC-KR (cp949) ���ڵ�

set /p setupVer="Setup Pipeline ������ �Է��Ͻÿ�. (��: 260519): "
set "SCRIPT_PATH=%~dp0pipeline_v2.ps1"

echo.
echo Setup Pipeline Ver: !setupVer!

if not exist "!SCRIPT_PATH!" (
    echo [����] ��ũ��Ʈ�� ã�� �� �����ϴ�: !SCRIPT_PATH!
    exit /b 1
)

echo [����] !SCRIPT_PATH! ���� ��...
powershell.exe -NoProfile -ExecutionPolicy Bypass ^
  -Command "Start-Process powershell.exe -ArgumentList '-NoExit', '-NoProfile', '-ExecutionPolicy Bypass', '-File', '!SCRIPT_PATH!', '-ScriptVer', '!setupVer!' -Verb RunAs"

endlocal
exit /b %errorlevel%
:: pause