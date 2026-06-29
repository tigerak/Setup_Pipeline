
param (
    [string]$ScriptVer
)

Write-Host "받은 Version 정보: $ScriptVer"

### 배포 모드 설정 ###
$DebugMode = $true

### 환경 변수 및 설정값 정의 ###
# 스크립트 실행 경로가 설치 소스 기준점.
$sourcePath          = $PSScriptRoot
# Cuda Toolkit Version 설정
$targetCudaVersion_1 = "11.8"
$targetCudaVersion_2 = @("12.8", "12.9")
# Miniconda 설정
$condaDest           = "C:\ProgramData\miniconda3"
# TensorRT 설정
$trtDest_1           = "D:\visionAI\TensorRT-8.5.3.1"
$trtDest_2           = "D:\visionAI\TensorRT-10.9.0.34"
# $trtDest_3           = "D:\visionAI\TensorRT-10.12.0.36"
# Eval Tools 설정
$evalToolsDest       = "D:\visionAI\Eval_Tools"
# Python 가상 환경 설정
$envName             = "visionAI"

# 상태 플래그 기본값 설정 
$isCudnnInstalled = $false
$isZlibInstalled = $false
$isCondaInstalled = $false
$isTrtInstalled = $false
$foundCondaPath = $null
$foundTrtPath = $null

### 설치 파일명 설정 ###
$cudnnZipFile_1 = "cudnn-windows-x86_64-8.6.0.163_cuda11-archive.zip"
$cudnnZipFile_2 = "cudnn-windows-x86_64-9.8.0.87_cuda12-archive.zip"
$zlibDllFile = "zlibwapi.dll"
$condaExeName   = "Miniconda3-py310_24.9.2-0-Windows-x86_64.exe"
$trtZipFile_1   = "TensorRT-8.5.3.1.zip"
$trtZipFile_2   = "TensorRT-10.9.0.34.zip"
# $trtZipFile_3   = "TensorRT-10.12.0.36.zip"
$envZipFile_1     = "visionAI_cu11_$ScriptVer.zip"
$envZipFile_2     = "visionAI_cu12_$ScriptVer.zip"
$evalToolsZipFile = "Eval_Tools_$ScriptVer.zip"

### [PRE-CHECK] 종속성 검증 ###
Write-Host "#============================================================#" -ForegroundColor Cyan
Write-Host "# 환경 배포 자동화 과정 시작                                 #" -ForegroundColor Cyan
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
    $null = Read-Host "NVIDIA Driver를 설치하세요. Enter 키를 누르면 설치가 종료됩니다."
    exit
}

# 사전 점검 2: CUDA 설치 여부 및 버전 추출
$nvccCommand = Get-Command "nvcc" -ErrorAction SilentlyContinue
if ($nvccCommand) {
    # 시스템에 등록된 nvcc.exe 경로 추출
    $nvccPath = $nvccCommand.Source
    # nvcc --version에서 버전 숫자만 추출
    $cudaVerString = (& $nvccPath --version | Select-String "release").ToString()
    $cudaVerNum = [regex]::Match($cudaVerString, "release (\d+\.\d+)").Groups[1].Value

    # target Cuda Version 아니면 에러 발생
    switch ($true) {
        ($cudaVerNum -eq $targetCudaVersion_1) { 
            $trtDest = $trtDest_1 
            $trtZipFile = $trtZipFile_1
            $cudnnZipFile = $cudnnZipFile_1
            $envZipFile = $envZipFile_1
            $cudaTrackTag = "cu11"
            $is_msg = $true
        }
        ($cudaVerNum -in $targetCudaVersion_2) { 
            $trtDest = $trtDest_2 
            $trtZipFile = $trtZipFile_2
            $cudnnZipFile = $cudnnZipFile_2
            $envZipFile = $envZipFile_2
            $cudaTrackTag = "cu12"
            $is_msg = $true
        }
        Default {
            Write-Host "    [실패] 설치된 CUDA Toolkit 버전이 $cudaVerNum 입니다. (설치 요구 사항: $targetCudaVersion_1 또는 $targetCudaVersion_2)" -ForegroundColor Red
            $null = Read-Host "요구 된 CUDA Toolkit을 설치하세요. Enter 키를 누르면 설치가 종료됩니다."
            exit
        }
    }
    if ($is_msg) {
        Write-Host "    [성공] CUDA Toolkit 확인 (설치 버전: $cudaVerNum)"
    }

    # nvcc의 bin 경로 추적
    $cudaBinPath = Split-Path -Parent $nvccPath

} else {
    Write-Host "    [실패] 시스템 환경 변수에서 CUDA(nvcc)를 찾을 수 없음. CUDA Toolkit이 설치되지 않음. (설치 요구 사항: $targetCudaVersion_1 또는 $targetCudaVersion_2)" -ForegroundColor Red
    $null = Read-Host "요구 된 CUDA Toolkit을 설치하세요. Enter 키를 누르면 설치가 종료됩니다."
    exit
}

# 사전 점검 3: cuda toolkit 에서 cudnn 및 zlib 탐지
$cudnnDllCandidates = Get-ChildItem -Path $cudaBinPath -Filter "cudnn*.dll" -File -ErrorAction SilentlyContinue
$zlibDll = Join-Path $cudaBinPath "zlibwapi.dll"

if ($cudnnDllCandidates -and $cudnnDllCandidates.Count -gt 0) {
    $isCudnnInstalled = $true
    Write-Host "    [성공] cuDNN 엔진 파일 확인 완료."
} else {
    Write-Host "    [실패] $cudaBinPath 경로에 cuDNN이 없음. 설치를 진행합니다." -ForegroundColor Yellow
}

if (Test-Path $zlibDll) {
    $isZlibInstalled = $true
    Write-Host "    [성공] 필수 의존성 파일(zlibwapi.dll) 확인 완료."
} else {
    Write-Host "    [실패] $cudaBinPath 경로에 zlibwapi.dll이 없음. 설치를 진행합니다." -ForegroundColor Yellow
}

# 사전 점검 4: miniconda3 설치 여부 및 버전 정보 확인
# 윈도우에서 많이 쓰이는 설치 경로 설정해서 탐색
$commonCondaPaths = @(
    "C:\miniconda3"
    "C:\ProgramData\miniconda3"     # AllUser
    "$env:USERPROFILE\miniconda3"   # JustMe
    "C:\Anaconda3"
    "C:\ProgramData\Anaconda3"      # Anaconda
    "$env:USERPROFILE\Anaconda3" 
)

foreach ($path in $commonCondaPaths) {
    if (Test-Path "$path\Scripts\conda.exe") {
        $isCondaInstalled = $true
        $foundCondaPath = $path
        break
    }
}

if ($isCondaInstalled) {
    Write-Host "    [통과] Conda가 감지되었습니다. 경로: $foundCondaPath" -ForegroundColor Green
} else {
    Write-Host "    [알림] Conda가 감지되지 않았습니다. miniconda 설치를 진행합니다" -ForegroundColor Yellow
}

# 사전 점검 5: TensorRT 설치 여부 및 버전 정보 확인
# 시스템 환경 변수에 등록 된 모든 폴더에서 Machine/User Path 수집 + 정리
$allPaths = @()
$allPaths += ([System.Environment]::GetEnvironmentVariable("Path", "Machine") -split ";")
$allPaths += ([System.Environment]::GetEnvironmentVariable("Path", "User") -split ";")
$allPaths = $allPaths |
    ForEach-Object { ($_ -replace '^"|"$', '').Trim() } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Select-Object -Unique

$pathCheckIndex = 0
Write-Host ("    [진행] TensorRT 경로 점검 (총 {0}개)" -f $allPaths.Count) -ForegroundColor Cyan
$trtCandidates = @()

foreach ($p in $allPaths) {
    $pathCheckIndex++
    if (-not (Test-Path $p)) {
        continue
    }

    $root = $p
    if ($p -match "[\\/](lib|bin)$") {
        $root = Split-Path -Parent $p
    }

    $libPath = Join-Path $root "lib"
    $trtexecPath = Join-Path $root "bin\trtexec.exe"

    # TensorRT 8.x: nvinfer.dll / nvinfer_plugin.dll
    # TensorRT 10.x: nvinfer_10.dll / nvinfer_plugin_10.dll
    $nvinferDll = Get-ChildItem -Path $libPath -Filter "nvinfer*.dll" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^nvinfer(_\d+)?\.dll$' } |
        Select-Object -First 1
    $pluginDll = Get-ChildItem -Path $libPath -Filter "nvinfer_plugin*.dll" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^nvinfer_plugin(_\d+)?\.dll$' } |
        Select-Object -First 1

    $hasNvinfer = $null -ne $nvinferDll
    $hasPlugin = $null -ne $pluginDll
    $hasTrtexec = Test-Path $trtexecPath

    # $nvinferStatus = if ($hasNvinfer) { "OK" } else { "MISS" }
    # $pluginStatus = if ($hasPlugin) { "OK" } else { "MISS" }
    # $trtexecStatus = if ($hasTrtexec) { "OK" } else { "MISS" }

    # Write-Host ("    [점검 {0}/{1}] {2} | nvinfer:{3}, plugin:{4}, trtexec:{5}" -f $pathCheckIndex, $allPaths.Count, $root, $nvinferStatus, $pluginStatus, $trtexecStatus) -ForegroundColor DarkGray

    if ($hasNvinfer -and $hasPlugin -and $hasTrtexec) {
        Write-Host "    [일치] TensorRT 후보 경로 확인: $root" -ForegroundColor Green
        $trtCandidates += $root
    }
}

if ($trtCandidates.Count -gt 0) {
    $trtCandidates = $trtCandidates | Select-Object -Unique
    $expectedTrtPath = $trtDest.TrimEnd('\\')
    $matchedExpectedTrt = $trtCandidates |
        Where-Object { $_.TrimEnd('\\') -ieq $expectedTrtPath } |
        Select-Object -First 1

    if ($matchedExpectedTrt) {
        $isTrtInstalled = $true
        $foundTrtPath = $matchedExpectedTrt
    } else {
        $isTrtInstalled = $false
        $foundTrtPath = $null
        Write-Host "    [알림] 감지된 TensorRT 경로가 CUDA($cudaVerNum) 대상 경로($trtDest)와 다릅니다. 재설치를 진행합니다." -ForegroundColor Yellow
    }
}

if ($isTrtInstalled) {
    Write-Host "    [통과] TensorRT가 감지되었습니다. 경로: $foundTrtPath" -ForegroundColor Green
} else {
    Write-Host "    [알림] 시스템 환경 변수에서 TensorRT가 감지되지 않았습니다. 설치를 진행합니다." -ForegroundColor Yellow
}

### [USER CONFIRMATION] 사용자 최종 승인 ###
# 사전 점검 1,2(NVIDIA Driver, CUDA Toolkit)는 수동 설치 항목으로 제외
# 사전 점검 3,4,5에서 누락된 항목만 설치 대상으로 안내
$installPlanKeys = @()
$installPlanText = @()

if (-not $isCudnnInstalled) {
    $installPlanKeys += "CUDNN"
    $installPlanText += "cuDNN 설치 경로 -> $cudaBinPath"
}
if (-not $isZlibInstalled) {
    $installPlanKeys += "ZLIB"
    $installPlanText += "zlibwapi.dll 설치 경로 -> $cudaBinPath"
}
if (-not $isCondaInstalled) {
    $installPlanKeys += "CONDA"
    $installPlanText += "Miniconda 설치 경로 -> $condaDest"
}
if (-not $isTrtInstalled) {
    $installPlanKeys += "TRT"
    $installPlanText += "TensorRT 설치 경로 -> $trtDest"
}

if ($DebugMode) {
    # 개발 모드: 터미널에서 텍스트로 확인
    Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host " [설치 대상 경로 확인]"
    if ($installPlanText.Count -eq 0) {
        Write-Host " - 설치할 항목 없음 (사전 점검 모두 충족)" -ForegroundColor Green
        Write-Host " - Python 가상환경($envName) 설치를 진행합니다." -ForegroundColor Yellow
    } else {
        for ($i = 0; $i -lt $installPlanText.Count; $i++) {
            Write-Host (" {0}. {1}" -f ($i + 1), $installPlanText[$i])
        }
    }
    Write-Host "------------------------------------------------------------" -ForegroundColor Cyan

    $ans = Read-Host "설치를 계속 진행하겠습니까? (y/N)"
    if ($ans -notmatch "^[Yy]$") {
        Write-Host "    [취소] 설치를 취소하였습니다. 배포 프로세스 종료." -ForegroundColor Red
        exit
    }
    Write-Host "    [승인] 설치를 시작합니다." -ForegroundColor Green
} else {
    # 배포 모드(.exe): 윈도우 GUI 팝업창으로 확인
    Add-Type -AssemblyName System.Windows.Forms
    if ($installPlanText.Count -eq 0) {
        $msgText = "사전 점검 기준으로 추가 설치가 필요하지 않습니다.`n`n" +
                   "확인을 누르면 다음 단계로 진행합니다."
        [void][System.Windows.Forms.MessageBox]::Show(
            $msgText,
            "설치 대상 확인",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
        Write-Host "Python 가상환경($envName) 설치를 진행합니다." -ForegroundColor Green
    } else {
        $msgBody = ($installPlanText | ForEach-Object { " - $_" }) -join "`n"
        $msgText = "다음 누락 항목만 설치합니다.`n`n" + $msgBody + "`n`n" +
                   "설치를 계속 하겠습니까?"
        $msgResult = [System.Windows.Forms.MessageBox]::Show(
            $msgText,
            "설치 대상 확인",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )

        if ($msgResult -eq "No") {
            Write-Host "[취소] 설치를 취소하였습니다. 배포 프로세스 종료." -ForegroundColor Red
            exit
        }
        Write-Host "[승인] 누락 항목 설치를 시작합니다." -ForegroundColor Green
    }
}
Write-Host ""

### [STEP 1] 미니콘다 설치 ###
if ($installPlanKeys -contains "CONDA") {
    Write-Host "1 단계: 미니콘다 백그라운드 설치 중... (10분 내에 설치됩니다.)" -ForegroundColor Yellow

    # 미니콘다 설치 실행
    $installArgs = @(
        "/S",                  # Silent 모드로 설치 (GUI 없이 자동 설치)
        "/InstallationType=AllUsers", # JustMe | AllUsers
        "/NoShortcuts=0",      # 0: 바탕화면과 시작 메뉴에 바로가기 생성, 1: 바로가기 생성 안함
        "/RegisterPython=0",   # 0: 설치 시 시스템 환경 변수에 등록, 1: 등록 안함
        "/D=$condaDest"        # 설치 경로 지정 (예: C:\ProgramData\miniconda3)
    ) 
    
    # 반드시 관리자 권한으로 실행
    Start-Process -FilePath "$sourcePath\pkgs\$condaExeName" -ArgumentList $installArgs -Wait
    # 설치 검증
    if (Test-Path $condaDest\Scripts) {
        Write-Host "    [성공] $condaDest 에 미니콘다 설치 완료." -ForegroundColor Green
        $foundCondaPath = $condaDest
    } else  {
        Write-Host "    [오류] 미니콘다 설치 실패." -ForegroundColor Red
        exit
    }
} else {
    Write-Host "1 단계: 미니콘다 설치 생략 (이미 설치됨)" -ForegroundColor Cyan
}
Write-Host ""

# 이후 단계는 실제 감지/설치된 conda 경로를 기준으로 동작
if (-not [string]::IsNullOrWhiteSpace($foundCondaPath) -and (Test-Path "$foundCondaPath\Scripts\conda.exe")) {
    $activeCondaPath = $foundCondaPath
} else {
    $activeCondaPath = $condaDest
}

### [step 2] TensorRT Engine 배포 ###
if ($installPlanKeys -contains "TRT") {
    Write-Host "2 단계: TensorRT 압축 해제 중..." -ForegroundColor Yellow
    # 압축 해제 시작
    if (-not (Test-Path "$sourcePath\pkgs\$trtZipFile")) {
        Write-Host "    [오류] TensorRT 패키지를 찾지 못했습니다: $sourcePath\pkgs\$trtZipFile" -ForegroundColor Red
        $null = Read-Host "패키지를 확인하세요. Enter 키를 누르면 설치가 종료됩니다."
        exit
    }
    Write-Host "    [진행] $trtZipFile 압축 해제 중..." -ForegroundColor Yellow
    Expand-Archive -Path "$sourcePath\pkgs\$trtZipFile" -DestinationPath "$trtDest" -Force

    # 압축 해제 후 실제 결과물이 $trtDest에 잘 들어갔는지 검사
    if (Test-Path "$trtDest\lib") {
        Write-Host "    [성공] $trtDest 에 TensorRT 설치 완료." -ForegroundColor Green
        $isTrtInstalled = $true
        $foundTrtPath = $trtDest
    } else {
        # 
        Write-Host "    [경고] 설치가 완료됐으나 lib이 존재 하지 않음" -ForegroundColor Red
    }
} else {
    Write-Host "2 단계: TensorRT 설치 생략 (이미 설치됨)" -ForegroundColor Cyan
}
Write-Host ""

### [step 3] cuDNN / zlib 배포 ###
if (($installPlanKeys -contains "CUDNN") -or ($installPlanKeys -contains "ZLIB")) {
    Write-Host "3 단계: CUDA 런타임 의존성(cuDNN/zlib) 배포 중..." -ForegroundColor Yellow
    $cudaRootPath = Split-Path -Parent $cudaBinPath

    if ($installPlanKeys -contains "CUDNN") {
        $cudnnZipPath = Join-Path "$sourcePath\pkgs" $cudnnZipFile
        if (Test-Path $cudnnZipPath) {
            $cudnnTempDir = Join-Path $env:TEMP ("cudnn_extract_" + [guid]::NewGuid().ToString("N"))
            Expand-Archive -Path $cudnnZipPath -DestinationPath $cudnnTempDir -Force

            $cudnnRoot = Get-ChildItem -Path $cudnnTempDir -Directory -Recurse -ErrorAction SilentlyContinue |
                Where-Object { (Test-Path (Join-Path $_.FullName "bin")) -and (Test-Path (Join-Path $_.FullName "include")) -and (Test-Path (Join-Path $_.FullName "lib")) } |
                Select-Object -First 1

            if ($null -eq $cudnnRoot) {
                Write-Host "    [오류] $cudnnZipFile 내부에서 cuDNN 루트(bin/include/lib)를 찾지 못했습니다." -ForegroundColor Red
                Remove-Item -Path $cudnnTempDir -Recurse -Force -ErrorAction SilentlyContinue
                exit
            }

            $cudnnBinSrc = Join-Path $cudnnRoot.FullName "bin"
            $cudnnIncludeSrc = Join-Path $cudnnRoot.FullName "include"
            $cudnnLibSrc = Join-Path $cudnnRoot.FullName "lib"
            $cudaIncludePath = Join-Path $cudaRootPath "include"
            $cudaLibPath = Join-Path $cudaRootPath "lib"

            if (Test-Path $cudnnBinSrc) {
                New-Item -ItemType Directory -Force -Path $cudaBinPath | Out-Null
                Copy-Item -Path (Join-Path $cudnnBinSrc "*") -Destination $cudaBinPath -Recurse -Force
            }

            if (Test-Path $cudnnIncludeSrc) {
                New-Item -ItemType Directory -Force -Path $cudaIncludePath | Out-Null
                Copy-Item -Path (Join-Path $cudnnIncludeSrc "*") -Destination $cudaIncludePath -Recurse -Force
            }

            if (Test-Path $cudnnLibSrc) {
                New-Item -ItemType Directory -Force -Path $cudaLibPath | Out-Null
                Copy-Item -Path (Join-Path $cudnnLibSrc "*") -Destination $cudaLibPath -Recurse -Force
            }

            Write-Host "    [성공] cuDNN 압축 해제/덮어쓰기 완료: $cudaRootPath (bin/include/lib)" -ForegroundColor Green

            Remove-Item -Path $cudnnTempDir -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            Write-Host "    [오류] cuDNN 패키지를 찾지 못했습니다: $cudnnZipPath" -ForegroundColor Red
            exit
        }
    } else {
        Write-Host "    [알림] cuDNN 배포 생략 (이미 존재)" -ForegroundColor Cyan
    }

    if ($installPlanKeys -contains "ZLIB") {
        $zlibSourcePath = Join-Path "$sourcePath\pkgs" $zlibDllFile
        $zlibTargetPath = Join-Path $cudaBinPath $zlibDllFile

        if (Test-Path $zlibSourcePath) {
            Copy-Item -Path $zlibSourcePath -Destination $zlibTargetPath -Force
            Write-Host "    [성공] zlibwapi.dll 배포 완료: $zlibTargetPath" -ForegroundColor Green
        } else {
            Write-Host "    [오류] zlib 파일을 찾지 못했습니다: $zlibSourcePath" -ForegroundColor Red
            exit
        }
    } else {
        Write-Host "    [알림] zlib 배포 생략 (이미 존재)" -ForegroundColor Cyan
    }
} else {
    Write-Host "3 단계: CUDA 런타임 의존성(cuDNN/zlib) 배포 생략 (이미 존재)" -ForegroundColor Cyan
}
Write-Host ""

### [step 4] Python 가상환경 추가 ###
Write-Host "4 단계: Python 가상환경($envName) 이식 중..." -ForegroundColor Yellow

$fullEnvPath = "$activeCondaPath\envs\$envName"
$envVersionFile = Join-Path $fullEnvPath ".pipeline_env_version"
$desiredEnvStamp = "$ScriptVer|$cudaTrackTag"
$needEnvUpdate = $true

# 가상환경 설치 폴더 탐지
if (Test-Path $fullEnvPath) {
    Write-Host "   [알림] 기존 가상환경 폴더가 발견되었습니다. 버전 확인 중..." -ForegroundColor Cyan

    if (Test-Path $envVersionFile) {
        $installedEnvVersionRaw = Get-Content -Path $envVersionFile -ErrorAction SilentlyContinue | Select-Object -First 1
        $installedEnvVersion = if ($null -eq $installedEnvVersionRaw) { "" } else { $installedEnvVersionRaw.ToString().Trim() }
        if (-not [string]::IsNullOrWhiteSpace($installedEnvVersion)) {
            Write-Host "   [정보] 현재 가상환경 저장 버전: $installedEnvVersion" -ForegroundColor DarkGray
        }

        if ($installedEnvVersion -eq $desiredEnvStamp) {
            $needEnvUpdate = $false
            Write-Host "   [생략] 요청 버전/쿠다($desiredEnvStamp)와 동일하여 가상환경 이식을 건너뜁니다." -ForegroundColor Cyan
        } else {
            Write-Host "   [갱신] 요청 버전/쿠다($desiredEnvStamp)와 달라 가상환경을 재이식합니다." -ForegroundColor Yellow
        }
    } else {
        Write-Host "   [알림] 저장된 버전 정보가 없어 가상환경을 갱신합니다." -ForegroundColor Yellow
    }
} else {
    Write-Host "   [신규] 가상환경 폴더를 생성합니다." -ForegroundColor Cyan
}

if ($needEnvUpdate) {
    if (Test-Path $fullEnvPath) {
        Write-Host "   [진행] 기존 가상환경 폴더를 완전 삭제합니다: $fullEnvPath" -ForegroundColor Yellow
        Remove-Item -Path $fullEnvPath -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $fullEnvPath | Out-Null
    Expand-Archive -Path "$sourcePath\pkgs\$envZipFile" -DestinationPath $fullEnvPath -Force
    Set-Content -Path $envVersionFile -Value $desiredEnvStamp -Encoding ASCII -Force
    Write-Host "    [성공] Python 가상환경($envName) 이식이 완료되었습니다. (버전/쿠다: $desiredEnvStamp)" -ForegroundColor Green
} else {
    Write-Host "    [완료] Python 가상환경($envName)은 최신 버전으로 유지됩니다." -ForegroundColor Green
}
Write-Host ""

if ($isTrtInstalled -and -not [string]::IsNullOrWhiteSpace($foundTrtPath)) {
    $desiredTrtPath = $foundTrtPath
} else {
    $desiredTrtPath = $trtDest
}

### [step 5] 시스템 환경 변수(Path) 자동 등록 ###
$currentPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
if ($null -eq $currentPath) {
    $currentPath = ""
}
$targetPaths = @(
    "$cudaBinPath",         # cublas/cudnn 등 CUDA 런타임 DLL
    "$desiredTrtPath\lib", # TensorRT DLL 파일들
    "$desiredTrtPath\bin"  # trtexec.exe 등
)
$needPathRegistration = ($installPlanKeys -contains "TRT")

if (-not $needPathRegistration) {
    foreach ($path in $targetPaths) {
        if ($currentPath -notmatch [regex]::Escape($path)) {
            $needPathRegistration = $true
            break
        }
    }
}

if ($needPathRegistration) {
    Write-Host "5 단계: 시스템 환경 변수(Path)에 CUDA/TensorRT 라이브러리 등록 중..." -ForegroundColor Yellow
    $isChanged = $false # 실제로 변경사항이 있는지 확인하는 깃발

    # CUDA/TensorRT 런타임 의존성 경로를 Path에 등록
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
} else {
    Write-Host "5 단계: CUDA/TensorRT Path 등록 생략 (이미 최신 경로)" -ForegroundColor Cyan
}
Write-Host ""

### [step 6] TRT_PATH 환경 변수 생성 ###
$currentTrtPath = [System.Environment]::GetEnvironmentVariable("TRT_PATH", "User")
$needTrtPathUpdate = ($installPlanKeys -contains "TRT") -or [string]::IsNullOrWhiteSpace($currentTrtPath) -or ($currentTrtPath -ne $desiredTrtPath)

if ($needTrtPathUpdate) {
    Write-Host "6 단계: 런타임 종속성 고정을 위한 전용 변수(TRT_PATH) 생성..." -ForegroundColor Yellow
    [System.Environment]::SetEnvironmentVariable("TRT_PATH", $desiredTrtPath, "User")
} else {
    Write-Host "6 단계: TRT_PATH 생성 생략 (이미 최신 경로)" -ForegroundColor Cyan
}

### [step 7] Eval Tools 설치 ###
Write-Host "7 단계: Eval Tools 버전: $ScriptVer 이식 중..." -ForegroundColor Yellow
$evalToolsVersionFile = Join-Path $evalToolsDest ".pipeline_evaltools_version"
$desiredEvalToolsStamp = "$ScriptVer"
$needEvalToolsUpdate = $true

if (Test-Path $evalToolsDest) {
    if (Test-Path $evalToolsVersionFile) {
        $installedEvalToolsVersionRaw = Get-Content -Path $evalToolsVersionFile -ErrorAction SilentlyContinue | Select-Object -First 1
        $installedEvalToolsVersion = if ($null -eq $installedEvalToolsVersionRaw) { "" } else { $installedEvalToolsVersionRaw.ToString().Trim() }
        if ($installedEvalToolsVersion -eq $desiredEvalToolsStamp) {
            $needEvalToolsUpdate = $false
            Write-Host "    [생략] Eval Tools가 최신 버전입니다: $desiredEvalToolsStamp" -ForegroundColor Cyan
        }
    }
}

if ($needEvalToolsUpdate) {
    if (-not (Test-Path "$sourcePath\pkgs\$evalToolsZipFile")) {
        Write-Host "    [오류] Eval Tools 패키지를 찾지 못했습니다: $sourcePath\pkgs\$evalToolsZipFile" -ForegroundColor Red
        $null = Read-Host "패키지를 확인하세요. Enter 키를 누르면 설치가 종료됩니다."
        exit
    }

    if (Test-Path $evalToolsDest) {
        Write-Host "    [진행] 기존 Eval Tools 폴더를 삭제합니다: $evalToolsDest" -ForegroundColor Yellow
        Remove-Item -Path $evalToolsDest -Recurse -Force
    }

    New-Item -ItemType Directory -Force -Path $evalToolsDest | Out-Null
    Write-Host "    [진행] $evalToolsZipFile 압축 해제 중..." -ForegroundColor Yellow
    Expand-Archive -Path "$sourcePath\pkgs\$evalToolsZipFile" -DestinationPath "$evalToolsDest" -Force
    Set-Content -Path $evalToolsVersionFile -Value $desiredEvalToolsStamp -Encoding ASCII -Force

    if (Test-Path "$evalToolsDest") {
        Write-Host "    [성공] $evalToolsDest 에 Eval Tools 설치 완료. (버전: $desiredEvalToolsStamp)" -ForegroundColor Green
    } else {
        Write-Host "    [경고] 설치가 완료되지 않음" -ForegroundColor Red
    }
}

### .bat 파일 만들기 <- 버전 관리 하면서 가상환경 꾸미기 (파이썬 파일만 바뀌었나? 가상환경 업데이트 해야하나? 에 따라 달라지기)

### [프로세스 종료] ###
Write-Host ""
Write-Host "#============================================================#" -ForegroundColor Cyan
Write-Host "# [배포 완료] 모든 구성 요소 설치 완료.                        #"
Write-Host "#============================================================#" -ForegroundColor Cyan
Write-Host "적용을 위해 새로 터미널을 여십시오." -ForegroundColor Cyan
Write-Host "Conda 가상환경 명령어: conda activate $envName" -ForegroundColor Cyan
Write-Host ""
$null = Read-Host "설치를 종료하려면 Enter 키를 누르세요..."