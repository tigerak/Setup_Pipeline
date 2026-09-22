@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
set "PS1_PATH=%SCRIPT_DIR%run_requirements_validation.ps1"
set "LOG_DIR=%SCRIPT_DIR%logs"

if not exist "%PS1_PATH%" (
    echo [ERROR] Script not found: "%PS1_PATH%"
    pause
    exit /b 1
)

if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"

title Requirements Validation Launcher

:MENU
echo.
echo ============================================================
echo Requirements Validation Launcher
echo ============================================================
echo.
echo [1] CU11 validate only
echo [2] CU11 sync lock only
echo [3] CU12 validate only
echo [4] CU12 sync lock only
echo [5] ALL validate only
echo [6] ALL sync lock only
echo [7] Custom options
echo [Q] Quit
echo.
call :ASK_CHOICE "Select option [1-7/Q]: " "1 2 3 4 5 6 7 Q" MENU_CHOICE

if /i "%MENU_CHOICE%"=="Q" exit /b 0
if "%MENU_CHOICE%"=="7" goto CUSTOM
if "%MENU_CHOICE%"=="6" call :SET_PRESET all sync
if "%MENU_CHOICE%"=="5" call :SET_PRESET all validate
if "%MENU_CHOICE%"=="4" call :SET_PRESET cu12 sync
if "%MENU_CHOICE%"=="3" call :SET_PRESET cu12 validate
if "%MENU_CHOICE%"=="2" call :SET_PRESET cu11 sync
if "%MENU_CHOICE%"=="1" call :SET_PRESET cu11 validate
goto ASK_OPTIONS

:CUSTOM
echo.
echo ============================================================
echo Custom Requirements Validation
echo ============================================================
echo.
set "TRACK="
set /p TRACK=Track ^(cu11^|cu12^|all, Enter=menu^): 
if /i "%TRACK%"=="" goto MENU
if /i not "%TRACK%"=="cu11" if /i not "%TRACK%"=="cu12" if /i not "%TRACK%"=="all" (
    echo [ERROR] Invalid track: %TRACK%
    pause
    goto MENU
)
call :NORMALIZE_TRACK

set "SYNC_LOCK=no"
set "RUN_MODE=validate"
call :ASK_MODE
goto ASK_OPTIONS

:ASK_OPTIONS
set "RUN_MODE_LABEL="
set "REMOVE_VALIDATION_ENV=no"
set "CLEAR_TEMP_CACHE=no"
set "CLEAR_APPROVED_WHEELHOUSE=no"
set "REMOVE_OFFLINE_ENV=no"
set "BUILD_TEMP_CACHE=no"
set "BUILD_APPROVED_WHEELHOUSE=no"
set "VERIFY_OFFLINE=no"
set "ENV_PREFIX=req"
set "PYTHON_VERSION=3.10"
set "WHEEL_OUTPUT_ROOT="
set "RUN_LOG_FILE="

if /i "%RUN_MODE%"=="validate" (
    set "RUN_MODE_LABEL=validate only"
) else (
    set "RUN_MODE_LABEL=sync lock only"
)

echo.
set /p ENV_PREFIX=Environment prefix [req]: 
if "%ENV_PREFIX%"=="" set "ENV_PREFIX=req"

set /p PYTHON_VERSION=Python version [3.10]: 
if "%PYTHON_VERSION%"=="" set "PYTHON_VERSION=3.10"

if not defined WHEEL_OUTPUT_ROOT set "WHEEL_OUTPUT_ROOT=requirements\wheelhouse"

if /i "%RUN_MODE%"=="sync" (
    set "SYNC_LOCK=yes"
    set "BUILD_APPROVED_WHEELHOUSE=yes"
    set "VERIFY_OFFLINE=yes"
    set "REMOVE_OFFLINE_ENV=yes"
    call :ASK_YES_NO_DEFAULT "Delete existing build environment before approved rebuild?" REMOVE_VALIDATION_ENV Y
    call :ASK_YES_NO_DEFAULT "Delete approved wheelhouse before rebuild?" CLEAR_APPROVED_WHEELHOUSE Y
    goto RUN
)

set "SYNC_LOCK=no"

call :ASK_YES_NO_DEFAULT "Delete existing validation environment before run?" REMOVE_VALIDATION_ENV Y

set "BUILD_TEMP_CACHE=yes"
call :ASK_YES_NO_DEFAULT "Delete temp wheel cache before manifest download?" CLEAR_TEMP_CACHE N

goto RUN

:RUN
set "PS1_ARGS=-ExecutionPolicy Bypass -File "%PS1_PATH%" -Track %TRACK% -EnvPrefix %ENV_PREFIX% -PythonVersion %PYTHON_VERSION%"

if /i "%SYNC_LOCK%"=="yes" set "PS1_ARGS=%PS1_ARGS% -SyncLock"
if /i "%REMOVE_VALIDATION_ENV%"=="yes" set "PS1_ARGS=%PS1_ARGS% -RemoveValidationEnv"
if /i "%BUILD_TEMP_CACHE%"=="yes" (
    set "PS1_ARGS=%PS1_ARGS% -BuildTempWheelCache"
    if /i "%CLEAR_TEMP_CACHE%"=="yes" set "PS1_ARGS=%PS1_ARGS% -ClearTempWheelCache"
    if not "%WHEEL_OUTPUT_ROOT%"=="" set "PS1_ARGS=%PS1_ARGS% -WheelOutputRoot %WHEEL_OUTPUT_ROOT%"
)
if /i "%BUILD_APPROVED_WHEELHOUSE%"=="yes" (
    set "PS1_ARGS=%PS1_ARGS% -BuildApprovedWheelhouse"
    if /i "%CLEAR_TEMP_CACHE%"=="yes" set "PS1_ARGS=%PS1_ARGS% -ClearTempWheelCache"
    if /i "%CLEAR_APPROVED_WHEELHOUSE%"=="yes" set "PS1_ARGS=%PS1_ARGS% -ClearApprovedWheelhouse"
    if /i "%VERIFY_OFFLINE%"=="yes" set "PS1_ARGS=%PS1_ARGS% -VerifyOfflineInstall"
    if /i "%REMOVE_OFFLINE_ENV%"=="yes" set "PS1_ARGS=%PS1_ARGS% -RemoveOfflineEnv"
    if not "%WHEEL_OUTPUT_ROOT%"=="" set "PS1_ARGS=%PS1_ARGS% -WheelOutputRoot %WHEEL_OUTPUT_ROOT%"
)

echo.
echo ============================================================
echo Execute Requirements Validation
echo ============================================================
echo.
echo Track           : %TRACK%
echo Mode            : %RUN_MODE_LABEL%
echo Sync lock       : %SYNC_LOCK%
echo Env prefix      : %ENV_PREFIX%
echo Python version  : %PYTHON_VERSION%
echo Remove env      : %REMOVE_VALIDATION_ENV%
echo API validation  : on
echo CUDA validation : on
echo TensorRT check  : off
echo Build temp cache: %BUILD_TEMP_CACHE%
echo Clear temp cache: %CLEAR_TEMP_CACHE%
echo Build approved  : %BUILD_APPROVED_WHEELHOUSE%
if /i "%BUILD_APPROVED_WHEELHOUSE%"=="yes" echo Clear approved  : %CLEAR_APPROVED_WHEELHOUSE%
echo Verify offline  : %VERIFY_OFFLINE%
if /i "%VERIFY_OFFLINE%"=="yes" echo Remove offline  : %REMOVE_OFFLINE_ENV%
echo Wheel root      : %WHEEL_OUTPUT_ROOT%
echo.
echo Command: powershell %PS1_ARGS%
echo.
call :ASK_CHOICE "Run this command? [Y/N]: " "Y N" RUN_CONFIRM
if /i "%RUN_CONFIRM%"=="N" goto MENU

call :MAKE_TIMESTAMP
set "RUN_LOG_FILE=%LOG_DIR%\launcher_%TRACK%_!STAMP!.log"
(
    echo [%date% %time%] Requirements validation launcher started.
    echo Track=%TRACK%
    echo SyncLock=%SYNC_LOCK%
    echo EnvPrefix=%ENV_PREFIX%
    echo PythonVersion=%PYTHON_VERSION%
    echo RemoveValidationEnv=%REMOVE_VALIDATION_ENV%
    echo BuildTempWheelCache=%BUILD_TEMP_CACHE%
    echo ClearTempWheelCache=%CLEAR_TEMP_CACHE%
    echo BuildApprovedWheelhouse=%BUILD_APPROVED_WHEELHOUSE%
    echo ClearApprovedWheelhouse=%CLEAR_APPROVED_WHEELHOUSE%
    echo VerifyOfflineInstall=%VERIFY_OFFLINE%
    echo RemoveOfflineEnv=%REMOVE_OFFLINE_ENV%
    echo WheelOutputRoot=%WHEEL_OUTPUT_ROOT%
    echo Command=powershell %PS1_ARGS%
) > "%RUN_LOG_FILE%"

echo.
echo ============================================================
echo Running validation in console
echo ============================================================
echo.
echo Detailed validation output will be shown below.
echo Full PowerShell transcript log will be saved by the .ps1 script.
echo Launcher metadata log: "%RUN_LOG_FILE%"
echo.

powershell %PS1_ARGS%
set "EXIT_CODE=%errorlevel%"

(
    echo ExitCode=%EXIT_CODE%
    echo [%date% %time%] Requirements validation launcher finished.
) >> "%RUN_LOG_FILE%"

echo.
if "%EXIT_CODE%"=="0" (
    echo [OK] Validation completed successfully.
) else (
    echo [ERROR] Validation failed with exit code %EXIT_CODE%.
)
echo [INFO] Launcher log: "%RUN_LOG_FILE%"
echo [INFO] Returning to main menu.
echo.
goto MENU

:SET_PRESET
set "TRACK=%~1"
set "RUN_MODE=%~2"
exit /b 0

:ASK_MODE
echo.
echo [1] Validate only
echo [2] Sync lock only
call :ASK_CHOICE "Select run mode [1/2]: " "1 2" MODE_CHOICE
if "%MODE_CHOICE%"=="2" (
    set "RUN_MODE=sync"
) else (
    set "RUN_MODE=validate"
)
exit /b 0

:ASK_CHOICE
set "CHOICE_INPUT="
:ASK_CHOICE_LOOP
set /p CHOICE_INPUT=%~1
if /i "%CHOICE_INPUT%"=="" (
    echo [ERROR] Please enter one of: %~2
    goto ASK_CHOICE_LOOP
)
for %%V in (%~2) do (
    if /i "%CHOICE_INPUT%"=="%%V" (
        set "%~3=%%V"
        exit /b 0
    )
)
echo [ERROR] Please enter one of: %~2
goto ASK_CHOICE_LOOP
exit /b 0

:NORMALIZE_TRACK
if /i "%TRACK%"=="CU11" set "TRACK=cu11"
if /i "%TRACK%"=="CU12" set "TRACK=cu12"
if /i "%TRACK%"=="ALL" set "TRACK=all"
exit /b 0

:ASK_YES_NO_DEFAULT
set "ASK_INPUT="
:ASK_YES_NO_DEFAULT_LOOP
set /p ASK_INPUT=%~1 [Y/N] (default: %~3): 
if /i "%ASK_INPUT%"=="" set "ASK_INPUT=%~3"
if /i "%ASK_INPUT%"=="Y" (
    set "%~2=yes"
    exit /b 0
)
if /i "%ASK_INPUT%"=="N" (
    set "%~2=no"
    exit /b 0
)
echo [ERROR] Please enter Y or N.
goto ASK_YES_NO_DEFAULT_LOOP
exit /b 0

:MAKE_TIMESTAMP
set "STAMP=%date:~0,4%%date:~5,2%%date:~8,2%_%time:~0,2%%time:~3,2%%time:~6,2%"
set "STAMP=%STAMP: =0%"
exit /b 0