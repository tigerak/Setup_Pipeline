# =========================================================================
# 환경 배포 자동화 스크립트 (Windows native / Offline)
# 대상: Miniconda 310, Conda 가상 환경(.zip), TensorRT 8.5.3.1(.zip)
# =========================================================================

# EUC-KR로 저장

### 배포 모드 설정 ###
$DebugMode = $true

### 환경 변수 및 설정값 정의 ###
# 스크립트 실행 경로가 설치 소스 기준점.
$sourcePath = $PSScriptRoot
# Cuda Toolkit Version 설정
$targetCudaVersion = "11.8"
# Miniconda 설정
$condaDest = "C:\ProgramData\miniconda3"
# TensorRT 설정
$trtDest = "D:\visionAI\TensorRT-8.5.3.1"
# Python 가상 환경 설정
$envName = "tabtest_new"

### 설치 파일명 설정 ###
$condaExeName = "Miniconda3-py310_24.9.2-0-Windows-x86_64.exe"
$trtZipFile = "TensorRT-8.5.3.1.zip"
$envZipFile = "tabtest_new.zip"

### [PRE-CHECK] 종속성 검증 ###
Write-Host "#============================================================#" -ForegroundColor Cyan
Write-Host "# 환경 배포 자동화 과정 시작                                    #" -ForegroundColor Cyan
Write-Host "#============================================================#" -ForegroundColor Cyan
Write-Host ""
Write-Host "사전 점검: 시스템 환경 추적 중..." -ForegroundColor Yellow

# 사전 점검 1: NVIDIA Driver 설치 여부 및 버전 추출
$nvidiaSmi = Get-Command "nvidia-smi" -ErrorAction SilentlyContinue
if ($nvidiaSmi) {
    $driverVer = (nvidia-smi --query-gpu=driver_version --format=csv,noheader) -join ", "
    Write-Host "    [성공] NVIDIA Driver 확인 (설치 버전: $driverVer)"
} else {
    Write-Host "    [실패] NVIDIA Driver를 확인할 수 없습니다. (nvidia-smi 실패)" -ForegroundColor Red
    exit
}

# 사전 점검 2: CUDA 설치 여부 및 버전 추출
$nvccCommend = Get-Command "nvcc" -ErrorAction SilentlyContinue
if ($nvccCommend) {
    # 시스템에 등록된 nvcc.exe 경로 추출
    $nvccPath = $nvccCommend.Source
    # nvcc --version에서 버전 숫자만 추출
    $cudaVerString = (& $nvccPath --version | Select-String "release").ToString()
    $cudaVerNum = [regex]::Match($cudaVerString, "release (\d+\.\d+)").Groups[1].Value

    # target Cuda Version 아니면 에러 발생
    if ($cudaVerNum -eq $targetCudaVersion) {
        Write-Host "    [성공] CUDA Toolkit 확인 (설치 버전: $cudaVerNum)"
    } else {
        Write-Host "    [실패] 설치된 CUDA Toolkit 버전이 $cudaVerNum 입니다. (설치 요구 사항: $targetCudaVersion)" -ForegroundColor Red
        exit
    }
    # nvcc의 bin 경로 추적
    $cudaBinPath = Split-Path -Parent $nvccPath

} else {
    Write-Host "    [실패] 시스템 환경 변수에서 CUDA(nvcc)를 찾을 수 없음. CUDA Toolkit이 설치되지 않음." -ForegroundColor Red
    exit
}

# 사전 점검 3: cuda toolkit 에서 cudnn 및 zlib 탐지
$cudnnDll = "$cudaBinPath\cudnn64_8.dll"
$zlibDll = "$cudaBinPath\zlibwapi.dll"

if (Test-Path $cudnnDll) {
    Write-Host "    [성공] cuDNN 엔진 파일 확인 완료."
} else {
    Write-Host "    [실패] $cudaBinPath 경로에 cuDNN이 없음." -ForegroundColor Red
    exit
}

if (Test-Path $zlibDll) {
    Write-Host "    [성공] 필수 의존성 파일(zlibwapi.dll) 확인 완료."
} else {
    Write-Host "    [실패] $cudaBinPath 경로에 zlibwapi.dll이 없음." -ForegroundColor Red
    # exit
}

# 사전 점검 4: miniconda3 설치 여부 및 버전 정보 확인
# 사전 점검 5: TensorRT 설치 여부 및 버전 정보 확인

### [USER CONFIRMATION] 사용자 최종 승인 ###
if ($DebugMode) {
    # 개발 모드: 터미널에서 텍스트로 확인
    Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host " [설치 경로 확인]"
    Write-Host " 1. 미니콘다 설치 경로: $condaDest"
    Write-Host " 2. TensorRT 설치 경로: $trtDest"
    Write-Host "------------------------------------------------------------" -ForegroundColor Cyan

    $ans = Read-Host "위 경로에 설치를 계속 진행하겠습니까? (Y/n)"
    if ($ans -notmatch "^[Yy]$") {
        Write-Host "    [취소] 설치를 취소하였습니다. 배포 프로세스 종료." -ForegroundColor Red
        exit
    }
    Write-Host "    [승인] 설치를 시작합니다." -ForegroundColor Green
} else {
    # 배포 모드(.exe): 윈도우 GUI 팝업창으로 확인
    Add-Type -AssemblyName System.Windows.Forms
    $msgText = "다음 경로에서 설치를 시작합니다. `n`n" +
               ">>> 미니콘다 설치 경로: $condaDest`n"
               ">>> TensorRT 설치 경로: $trtDest`n`n"
               "설치를 계속 하겠습니까?"
    $msgResult = [System.Windows.Forms.MessageBox]::Show($msgText, "설치 경로 확인", [System.Windows.Forms.MessageBox.Buttons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Information)

    if ($msgResult -eq "No") {
        Write-Host "[취소] 설치를 취소하였습니다. 배포 프로세스 종료." -ForegroundColor Red
        exit
    }
    Write-Host "[승인] 설치를 시작합니다." -ForegroundColor Green
}
Write-Host ""

### [STEP 1] 미니콘다 설치 ###
$condaExePath = "$condaDest\Scripts\conda.exe"

Write-Host "1 단계: 미니콘다 백그라운드 설치 중..." -ForegroundColor Yellow
if (Test-Path $condaExePath) {
    # conda.exe 가 있으면 설치된 것으로 간주. (설치 생략)
    Write-Host "    [알림] $condaDest 에 Mini-Conda가 이미 존재합니다. 설치 생략." -ForegroundColor Cyan
} else {
    # 미니콘다 설치 실행
    $installArgs = @(
        "/S",
        "/InstallationType=JustMe",
        # "/NoShortcuts=0",
        "/RegisterPython=0",
        "/D=$condaDest"
    )
    # NoShortcuts=1로 이미 설치한 경우: ../miniconda3/Scripts/conda.exe init powershell
    # 반드시 관리자 권한으로 실행
    Start-Process -FilePath "$sourcePath\pkgs\$condaExeName" -ArgumentList $installArgs -Wait
    # 설치 검증
    if (Test-Path $condaDest\Scripts) {
        Write-Host "    [성공] $condaDest 에 미니콘다 설치 완료." -ForegroundColor Green
    } else  {
        Write-Host "    [오류] 미니콘다 설치 실패." -ForegroundColor Red
        exit
    }
}
Write-Host ""

### [step 2] TensorRT Engine 배포 ###
Write-Host "2 단계: TensorRT 압축 해제 중..." -ForegroundColor Yellow
if (Test-Path "$trtDest\lib") {
    # lib 폴더가 존재하면 설치된 것으로 간주. (설치 생략)
    Write-Host "    [알림] $trtDest 에 TensorRT가 이미 존재합니다. 설치 생략." -ForegroundColor Cyan
} else {
    # 압축 해제 시작
    Write-Host "    [진행] $trtZipFile 압축 해제 중..." -ForegroundColor Yellow
    Expand-Archive -Path "$sourcePath\pkgs\$trtZipFile" -DestinationPath "$trtDest" -Force

    # 압축 해제 후 실제 결과물이 $trtDest에 잘 들어갔는지 검사
    if (Test-Path "$trtDest\lib") {
        Write-Host "    [성공] $trtDest 에 TensorRT 설치 완료." -ForegroundColor Green
    } else {
        # 
        Write-Host "    [경고] 설치가 완료됐으나 lib이 존재 하지 않음" -ForegroundColor Red
    }
}
Write-Host ""

### [step 3] Python 가상환경 추가 ###
Write-Host "3 단계: Python 가상환경($envName) 이식 중..." -ForegroundColor Yellow

$fullEnvPath = "$condaDest\envs\$envName"

# 가상환경 설치 폴더 탐지
if (Test-Path $fullEnvPath) {
    Write-Host "   [알림] 기존 가상환경 폴더가 발견되었습니다. 현재 버전으로 덮어쓰기합니다." -ForegroundColor Cyan
} else {
    # 가상환경 폴더가 없다면 생성 
    New-Item -ItemType Directory -Force -Path $fullEnvPath | Out-Null
}

Expand-Archive -Path "$sourcePath\pkgs\$envZipFile" -DestinationPath $fullEnvPath -Force
Write-Host "    [성공] Python 가상환경($envName) 이식이 완료되었습니다." -ForegroundColor Green
Write-Host ""

### [step 4] 시스템 환경 변수(Path) 자동 등록 ###
Write-Host "4 단계: 시스템 환경 변수(Path)에 TensorRT 라이브러리 등록 중..." -ForegroundColor Yellow

# Path에 추가 할 폴더 경로를 배열(@)로 정의
$targetPaths = @(
    "$trtDest\lib", # DLL 파일들
    "$trtDest\bin"  # trtexe.exe 등
)

# 현재 사용자 전용 시스템 환경 변수 Path 가져오기 
$currentPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
$isChanged = $false # 실제로 변경사항이 있는지 확인하는 깃발

# TensorRT 라이브러리 등을 Path에 등록
foreach ($path in $targetPaths) {
    if (Test-Path $path) {
        # 기존 path에 해당 경로가 존재하는지 확인
        if ($currentPath -notmatch [regex]::Escape($path)) {
            $currentPath = $currentPath.TrimEnd(';') + ";" + $path
            $isChanged = $true
            Write-Host "    [성공] 시스템 Path에 신규 등록 완료: $path" -ForegroundColor Green
        } else {
            Write-Host "    [알림] 이미 Path에 경로가 존재: $path" -ForegroundColor Cyan
        }
    } else {
        # 경로가 없는 경우
        Write-Host "    [경고] 해당 경로가 존재하지 않아 등록을 건너뜀: $path" -ForegroundColor Red
    }
}

# Path에 변경사항이 있다면 시스템 레지스트리에  최종 저장
if ($isChanged) {
    [System.Environment]::SetEnvironmentVariable("Path", $currentPath, "User")
    Write-Host "    [완료] 모든 시스템 환경 변수 변경 사항 저장 완료." -ForegroundColor Green
} else {
    Write-Host " [알림] 업데이트 할 새로운 경로가 없습니다." -ForegroundColor Cyan
}
Write-Host ""

### [step 5] TRT_PATH 환경 변수 생성
Write-Host "5 단계: 런타임 종속성 고정을 위한 전용 변수(TRT_PATH) 생성..." -ForegroundColor Yellow
[System.Environment]::SetEnvironmentVariable("TRT_PATH", $trtDest, "User")

### [프로세스 종료] ###
Write-Host ""
Write-Host "#============================================================#" -ForegroundColor Cyan
Write-Host "# [배포 완료] 모든 구성 요소 설치 완료.                          #"
Write-Host "#============================================================#" -ForegroundColor Cyan
Write-Host "적용을 위해 새로 터미널을 여시오." -ForegroundColor Cyan
Write-Host "가상환경 명령어: conda activate $envName" -ForegroundColor Cyan
Write-Host ""
