param(
    [string]$ScriptVer
)

if ([string]::IsNullOrWhiteSpace($ScriptVer)) {
    Add-Type -AssemblyName Microsoft.VisualBasic
    Add-Type -AssemblyName System.Windows.Forms
    $ScriptVer = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Enter setup pipeline version (example: 260609)",
        "Setup Pipeline Version",
        ""
    )

    if ([string]::IsNullOrWhiteSpace($ScriptVer)) {
        [void][System.Windows.Forms.MessageBox]::Show(
            "Version is required. Setup will exit.",
            "Canceled",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        exit 1
    }
}

. "$PSScriptRoot\pipeline_core_v2.ps1"
Invoke-PipelineSetupV2 -ScriptVer $ScriptVer -DebugMode $false
