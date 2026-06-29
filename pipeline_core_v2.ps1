Set-StrictMode -Version Latest

$script:GuiLogForm = $null
$script:GuiLogRichTextBox = $null
$script:GuiContinueButton = $null
$script:GuiCancelButton = $null
$script:GuiCloseButton = $null
$script:GuiStepStatusLabel = $null
$script:GuiStepProgressBar = $null
$script:GuiDecision = $null

function Convert-ConsoleColorToDrawingColor {
    param([System.ConsoleColor]$Color)

    switch ($Color) {
        Black { return [System.Drawing.Color]::Black }
        DarkBlue { return [System.Drawing.Color]::DarkBlue }
        DarkGreen { return [System.Drawing.Color]::DarkGreen }
        DarkCyan { return [System.Drawing.Color]::DarkCyan }
        DarkRed { return [System.Drawing.Color]::DarkRed }
        DarkMagenta { return [System.Drawing.Color]::DarkMagenta }
        DarkYellow { return [System.Drawing.Color]::Olive }
        Gray { return [System.Drawing.Color]::DimGray }
        DarkGray { return [System.Drawing.Color]::Gray }
        Blue { return [System.Drawing.Color]::RoyalBlue }
        Green { return [System.Drawing.Color]::ForestGreen }
        Cyan { return [System.Drawing.Color]::Teal }
        Red { return [System.Drawing.Color]::Red }
        Magenta { return [System.Drawing.Color]::Magenta }
        Yellow { return [System.Drawing.Color]::Goldenrod }
        White { return [System.Drawing.Color]::Black }
        default { return [System.Drawing.Color]::Black }
    }
}

function Resolve-PackageSourcePath {
    $candidates = @()

    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $candidates += $PSScriptRoot
    }

    $baseDir = [System.AppDomain]::CurrentDomain.BaseDirectory
    if (-not [string]::IsNullOrWhiteSpace($baseDir)) {
        $candidates += $baseDir.TrimEnd('\\')
    }

    try {
        $cwd = (Get-Location).Path
        if (-not [string]::IsNullOrWhiteSpace($cwd)) {
            $candidates += $cwd
        }
    }
    catch {
    }

    $expandedCandidates = @()
    foreach ($c in $candidates) {
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        $expandedCandidates += $c
        try {
            $parent = Split-Path -Parent $c
            if (-not [string]::IsNullOrWhiteSpace($parent)) {
                $expandedCandidates += $parent
            }
        }
        catch {
        }
    }

    $uniqueCandidates = $expandedCandidates |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique

    foreach ($base in $uniqueCandidates) {
        $pkgPath = Join-Path $base "pkgs"
        if (Test-Path $pkgPath) {
            return $base
        }
    }

    throw "pkgs folder not found. Searched: $($uniqueCandidates -join '; ')"
}

function Initialize-GuiLogWindow {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $script:GuiLogForm = New-Object System.Windows.Forms.Form
    $script:GuiLogForm.Text = "Setup Pipeline Progress"
    $script:GuiLogForm.StartPosition = "CenterScreen"
    $script:GuiLogForm.Size = New-Object System.Drawing.Size(980, 680)
    $script:GuiLogForm.TopMost = $true

    $script:GuiLogRichTextBox = New-Object System.Windows.Forms.RichTextBox
    $script:GuiLogRichTextBox.ReadOnly = $true
    $script:GuiLogRichTextBox.Dock = "Fill"
    $script:GuiLogRichTextBox.Font = New-Object System.Drawing.Font("Consolas", 10)
    $script:GuiLogRichTextBox.BackColor = [System.Drawing.Color]::White
    $script:GuiLogRichTextBox.ForeColor = [System.Drawing.Color]::Black

    $buttonPanel = New-Object System.Windows.Forms.Panel
    $buttonPanel.Dock = "Bottom"
    $buttonPanel.Height = 86

    $script:GuiStepStatusLabel = New-Object System.Windows.Forms.Label
    $script:GuiStepStatusLabel.Text = "Step progress: waiting"
    $script:GuiStepStatusLabel.AutoSize = $false
    $script:GuiStepStatusLabel.Width = 520
    $script:GuiStepStatusLabel.Height = 18
    $script:GuiStepStatusLabel.Left = 10
    $script:GuiStepStatusLabel.Top = 8

    $script:GuiStepProgressBar = New-Object System.Windows.Forms.ProgressBar
    $script:GuiStepProgressBar.Minimum = 0
    $script:GuiStepProgressBar.Maximum = 100
    $script:GuiStepProgressBar.Value = 0
    $script:GuiStepProgressBar.Width = 520
    $script:GuiStepProgressBar.Height = 18
    $script:GuiStepProgressBar.Left = 10
    $script:GuiStepProgressBar.Top = 28

    $script:GuiContinueButton = New-Object System.Windows.Forms.Button
    $script:GuiContinueButton.Text = "Continue"
    $script:GuiContinueButton.Width = 110
    $script:GuiContinueButton.Height = 30
    $script:GuiContinueButton.Left = 560
    $script:GuiContinueButton.Top = 20
    $script:GuiContinueButton.Visible = $false
    $script:GuiContinueButton.Add_Click({
        $script:GuiDecision = $true
    })

    $script:GuiCancelButton = New-Object System.Windows.Forms.Button
    $script:GuiCancelButton.Text = "Cancel"
    $script:GuiCancelButton.Width = 110
    $script:GuiCancelButton.Height = 30
    $script:GuiCancelButton.Left = 680
    $script:GuiCancelButton.Top = 20
    $script:GuiCancelButton.Visible = $false
    $script:GuiCancelButton.Add_Click({
        $script:GuiDecision = $false
    })

    $script:GuiCloseButton = New-Object System.Windows.Forms.Button
    $script:GuiCloseButton.Text = "Close"
    $script:GuiCloseButton.Width = 110
    $script:GuiCloseButton.Height = 30
    $script:GuiCloseButton.Left = 800
    $script:GuiCloseButton.Top = 20
    $script:GuiCloseButton.Enabled = $false
    $script:GuiCloseButton.Add_Click({
        $script:GuiLogForm.Close()
    })

    $buttonPanel.Controls.Add($script:GuiStepStatusLabel)
    $buttonPanel.Controls.Add($script:GuiStepProgressBar)
    $buttonPanel.Controls.Add($script:GuiContinueButton)
    $buttonPanel.Controls.Add($script:GuiCancelButton)
    $buttonPanel.Controls.Add($script:GuiCloseButton)

    $script:GuiLogForm.Controls.Add($script:GuiLogRichTextBox)
    $script:GuiLogForm.Controls.Add($buttonPanel)
    [void]$script:GuiLogForm.Show()
}

function Set-GuiStepProgress {
    param(
        [int]$Step,
        [string]$Title,
        [int]$TotalSteps = 8,
        [switch]$Running
    )

    if (($null -eq $script:GuiStepProgressBar) -or ($null -eq $script:GuiStepStatusLabel)) {
        return
    }

    $script:GuiStepProgressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
    if ($Running) {
        $script:GuiStepProgressBar.Value = 0
        $script:GuiStepStatusLabel.Text = "Step $($Step)/$($TotalSteps): $Title..."
    } else {
        $script:GuiStepProgressBar.Value = 100
        $script:GuiStepStatusLabel.Text = "Step $($Step)/$($TotalSteps): $Title"
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-GuiSubProgress {
    param([int]$Percent)

    if ($null -eq $script:GuiStepProgressBar) { return }
    $script:GuiStepProgressBar.Value = [Math]::Max(0, [Math]::Min($Percent, 100))
    [System.Windows.Forms.Application]::DoEvents()
}

function Add-GuiLog {
    param(
        [string]$Message,
        [System.ConsoleColor]$ForegroundColor = [System.ConsoleColor]::Gray,
        [switch]$NoNewline
    )

    if ($null -ne $script:GuiLogRichTextBox -and -not $script:GuiLogForm.IsDisposed) {
        $line = if ($null -eq $Message) { "" } else { $Message }
        $color = Convert-ConsoleColorToDrawingColor -Color $ForegroundColor
        $script:GuiLogRichTextBox.SelectionStart = $script:GuiLogRichTextBox.TextLength
        $script:GuiLogRichTextBox.SelectionLength = 0
        $script:GuiLogRichTextBox.SelectionColor = $color

        if ($NoNewline) {
            $script:GuiLogRichTextBox.AppendText($line)
        } else {
            $script:GuiLogRichTextBox.AppendText($line + [Environment]::NewLine)
        }

        $script:GuiLogRichTextBox.SelectionColor = [System.Drawing.Color]::Black
        $script:GuiLogRichTextBox.SelectionStart = $script:GuiLogRichTextBox.TextLength
        $script:GuiLogRichTextBox.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Request-GuiContinue {
    param([string]$Prompt)

    Add-GuiLog ""
    Add-GuiLog $Prompt
    Add-GuiLog "Use Continue or Cancel in the same window."

    $script:GuiDecision = $null
    $script:GuiContinueButton.Visible = $true
    $script:GuiCancelButton.Visible = $true

    while ($null -eq $script:GuiDecision -and -not $script:GuiLogForm.IsDisposed) {
        [System.Windows.Forms.Application]::DoEvents()
    }

    $script:GuiContinueButton.Visible = $false
    $script:GuiCancelButton.Visible = $false

    return ($script:GuiDecision -eq $true)
}

function Wait-GuiLogWindowClose {
    if ($null -ne $script:GuiCloseButton -and -not $script:GuiLogForm.IsDisposed) {
        $script:GuiCloseButton.Enabled = $true
        Add-GuiLog ""
        Add-GuiLog "Process finished. Click Close to exit."
        while (-not $script:GuiLogForm.IsDisposed) {
            [System.Windows.Forms.Application]::DoEvents()
        }
    }
}

function Show-StageError {
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)]$ErrorRecord,
        [bool]$DebugMode = $true
    )

    $msg = "[$Stage] Failed: $($ErrorRecord.Exception.Message)"
    Write-Host $msg -ForegroundColor Red

    if (-not $DebugMode) {
        Add-GuiLog $msg
        Wait-GuiLogWindowClose
    }
}

function Show-PrecheckRuntimeSummary {
    param(
        [bool]$IsCondaInstalled,
        [string]$FoundCondaPath,
        [bool]$IsTrtInstalled,
        [string]$FoundTrtPath,
        [string]$ExpectedTrtPath
    )

    $condaStatus = if ($IsCondaInstalled) {
        "Conda: Detected`nPath: $FoundCondaPath"
    } else {
        "Conda: Not detected`nAction: Miniconda install will run"
    }

    $trtStatus = if ($IsTrtInstalled) {
        "TensorRT: Detected`nPath: $FoundTrtPath"
    } else {
        "TensorRT: Not detected/mismatch`nExpected path: $ExpectedTrtPath`nAction: TensorRT install will run"
    }

    Add-GuiLog ""
    Add-GuiLog "[Pre-check Summary]"
    foreach ($line in ($condaStatus -split "`n")) { Add-GuiLog $line }
    Add-GuiLog ""
    foreach ($line in ($trtStatus -split "`n")) { Add-GuiLog $line }
    Add-GuiLog ""
}

function Invoke-PipelineSetupV2 {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptVer,
        [bool]$DebugMode = $true
    )

    if (-not $DebugMode) {
        Initialize-GuiLogWindow
        Set-GuiStepProgress -Step 0 -Title "Initializing"

        function global:Write-Host {
            [CmdletBinding()]
            param(
                [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
                [object[]]$Object,
                [System.ConsoleColor]$ForegroundColor = [System.ConsoleColor]::Gray,
                [System.ConsoleColor]$BackgroundColor,
                [switch]$NoNewline,
                [object]$Separator = " "
            )

            if ($null -eq $Object) {
                Add-GuiLog ""
            } else {
                $joined = ($Object | ForEach-Object { "$_" }) -join ([string]$Separator)
                Add-GuiLog -Message $joined -ForegroundColor $ForegroundColor -NoNewline:$NoNewline
            }
        }
    }

    ### 환경 변수 및 설정값 정의 ###
    # 스크립트 실행 경로가 설치 소스 기준점.
    Write-Host "Received version: $ScriptVer"

    $sourcePath = Resolve-PackageSourcePath
    Write-Host "Package source root: $sourcePath" -ForegroundColor DarkGray
    $targetCudaVersion_1 = "11.8"
    $targetCudaVersion_2 = @("12.8", "12.9")

    $condaDest = "C:\ProgramData\miniconda3"
    $trtDest_1 = "D:\visionAI\TensorRT-8.5.3.1"
    $trtDest_2 = "D:\visionAI\TensorRT-10.9.0.34"
    $evalToolsDest = "D:\visionAI\Eval_Tools"
    $envName = "visionAI"

    $isCudnnInstalled = $false
    $isZlibInstalled = $false
    $isCondaInstalled = $false
    $isTrtInstalled = $false
    $foundCondaPath = $null
    $foundTrtPath = $null

    $cudnnZipFile_1 = "cudnn-windows-x86_64-8.6.0.163_cuda11-archive.zip"
    $cudnnZipFile_2 = "cudnn-windows-x86_64-9.8.0.87_cuda12-archive.zip"
    $zlibDllFile = "zlibwapi.dll"
    $condaExeName = "Miniconda3-py310_24.9.2-0-Windows-x86_64.exe"
    $trtZipFile_1 = "TensorRT-8.5.3.1.zip"
    $trtZipFile_2 = "TensorRT-10.9.0.34.zip"
    $envZipFile_1 = "visionAI_cu11_$ScriptVer.zip"
    $envZipFile_2 = "visionAI_cu12_$ScriptVer.zip"
    $evalToolsZipFile = "Eval_Tools_$ScriptVer.zip"

    Write-Host "#============================================================#" -ForegroundColor Cyan
    Write-Host "# Pipeline setup automation started                          #" -ForegroundColor Cyan
    Write-Host "#============================================================#" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Pre-check: scanning current system status..." -ForegroundColor Yellow
    if (-not $DebugMode) {
        Set-GuiStepProgress -Step 1 -Title "Pre-check" -Running
    }

    try {
        $nvidiaSmi = Get-Command "nvidia-smi" -ErrorAction SilentlyContinue
        if ($nvidiaSmi) {
            $driverVer = (nvidia-smi --query-gpu=driver_version --format=csv,noheader) -join ", "
            Write-Host "    [OK] NVIDIA driver detected: $driverVer"
        } else {
            throw "NVIDIA driver check failed (nvidia-smi not found)."
        }
        if (-not $DebugMode) { Set-GuiSubProgress -Percent 15 }

        $nvccCommand = Get-Command "nvcc" -ErrorAction SilentlyContinue
        if (-not $nvccCommand) {
            throw "CUDA toolkit check failed (nvcc not found)."
        }

        $nvccPath = $nvccCommand.Source
        $cudaVerString = (& $nvccPath --version | Select-String "release").ToString()
        $cudaVerNum = [regex]::Match($cudaVerString, "release (\d+\.\d+)").Groups[1].Value
        if (-not $DebugMode) { Set-GuiSubProgress -Percent 30 }

        switch ($true) {
            ($cudaVerNum -eq $targetCudaVersion_1) {
                $trtDest = $trtDest_1
                $trtZipFile = $trtZipFile_1
                $cudnnZipFile = $cudnnZipFile_1
                $envZipFile = $envZipFile_1
                $cudaTrackTag = "cu11"
            }
            ($cudaVerNum -in $targetCudaVersion_2) {
                $trtDest = $trtDest_2
                $trtZipFile = $trtZipFile_2
                $cudnnZipFile = $cudnnZipFile_2
                $envZipFile = $envZipFile_2
                $cudaTrackTag = "cu12"
            }
            default {
                throw "Unsupported CUDA version: $cudaVerNum (required: $targetCudaVersion_1 or $($targetCudaVersion_2 -join ', '))."
            }
        }
        Write-Host "    [OK] CUDA toolkit detected: $cudaVerNum"

        $cudaBinPath = Split-Path -Parent $nvccPath

        $cudnnDllCandidates = Get-ChildItem -Path $cudaBinPath -Filter "cudnn*.dll" -File -ErrorAction SilentlyContinue
        $zlibDll = Join-Path $cudaBinPath "zlibwapi.dll"

        if ($cudnnDllCandidates -and $cudnnDllCandidates.Count -gt 0) {
            $isCudnnInstalled = $true
            Write-Host "    [OK] cuDNN DLLs detected."
        } else {
            Write-Host "    [MISS] cuDNN DLLs not found in $cudaBinPath" -ForegroundColor Yellow
        }
        if (-not $DebugMode) { Set-GuiSubProgress -Percent 50 }

        if (Test-Path $zlibDll) {
            $isZlibInstalled = $true
            Write-Host "    [OK] zlibwapi.dll detected."
        } else {
            Write-Host "    [MISS] zlibwapi.dll not found in $cudaBinPath" -ForegroundColor Yellow
        }
        if (-not $DebugMode) { Set-GuiSubProgress -Percent 65 }

        $commonCondaPaths = @(
            "C:\miniconda3",
            "C:\ProgramData\miniconda3",
            "$env:USERPROFILE\miniconda3",
            "C:\Anaconda3",
            "C:\ProgramData\Anaconda3",
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
            Write-Host "    [OK] Conda detected: $foundCondaPath" -ForegroundColor Green
        } else {
            Write-Host "    [MISS] Conda not detected. Will install Miniconda." -ForegroundColor Yellow
        }
        if (-not $DebugMode) { Set-GuiSubProgress -Percent 80 }

        $allPaths = @()
        $allPaths += ([System.Environment]::GetEnvironmentVariable("Path", "Machine") -split ";")
        $allPaths += ([System.Environment]::GetEnvironmentVariable("Path", "User") -split ";")
        $allPaths = $allPaths |
            ForEach-Object { ($_ -replace '^"|"$', '').Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique

        $trtCandidates = @()
        foreach ($p in $allPaths) {
            if (-not (Test-Path $p)) { continue }

            $root = $p
            if ($p -match "[\\/](lib|bin)$") {
                $root = Split-Path -Parent $p
            }

            $libPath = Join-Path $root "lib"
            $trtexecPath = Join-Path $root "bin\trtexec.exe"

            $nvinferDll = Get-ChildItem -Path $libPath -Filter "nvinfer*.dll" -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^nvinfer(_\d+)?\.dll$' } |
                Select-Object -First 1
            $pluginDll = Get-ChildItem -Path $libPath -Filter "nvinfer_plugin*.dll" -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^nvinfer_plugin(_\d+)?\.dll$' } |
                Select-Object -First 1

            if (($null -ne $nvinferDll) -and ($null -ne $pluginDll) -and (Test-Path $trtexecPath)) {
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
                Write-Host "    [MISS] TensorRT found, but not matching CUDA target path ($trtDest). Reinstall required." -ForegroundColor Yellow
            }
        }

        if ($isTrtInstalled) {
            Write-Host "    [OK] TensorRT detected: $foundTrtPath" -ForegroundColor Green
        } else {
            Write-Host "    [MISS] TensorRT not detected in expected path. Install will proceed." -ForegroundColor Yellow
        }
        if (-not $DebugMode) {
            Set-GuiStepProgress -Step 1 -Title "Pre-check"
        }
    }
    catch {
        Show-StageError -Stage "Pre-check" -ErrorRecord $_ -DebugMode $DebugMode
        if ($DebugMode) {
            $null = Read-Host "Press Enter to exit"
        }
        return
    }

    if (-not $DebugMode) {
        Show-PrecheckRuntimeSummary `
            -IsCondaInstalled $isCondaInstalled `
            -FoundCondaPath $foundCondaPath `
            -IsTrtInstalled $isTrtInstalled `
            -FoundTrtPath $foundTrtPath `
            -ExpectedTrtPath $trtDest
    }

    $installPlanKeys = @()
    $installPlanText = @()

    if (-not $isCudnnInstalled) {
        $installPlanKeys += "CUDNN"
        $installPlanText += "cuDNN -> $cudaBinPath"
    }
    if (-not $isZlibInstalled) {
        $installPlanKeys += "ZLIB"
        $installPlanText += "zlibwapi.dll -> $cudaBinPath"
    }
    if (-not $isCondaInstalled) {
        $installPlanKeys += "CONDA"
        $installPlanText += "Miniconda -> $condaDest"
    }
    if (-not $isTrtInstalled) {
        $installPlanKeys += "TRT"
        $installPlanText += "TensorRT -> $trtDest"
    }

    if ($DebugMode) {
        Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
        Write-Host " Install plan"
        if ($installPlanText.Count -eq 0) {
            Write-Host " - No extra install target from pre-check" -ForegroundColor Green
            Write-Host " - Python env deployment will still run" -ForegroundColor Yellow
        } else {
            for ($i = 0; $i -lt $installPlanText.Count; $i++) {
                Write-Host (" {0}. {1}" -f ($i + 1), $installPlanText[$i])
            }
        }
        Write-Host "------------------------------------------------------------" -ForegroundColor Cyan

        $ans = Read-Host "Continue setup? (y/N)"
        if ($ans -notmatch "^[Yy]$") {
            Write-Host "Canceled by user." -ForegroundColor Red
            return
        }
    } else {
        if ($installPlanText.Count -eq 0) {
            Add-GuiLog "No additional system component install is required from pre-check."
            Add-GuiLog "Python environment deployment will continue."
        } else {
            $msgBody = ($installPlanText | ForEach-Object { " - $_" }) -join "`n"
            Add-GuiLog "Install targets:"
            foreach ($line in ($msgBody -split "`n")) { Add-GuiLog $line }

            if (-not (Request-GuiContinue -Prompt "Continue setup?")) {
                Write-Host "Canceled by user." -ForegroundColor Red
                return
            }
        }
    }

    try {
        if (-not $DebugMode) {
            Set-GuiStepProgress -Step 2 -Title "Miniconda" -Running
        }
        if ($installPlanKeys -contains "CONDA") {
            Write-Host "[1/7] Installing Miniconda... (about 5 min)" -ForegroundColor Yellow
            $installArgs = @(
                "/S",
                "/InstallationType=AllUsers",
                "/NoShortcuts=0",
                "/RegisterPython=0",
                "/D=$condaDest"
            )
            if (-not $DebugMode) { Set-GuiSubProgress -Percent 50 }
            Start-Process -FilePath "$sourcePath\pkgs\$condaExeName" -ArgumentList $installArgs -Wait
            if (Test-Path "$condaDest\Scripts") {
                $foundCondaPath = $condaDest
                Write-Host "    [OK] Miniconda installed: $condaDest" -ForegroundColor Green
            } else {
                throw "Miniconda install failed."
            }
        } else {
            Write-Host "[1/7] Miniconda install skipped." -ForegroundColor Cyan
        }
        if (-not $DebugMode) {
            Set-GuiStepProgress -Step 2 -Title "Miniconda"
        }
    }
    catch {
        Show-StageError -Stage "Step 1 - Miniconda" -ErrorRecord $_ -DebugMode $DebugMode
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($foundCondaPath) -and (Test-Path "$foundCondaPath\Scripts\conda.exe")) {
        $activeCondaPath = $foundCondaPath
    } else {
        $activeCondaPath = $condaDest
    }

    try {
        if (-not $DebugMode) {
            Set-GuiStepProgress -Step 3 -Title "TensorRT" -Running
        }
        if ($installPlanKeys -contains "TRT") {
            Write-Host "[2/7] Installing TensorRT..." -ForegroundColor Yellow
            if (-not (Test-Path "$sourcePath\pkgs\$trtZipFile")) {
                throw "TensorRT package not found: $sourcePath\pkgs\$trtZipFile"
            }
            if (-not $DebugMode) { Set-GuiSubProgress -Percent 40 }
            Expand-Archive -Path "$sourcePath\pkgs\$trtZipFile" -DestinationPath "$trtDest" -Force
            if (Test-Path "$trtDest\lib") {
                $isTrtInstalled = $true
                $foundTrtPath = $trtDest
                Write-Host "    [OK] TensorRT deployed: $trtDest" -ForegroundColor Green
            } else {
                throw "TensorRT deploy failed (lib folder missing)."
            }
        } else {
            Write-Host "[2/7] TensorRT install skipped." -ForegroundColor Cyan
        }
        if (-not $DebugMode) {
            Set-GuiStepProgress -Step 3 -Title "TensorRT"
        }
    }
    catch {
        Show-StageError -Stage "Step 2 - TensorRT" -ErrorRecord $_ -DebugMode $DebugMode
        return
    }

    try {
        if (-not $DebugMode) {
            Set-GuiStepProgress -Step 4 -Title "cuDNN/zlib" -Running
        }
        if (($installPlanKeys -contains "CUDNN") -or ($installPlanKeys -contains "ZLIB")) {
            Write-Host "[3/7] Deploying CUDA runtime dependencies..." -ForegroundColor Yellow
            $cudaRootPath = Split-Path -Parent $cudaBinPath

            if ($installPlanKeys -contains "CUDNN") {
                $cudnnZipPath = Join-Path "$sourcePath\pkgs" $cudnnZipFile
                if (-not (Test-Path $cudnnZipPath)) {
                    throw "cuDNN package not found: $cudnnZipPath"
                }

                $cudnnTempDir = Join-Path $env:TEMP ("cudnn_extract_" + [guid]::NewGuid().ToString("N"))
                if (-not $DebugMode) { Set-GuiSubProgress -Percent 30 }
                Expand-Archive -Path $cudnnZipPath -DestinationPath $cudnnTempDir -Force

                $cudnnRoot = Get-ChildItem -Path $cudnnTempDir -Directory -Recurse -ErrorAction SilentlyContinue |
                    Where-Object { (Test-Path (Join-Path $_.FullName "bin")) -and (Test-Path (Join-Path $_.FullName "include")) -and (Test-Path (Join-Path $_.FullName "lib")) } |
                    Select-Object -First 1

                if ($null -eq $cudnnRoot) {
                    Remove-Item -Path $cudnnTempDir -Recurse -Force -ErrorAction SilentlyContinue
                    throw "cuDNN root (bin/include/lib) not found inside archive."
                }

                if (-not $DebugMode) { Set-GuiSubProgress -Percent 70 }
                Copy-Item -Path (Join-Path $cudnnRoot.FullName "bin\*") -Destination $cudaBinPath -Recurse -Force
                Copy-Item -Path (Join-Path $cudnnRoot.FullName "include\*") -Destination (Join-Path $cudaRootPath "include") -Recurse -Force
                Copy-Item -Path (Join-Path $cudnnRoot.FullName "lib\*") -Destination (Join-Path $cudaRootPath "lib") -Recurse -Force
                Remove-Item -Path $cudnnTempDir -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "    [OK] cuDNN deployed to CUDA folders." -ForegroundColor Green
            }

            if ($installPlanKeys -contains "ZLIB") {
                $zlibSourcePath = Join-Path "$sourcePath\pkgs" $zlibDllFile
                $zlibTargetPath = Join-Path $cudaBinPath $zlibDllFile
                if (-not (Test-Path $zlibSourcePath)) {
                    throw "zlib package not found: $zlibSourcePath"
                }
                Copy-Item -Path $zlibSourcePath -Destination $zlibTargetPath -Force
                Write-Host "    [OK] zlibwapi.dll deployed." -ForegroundColor Green
            }
        } else {
            Write-Host "[3/7] CUDA dependency deploy skipped." -ForegroundColor Cyan
        }
        if (-not $DebugMode) {
            Set-GuiStepProgress -Step 4 -Title "cuDNN/zlib"
        }
    }
    catch {
        Show-StageError -Stage "Step 3 - cuDNN/zlib" -ErrorRecord $_ -DebugMode $DebugMode
        return
    }

    try {
        if (-not $DebugMode) {
            Set-GuiStepProgress -Step 5 -Title "Python env" -Running
        }
        Write-Host "[4/7] Deploying Python environment ($envName)..." -ForegroundColor Yellow
        $fullEnvPath = "$activeCondaPath\envs\$envName"
        $envVersionFile = Join-Path $fullEnvPath ".pipeline_env_version"
        $desiredEnvStamp = "$ScriptVer|$cudaTrackTag"
        $needEnvUpdate = $true

        if (Test-Path $fullEnvPath) {
            if (Test-Path $envVersionFile) {
                $installedEnvVersionRaw = Get-Content -Path $envVersionFile -ErrorAction SilentlyContinue | Select-Object -First 1
                $installedEnvVersion = if ($null -eq $installedEnvVersionRaw) { "" } else { $installedEnvVersionRaw.ToString().Trim() }
                if ($installedEnvVersion -eq $desiredEnvStamp) {
                    $needEnvUpdate = $false
                    Write-Host "    [SKIP] Environment is already up to date: $desiredEnvStamp" -ForegroundColor Cyan
                }
            }
        }

        if ($needEnvUpdate) {
            if (Test-Path $fullEnvPath) {
                if (-not $DebugMode) { Set-GuiSubProgress -Percent 20 }
                Remove-Item -Path $fullEnvPath -Recurse -Force
            }
            New-Item -ItemType Directory -Force -Path $fullEnvPath | Out-Null
            if (-not $DebugMode) { Set-GuiSubProgress -Percent 40 }
            Expand-Archive -Path "$sourcePath\pkgs\$envZipFile" -DestinationPath $fullEnvPath -Force
            Set-Content -Path $envVersionFile -Value $desiredEnvStamp -Encoding ASCII -Force
            Write-Host "    [OK] Environment deployed: $desiredEnvStamp" -ForegroundColor Green
        }
        if (-not $DebugMode) {
            Set-GuiStepProgress -Step 5 -Title "Python env"
        }
    }
    catch {
        Show-StageError -Stage "Step 4 - Python env" -ErrorRecord $_ -DebugMode $DebugMode
        return
    }

    if ($isTrtInstalled -and -not [string]::IsNullOrWhiteSpace($foundTrtPath)) {
        $desiredTrtPath = $foundTrtPath
    } else {
        $desiredTrtPath = $trtDest
    }

    try {
        if (-not $DebugMode) {
            Set-GuiStepProgress -Step 6 -Title "PATH" -Running
        }
        $currentPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
        if ($null -eq $currentPath) {
            $currentPath = ""
        }

        $targetPaths = @(
            "$cudaBinPath",
            "$desiredTrtPath\lib",
            "$desiredTrtPath\bin"
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
            Write-Host "[5/7] Updating user PATH for CUDA/TensorRT..." -ForegroundColor Yellow
            $isChanged = $false
            foreach ($path in $targetPaths) {
                if ((Test-Path $path) -and ($currentPath -notmatch [regex]::Escape($path))) {
                    $currentPath = $currentPath.TrimEnd(';') + ";" + $path
                    $isChanged = $true
                    Write-Host "    [ADD] $path" -ForegroundColor Green
                }
            }
            if ($isChanged) {
                [System.Environment]::SetEnvironmentVariable("Path", $currentPath, "User")
            }
        } else {
            Write-Host "[5/7] PATH update skipped (already up to date)." -ForegroundColor Cyan
        }
        if (-not $DebugMode) {
            Set-GuiStepProgress -Step 6 -Title "PATH"
        }
    }
    catch {
        Show-StageError -Stage "Step 5 - PATH" -ErrorRecord $_ -DebugMode $DebugMode
        return
    }

    try {
        if (-not $DebugMode) {
            Set-GuiStepProgress -Step 7 -Title "TRT_PATH" -Running
        }
        $currentTrtPath = [System.Environment]::GetEnvironmentVariable("TRT_PATH", "User")
        $needTrtPathUpdate = ($installPlanKeys -contains "TRT") -or [string]::IsNullOrWhiteSpace($currentTrtPath) -or ($currentTrtPath -ne $desiredTrtPath)
        if ($needTrtPathUpdate) {
            Write-Host "[6/7] Setting TRT_PATH..." -ForegroundColor Yellow
            [System.Environment]::SetEnvironmentVariable("TRT_PATH", $desiredTrtPath, "User")
        } else {
            Write-Host "[6/7] TRT_PATH update skipped." -ForegroundColor Cyan
        }
        if (-not $DebugMode) {
            Set-GuiStepProgress -Step 7 -Title "TRT_PATH"
        }
    }
    catch {
        Show-StageError -Stage "Step 6 - TRT_PATH" -ErrorRecord $_ -DebugMode $DebugMode
        return
    }

    try {
        if (-not $DebugMode) {
            Set-GuiStepProgress -Step 8 -Title "Eval Tools" -Running
        }
        Write-Host "[7/7] Deploying Eval Tools..." -ForegroundColor Yellow
        $evalToolsVersionFile = Join-Path $evalToolsDest ".pipeline_evaltools_version"
        $desiredEvalToolsStamp = "$ScriptVer"
        $needEvalToolsUpdate = $true

        if (Test-Path $evalToolsDest) {
            if (Test-Path $evalToolsVersionFile) {
                $installedEvalToolsVersionRaw = Get-Content -Path $evalToolsVersionFile -ErrorAction SilentlyContinue | Select-Object -First 1
                $installedEvalToolsVersion = if ($null -eq $installedEvalToolsVersionRaw) { "" } else { $installedEvalToolsVersionRaw.ToString().Trim() }
                if ($installedEvalToolsVersion -eq $desiredEvalToolsStamp) {
                    $needEvalToolsUpdate = $false
                    Write-Host "    [SKIP] Eval Tools are already up to date: $desiredEvalToolsStamp" -ForegroundColor Cyan
                }
            }
        }

        if ($needEvalToolsUpdate) {
            if (-not (Test-Path "$sourcePath\pkgs\$evalToolsZipFile")) {
                throw "Eval Tools package not found: $sourcePath\pkgs\$evalToolsZipFile"
            }

            if (Test-Path $evalToolsDest) {
                if (-not $DebugMode) { Set-GuiSubProgress -Percent 20 }
                Remove-Item -Path $evalToolsDest -Recurse -Force
            }

            New-Item -ItemType Directory -Force -Path $evalToolsDest | Out-Null
            if (-not $DebugMode) { Set-GuiSubProgress -Percent 50 }
            Expand-Archive -Path "$sourcePath\pkgs\$evalToolsZipFile" -DestinationPath "$evalToolsDest" -Force
            Set-Content -Path $evalToolsVersionFile -Value $desiredEvalToolsStamp -Encoding ASCII -Force
            Write-Host "    [OK] Eval Tools deployed: $evalToolsDest ($desiredEvalToolsStamp)" -ForegroundColor Green
        }
        if (-not $DebugMode) {
            Set-GuiStepProgress -Step 8 -Title "Eval Tools"
        }
    }
    catch {
        Show-StageError -Stage "Step 7 - Eval Tools" -ErrorRecord $_ -DebugMode $DebugMode
        return
    }

    Write-Host ""
    Write-Host "#============================================================#" -ForegroundColor Cyan
    Write-Host "# [DONE] All setup steps completed                           #" -ForegroundColor Cyan
    Write-Host "#============================================================#" -ForegroundColor Cyan
    Write-Host "Open a new terminal to apply PATH changes." -ForegroundColor Cyan
    Write-Host "Conda command: conda activate $envName" -ForegroundColor Cyan
    if (-not $DebugMode) {
        Set-GuiStepProgress -Step 8 -Title "Completed"
    }

    if ($DebugMode) {
        $null = Read-Host "Press Enter to exit"
    } else {
        Add-GuiLog "All setup steps completed successfully."
        Wait-GuiLogWindowClose
    }
}
