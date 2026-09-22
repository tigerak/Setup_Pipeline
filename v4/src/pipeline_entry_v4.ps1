# -----------------------------------------------------------------------------
# v4 GUI용 실행 진입 스크립트
# -----------------------------------------------------------------------------

Set-StrictMode -Version Latest

. "$PSScriptRoot\pipeline_config_v4.ps1"
. "$PSScriptRoot\pipeline_ui_v4.ps1"
. "$PSScriptRoot\pipeline_core_v4.ps1"

$ui = New-SetupPipelineUi
Set-PipelineUi -Ui $ui
$ui.Initialize()

try {
    Invoke-PipelineSetup -Ui $ui
}
finally {
    $ui.WaitClose()
}
