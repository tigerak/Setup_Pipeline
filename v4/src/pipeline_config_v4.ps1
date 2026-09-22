$script:PipelineConfig = [pscustomobject]@{
    # 기본 버전 스탬프
    DefaultCondaEnvVer = "260909"
    DefaultEvaltoolsVer = "260801"
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
    EnvZipPattern_Cu11 = "visionAI_cu11_{0}.7z"
    EnvZipPattern_Cu12 = "visionAI_cu12_{0}.7z"
    EvalToolsZipPattern = "Eval_Tools_{0}.zip"
    TrtZipFile_1 = "TensorRT-8.5.3.1.7z"
    TrtZipFile_2 = "TensorRT-10.9.0.34.7z"
    TrtZipFile_3 = "TensorRT-10.12.0.36.7z"
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

    if ($CudaVersion -eq $TargetCudaVersion_1) {
        return 1
    }

    if ($CudaVersion -eq "12.9") {
        return 3
    }

    if ($CudaVersion -in $TargetCudaVersion_2) {
        return 2
    }

    return 1
}
