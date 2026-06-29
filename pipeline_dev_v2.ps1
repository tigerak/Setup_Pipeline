param(
    [string]$ScriptVer
)

if ([string]::IsNullOrWhiteSpace($ScriptVer)) {
    $ScriptVer = Read-Host "Enter setup pipeline version (example: 260609)"
}

. "$PSScriptRoot\pipeline_core_v2.ps1"
Invoke-PipelineSetupV2 -ScriptVer $ScriptVer -DebugMode $true
