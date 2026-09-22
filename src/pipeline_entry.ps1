# ============================================================================
# v4 GUI용 실행 진입 스크립트
# ============================================================================

Set-StrictMode -Version Latest

# 로컬 설정 로드
. "$PSScriptRoot\local_config.ps1"

# 파이프라인 설정 로드
. "$PSScriptRoot\pipeline_config.ps1"

# ============================================================================
# local_config의 값으로 pipeline_config 오버라이드
# ============================================================================

if ($null -ne $script:LocalConfig) {
    # 버전 관리
    if ($script:LocalConfig.DefaultCondaEnvVer) {
        $script:PipelineConfig.DefaultCondaEnvVer = $script:LocalConfig.DefaultCondaEnvVer
    }
    if ($script:LocalConfig.DefaultEvaltoolsVer) {
        $script:PipelineConfig.DefaultEvaltoolsVer = $script:LocalConfig.DefaultEvaltoolsVer
    }
    
    # 패키지 소스 경로 관리
    if ($script:LocalConfig.PackageSourceRoot) {
        $script:PipelineConfig.PackageSourceRoot = $script:LocalConfig.PackageSourceRoot
    }
}

. "$PSScriptRoot\pipeline_ui.ps1"
. "$PSScriptRoot\pipeline_core.ps1"

$ui = New-SetupPipelineUi
Set-PipelineUi -Ui $ui
$ui.Initialize()

try {
    Invoke-PipelineSetup -Ui $ui
}
finally {
    $ui.WaitClose()
}
