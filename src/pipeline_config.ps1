$script:PipelineConfig = [pscustomobject]@{
    # 기본 환경/버전 값
    CondaEnvVer = "260101"
    EvaltoolsVer = "260101"
    # 로컬 캐시 루트: 실제 설치와 패키지 소스는 이 경로를 사용한다.
    PackageSourceRoot = "D:\visionAI\Setup_Pipeline"
    # 원격 보관소(선택): 로컬 캐시에 없는 파일만 동기화한다.
    RemotePackageSourceRoot = "\\12.34.56.7\Setup_Pipeline"

    # 기본 환경 이름
    DefaultEnvName = "visionAI"

    # CUDA 감지 기준
    TargetCudaVersion_1 = "11.8"
    TargetCudaVersion_2 = @("12.8", "12.9")

    # Miniconda 표준 설치 경로
    CondaDest = "C:\ProgramData\miniconda3"

    # TensorRT 설치 루트(후보)
    TrtDest_1 = "D:\visionAI\TensorRT-8.5.3.1"
    TrtDest_2 = "D:\visionAI\TensorRT-10.9.0.34"
    TrtDest_3 = "D:\visionAI\TensorRT-10.12.0.36"

    # 기타 대상 경로
    EvalToolsDest = "D:\visionAI\Eval_Tools"

    # 패키지 파일명
    SevenZipInstaller = "7z2603-x64.exe"
    CudnnZipFile_1 = "cudnn-windows-x86_64-8.6.0.163_cuda11-archive.7z"
    CudnnZipFile_2 = "cudnn-windows-x86_64-9.8.0.87_cuda12-archive.7z"
    ZlibDllFile = "zlibwapi.dll"
    CondaExeName = "Miniconda3-py310_24.9.2-0-Windows-x86_64.exe"
    EvalToolsZipPattern = "Eval_Tools_{0}.zip"
    TrtZipFile_1 = "TensorRT-8.5.3.1.7z"
    TrtZipFile_2 = "TensorRT-10.9.0.34.7z"
    TrtZipFile_3 = "TensorRT-10.12.0.36.7z"

    # Python 환경 설치 구성 (offline conda env 생성 + offline pip 설치)
    # Miniconda 설치 후 로컬 pkgs 캐시를 사용한 conda 환경 생성
    PythonVersion = "3.10"
    # 오프라인 pip 설치용 requirements lock 파일 경로 (상대경로: source root 기준)
    RequirementsWheelhouseRoot = "requirements\wheelhouse\approved"
    RequirementsLockFile_Common = "requirements\common.lock.txt"
    RequirementsLockFile_Cu11 = "requirements\cu11.lock.txt"
    RequirementsLockFile_Cu12 = "requirements\cu12.lock.txt"
}

function Normalize-CudaVersionLabel {
    param(
        [AllowEmptyString()][string]$Version
    )

    if ([string]::IsNullOrWhiteSpace($Version)) {
        return ""
    }

    $normalized = $Version.Trim()
    $normalized = $normalized -replace '[^0-9.]', ''
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return ""
    }

    if ($normalized -match '^(\d+)\.(\d+)(?:\.\d+)?$') {
        return "$($Matches[1]).$($Matches[2])"
    }

    return $normalized
}

function Get-PipelineTensorRTProfiles {
    <#
    .SYNOPSIS
    TensorRT 설치 프로필 목록을 반환한다.

    .DESCRIPTION
    core 로직이 버전/경로 하드코딩을 갖지 않도록,
    프로필 정의를 config 계층으로 분리한다.
    #>

    return @(
        [pscustomobject]@{
            OptionNo = 1
            Name = "TensorRT-8.5.3.1"
            Destination = $script:PipelineConfig.TrtDest_1
            ZipFile = $script:PipelineConfig.TrtZipFile_1
        }
        [pscustomobject]@{
            OptionNo = 2
            Name = "TensorRT-10.9.0.34"
            Destination = $script:PipelineConfig.TrtDest_2
            ZipFile = $script:PipelineConfig.TrtZipFile_2
        }
        [pscustomobject]@{
            OptionNo = 3
            Name = "TensorRT-10.12.0.36"
            Destination = $script:PipelineConfig.TrtDest_3
            ZipFile = $script:PipelineConfig.TrtZipFile_3
        }
    )
}

function Get-DefaultTensorRTOptionNumber {
    <#
    .SYNOPSIS
    감지된 CUDA 버전에 맞는 기본 TensorRT 선택 번호를 반환한다.

    .DESCRIPTION
    기본 선택은 어디까지나 UI에서 미리 강조되는 옵션이며,
    최종 설치 대상은 사용자가 선택 팝업에서 결정한다.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$CudaVersion,
        [Parameter(Mandatory = $true)][string]$TargetCudaVersion_1,
        [Parameter(Mandatory = $true)][string[]]$TargetCudaVersion_2
    )

    $normalizedCudaVersion = Normalize-CudaVersionLabel -Version $CudaVersion
    $normalizedTargetCudaVersion_1 = Normalize-CudaVersionLabel -Version $TargetCudaVersion_1
    $normalizedTargetCudaVersion_2 = @($TargetCudaVersion_2 | ForEach-Object { Normalize-CudaVersionLabel -Version $_ })

    if ($normalizedCudaVersion -eq $normalizedTargetCudaVersion_1) {
        return 1
    }

    if ($normalizedCudaVersion -eq "12.9") {
        return 3
    }

    if ($normalizedCudaVersion -in $normalizedTargetCudaVersion_2) {
        return 2
    }

    return 1
}
