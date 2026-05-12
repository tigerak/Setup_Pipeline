@echo off

set "SCRIPT_PATH=%~dp0pipeline_260511.ps1"

echo 관리자 권한으로 설치를 시작합니다...

powershell.exe -Command "Start-Process powershell.exe -ArgumentList '-NoProfile -NoExit -ExecutionPolicy  Bypass -File ""%SCRIPT_PATH%""' -Verb RunAs"

exit