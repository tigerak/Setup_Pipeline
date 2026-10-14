# ============================================================================
# GUI용 실행 진입 스크립트
# ============================================================================

Set-StrictMode -Version Latest

# 로컬 사용자 설정 로드
$localConfigCandidatePaths = @(
    (Join-Path (Split-Path -Parent $PSScriptRoot) "local_config.ps1"),
    (Join-Path $PSScriptRoot "local_config.ps1")
)

$localConfigPath = $localConfigCandidatePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($null -ne $localConfigPath) {
    . $localConfigPath
}

# 공용 기본 설정 로드
. "$PSScriptRoot\pipeline_config.ps1"

# 로컬 설정이 있으면 기본값을 override한다.
# 엔트리 파일은 값 선언이 아니라 merge만 수행한다.
if ($null -ne $script:LocalConfig) {
    foreach ($propertyName in @("CondaEnvVer", "EvaltoolsVer", "PackageSourceRoot", "RemotePackageSourceRoot")) {
        if ($script:LocalConfig.PSObject.Properties.Name -contains $propertyName) {
            $value = $script:LocalConfig.$propertyName
            if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
                $script:PipelineConfig.$propertyName = $value
            }
        }
    }
}

. "$PSScriptRoot\pipeline_ui.ps1"
. "$PSScriptRoot\pipeline_core.ps1"

$ui = New-SetupPipelineUi
Set-PipelineUi -Ui $ui
$ui.Initialize()

$setupCompleted = $false

try {
    $setupResult = Invoke-PipelineSetup -Ui $ui
    if ($setupResult -eq $false) {
        $ui.Log("")
        $ui.Log("[ENTRY] Setup stopped by user decision or step skip.")
        $ui.GuiCloseButton.Enabled = $true
        $ui.GuiCloseButton.Visible = $true
        $setupCompleted = $false
    }
    else {
        $setupCompleted = $true
    }
}
catch {
    $message = $_.Exception.Message
    $ui.Log("")
    $ui.Log("[ENTRY] Setup halt: $message", [System.ConsoleColor]::Red)
    $ui.SetTopMost($true)
    [System.Windows.Forms.MessageBox]::Show($message, "Setup Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    $setupCompleted = $false
}
finally {
    if ($setupCompleted) {
        $ui.WaitClose()
    }
    else {
        $ui.Log("")
        $ui.Log("Setup paused or did not complete normally. Review the log, then click Close to exit.")
        $ui.GuiCloseButton.Enabled = $true
        $ui.GuiCloseButton.Visible = $true
    }
}
