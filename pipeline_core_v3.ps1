Set-StrictMode -Version Latest

# 배포 버전: Conda 환경과 Eval Tools 버전을 독립적으로 관리한다.
# - CondaEnvVer: Python 가상 환경(visionAI) 패키지 버전
# - EvaltoolsVer: Eval Tools 패키지 버전
$script:DefaultCondaEnvVer = "260706"
$script:DefaultEvaltoolsVer = "260706"

$script:GuiLogForm = $null
$script:GuiLogRichTextBox = $null
$script:GuiContinueButton = $null
$script:GuiCancelButton = $null
$script:GuiCloseButton = $null
$script:GuiStepStatusLabel = $null
$script:GuiStepProgressBar = $null
$script:GuiSubStatusLabel = $null
$script:GuiSubProgressBar = $null
$script:GuiDecision = $null
$script:CurrentStep = 0

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
    $script:GuiLogForm.Size = New-Object System.Drawing.Size(980, 720)
    $script:GuiLogForm.TopMost = $false

    $script:GuiLogRichTextBox = New-Object System.Windows.Forms.RichTextBox
    $script:GuiLogRichTextBox.ReadOnly = $true
    $script:GuiLogRichTextBox.Dock = "Fill"
    $script:GuiLogRichTextBox.Font = New-Object System.Drawing.Font("Consolas", 10)
    $script:GuiLogRichTextBox.BackColor = [System.Drawing.Color]::White
    $script:GuiLogRichTextBox.ForeColor = [System.Drawing.Color]::Black

    # 하단 패널 (프로그래스 바 + 버튼)
    $buttonPanel = New-Object System.Windows.Forms.Panel
    $buttonPanel.Dock = "Bottom"
    $buttonPanel.Height = 130
    $buttonPanel.BackColor = [System.Drawing.Color]::LightGray

    # 1단계 진행률 레이블
    $script:GuiStepStatusLabel = New-Object System.Windows.Forms.Label
    $script:GuiStepStatusLabel.Text = "Step progress: waiting"
    $script:GuiStepStatusLabel.AutoSize = $false
    $script:GuiStepStatusLabel.Width = 520
    $script:GuiStepStatusLabel.Height = 16
    $script:GuiStepStatusLabel.Left = 10
    $script:GuiStepStatusLabel.Top = 8
    $script:GuiStepStatusLabel.Font = New-Object System.Drawing.Font("Consolas", 9, [System.Drawing.FontStyle]::Bold)

    # 1단계 진행률 바
    $script:GuiStepProgressBar = New-Object System.Windows.Forms.ProgressBar
    $script:GuiStepProgressBar.Minimum = 0
    $script:GuiStepProgressBar.Maximum = 100
    $script:GuiStepProgressBar.Value = 0
    $script:GuiStepProgressBar.Width = 520
    $script:GuiStepProgressBar.Height = 18
    $script:GuiStepProgressBar.Left = 10
    $script:GuiStepProgressBar.Top = 26

    # 세부 진행률 레이블
    $script:GuiSubStatusLabel = New-Object System.Windows.Forms.Label
    $script:GuiSubStatusLabel.Text = "Sub progress: 0%"
    $script:GuiSubStatusLabel.AutoSize = $false
    $script:GuiSubStatusLabel.Width = 520
    $script:GuiSubStatusLabel.Height = 16
    $script:GuiSubStatusLabel.Left = 10
    $script:GuiSubStatusLabel.Top = 50
    $script:GuiSubStatusLabel.Font = New-Object System.Drawing.Font("Consolas", 9)

    # 세부 진행률 바
    $script:GuiSubProgressBar = New-Object System.Windows.Forms.ProgressBar
    $script:GuiSubProgressBar.Minimum = 0
    $script:GuiSubProgressBar.Maximum = 100
    $script:GuiSubProgressBar.Value = 0
    $script:GuiSubProgressBar.Width = 520
    $script:GuiSubProgressBar.Height = 18
    $script:GuiSubProgressBar.Left = 10
    $script:GuiSubProgressBar.Top = 68

    $script:GuiContinueButton = New-Object System.Windows.Forms.Button
    $script:GuiContinueButton.Text = "Continue"
    $script:GuiContinueButton.Width = 110
    $script:GuiContinueButton.Height = 40
    $script:GuiContinueButton.Left = 560
    $script:GuiContinueButton.Top = 50
    $script:GuiContinueButton.Visible = $false
    $script:GuiContinueButton.Add_Click({
        $script:GuiDecision = $true
    })

    $script:GuiCancelButton = New-Object System.Windows.Forms.Button
    $script:GuiCancelButton.Text = "Cancel"
    $script:GuiCancelButton.Width = 110
    $script:GuiCancelButton.Height = 30
    $script:GuiCancelButton.Left = 680
    $script:GuiCancelButton.Top = 55
    $script:GuiCancelButton.Visible = $false
    $script:GuiCancelButton.Add_Click({
        $script:GuiDecision = $false
    })

    $script:GuiCloseButton = New-Object System.Windows.Forms.Button
    $script:GuiCloseButton.Text = "Close"
    $script:GuiCloseButton.Width = 110
    $script:GuiCloseButton.Height = 30
    $script:GuiCloseButton.Left = 800
    $script:GuiCloseButton.Top = 55
    $script:GuiCloseButton.Enabled = $false
    $script:GuiCloseButton.Add_Click({
        $script:GuiLogForm.Close()
    })

    $buttonPanel.Controls.Add($script:GuiStepStatusLabel)
    $buttonPanel.Controls.Add($script:GuiStepProgressBar)
    $buttonPanel.Controls.Add($script:GuiSubStatusLabel)
    $buttonPanel.Controls.Add($script:GuiSubProgressBar)
    $buttonPanel.Controls.Add($script:GuiContinueButton)
    $buttonPanel.Controls.Add($script:GuiCancelButton)
    $buttonPanel.Controls.Add($script:GuiCloseButton)

    $script:GuiLogForm.Controls.Add($script:GuiLogRichTextBox)
    $script:GuiLogForm.Controls.Add($buttonPanel)
    [void]$script:GuiLogForm.Show()
    # GUI가 제대로 렌더링되도록 이벤트 처리
    for ($i = 0; $i -lt 3; $i++) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 50
    }
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
    $script:CurrentStep = $Step
    
    if ($Running) {
        # 전체 8단계 중 현재 Step의 시작 위치 계산
        $stepStartPercent = [int](($Step - 1) * 100 / $TotalSteps)
        $script:GuiStepProgressBar.Value = $stepStartPercent
        $script:GuiStepStatusLabel.Text = "Step $($Step)/$($TotalSteps): $Title..."
        # 새 단계 시작 시 Sub Progress를 0으로 초기화
        $script:GuiSubProgressBar.Value = 0
        $script:GuiSubStatusLabel.Text = "Sub progress: 0%"
    } else {
        # 전체 8단계 중 현재 Step의 완료 위치 계산
        $stepEndPercent = [int]($Step * 100 / $TotalSteps)
        $script:GuiStepProgressBar.Value = $stepEndPercent
        $script:GuiStepStatusLabel.Text = "Step $($Step)/$($TotalSteps): $Title"
        # 단계 완료 시 Sub Progress를 100%로 설정
        $script:GuiSubProgressBar.Value = 100
        $script:GuiSubStatusLabel.Text = "Sub progress: 100%"
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-GuiSubProgress {
    param([int]$Percent)

    if ($null -eq $script:GuiSubProgressBar) { return }
    $script:GuiSubProgressBar.Value = [Math]::Max(0, [Math]::Min($Percent, 100))
    $script:GuiSubStatusLabel.Text = "Sub progress: $($script:GuiSubProgressBar.Value)%"
    
    # Step Progress bar도 함께 업데이트
    if (($null -ne $script:CurrentStep) -and ($script:CurrentStep -gt 0)) {
        $totalSteps = 8
        # 현재 Step의 시작과 끝 위치 계산
        $stepStart = [int](($script:CurrentStep - 1) * 100 / $totalSteps)
        $stepEnd = [int]($script:CurrentStep * 100 / $totalSteps)
        $stepRange = $stepEnd - $stepStart
        
        # Sub Progress에 따라 Step bar 값 계산
        $subPercent = $script:GuiSubProgressBar.Value
        $stepValue = [int]($stepStart + ($stepRange * $subPercent / 100))
        $script:GuiStepProgressBar.Value = $stepValue
    }
    
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

    # 사용자 응답이 필요한 순간에만 최상위로 올려 놓는다.
    Set-GuiTopMost -Enabled $true
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

    # 외부 설치기 창과 충돌하지 않도록 다시 비최상위로 되돌린다.
    Set-GuiTopMost -Enabled $false

    return ($script:GuiDecision -eq $true)
}

function Wait-GuiLogWindowClose {
    if ($null -ne $script:GuiCloseButton -and -not $script:GuiLogForm.IsDisposed) {
        # 종료 안내 단계는 사용자 확인이 필요하므로 최상위로 노출한다.
        Set-GuiTopMost -Enabled $true
        $script:GuiCloseButton.Enabled = $true
        Add-GuiLog ""
        Add-GuiLog "Process finished. Click Close to exit."
        while (-not $script:GuiLogForm.IsDisposed) {
            [System.Windows.Forms.Application]::DoEvents()
        }
    }
}

function Set-GuiTopMost {
    param([bool]$Enabled)

    if (($null -eq $script:GuiLogForm) -or $script:GuiLogForm.IsDisposed) {
        return
    }

    $script:GuiLogForm.TopMost = $Enabled
    if ($Enabled) {
        $script:GuiLogForm.Activate()
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Invoke-WithGuiNotOnTop {
    <#
    .SYNOPSIS
    외부 설치 프로그램 실행 시 GUI 창을 백그라운드에 두고 TopMost = false로 설정.
    GUI는 계속 visible 상태를 유지하므로 로그와 진행 상황을 볼 수 있다.
    실행 중 주기적으로 DoEvents()를 호출하여 GUI 응답성을 유지한다.
    #>
    param([Parameter(Mandatory = $true)][scriptblock]$Action)

    $wasMostOnTop = $false
    if (($null -ne $script:GuiLogForm) -and (-not $script:GuiLogForm.IsDisposed)) {
        $wasMostOnTop = $script:GuiLogForm.TopMost
        if ($wasMostOnTop) {
            $script:GuiLogForm.TopMost = $false
            [System.Windows.Forms.Application]::DoEvents()
        }
    }

    try {
        & $Action
        # 액션 실행 후 GUI 이벤트 처리
        for ($i = 0; $i -lt 5; $i++) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 100
        }
    }
    finally {
        if ($wasMostOnTop -and ($null -ne $script:GuiLogForm) -and (-not $script:GuiLogForm.IsDisposed)) {
            $script:GuiLogForm.TopMost = $true
            $script:GuiLogForm.Activate()
            [System.Windows.Forms.Application]::DoEvents()
        }
    }
}

function Invoke-ProcessWithGuiProgress {
    <#
    .SYNOPSIS
    외부 프로세스를 실행하는 동안 GUI 이벤트를 계속 처리하고,
    Sub Progress를 왕복 애니메이션으로 갱신해 멈춤처럼 보이지 않게 한다.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int]$StartPercent = 10,
        [int]$MaxPercentWhileRunning = 95,
        [int]$TickMilliseconds = 250
    )

    $wasMostOnTop = $false
    if (($null -ne $script:GuiLogForm) -and (-not $script:GuiLogForm.IsDisposed)) {
        $wasMostOnTop = $script:GuiLogForm.TopMost
        if ($wasMostOnTop) {
            $script:GuiLogForm.TopMost = $false
            [System.Windows.Forms.Application]::DoEvents()
        }
    }

    try {
        $start = [Math]::Max(0, [Math]::Min($StartPercent, 100))
        $maxRun = [Math]::Max($start, [Math]::Min($MaxPercentWhileRunning, 99))
        $tick = [Math]::Max(100, $TickMilliseconds)

        Set-GuiSubProgress -Percent $start
        $proc = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru

        $percent = $start
        while (-not $proc.HasExited) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds $tick

            if ($percent -lt $maxRun) {
                $percent += 2
                if ($percent -gt $maxRun) {
                    $percent = $maxRun
                }
            }

            Set-GuiSubProgress -Percent $percent
        }

        if ($proc.ExitCode -ne 0) {
            throw "Process failed with exit code $($proc.ExitCode): $FilePath"
        }

        Set-GuiSubProgress -Percent 100
    }
    finally {
        if ($wasMostOnTop -and ($null -ne $script:GuiLogForm) -and (-not $script:GuiLogForm.IsDisposed)) {
            $script:GuiLogForm.TopMost = $true
            $script:GuiLogForm.Activate()
            [System.Windows.Forms.Application]::DoEvents()
        }
    }
}

function Expand-ArchiveWithGuiProgress {
    <#
    .SYNOPSIS
    ZIP 엔트리를 파일 단위로 풀면서 Sub Progress를 실시간으로 갱신한다.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [int]$StartPercent = 0,
        [int]$EndPercent = 100
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    if (-not (Test-Path -LiteralPath $DestinationPath)) {
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    }

    $start = [Math]::Max(0, [Math]::Min($StartPercent, 100))
    $end = [Math]::Max($start, [Math]::Min($EndPercent, 100))

    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entries = @($zip.Entries | Where-Object { -not [string]::IsNullOrEmpty($_.Name) })
        $total = $entries.Count

        if ($total -eq 0) {
            Set-GuiSubProgress -Percent $end
            return
        }

        $i = 0
        foreach ($entry in $entries) {
            $targetPath = Join-Path $DestinationPath $entry.FullName
            $targetDir = Split-Path -Parent $targetPath
            if (-not [string]::IsNullOrWhiteSpace($targetDir) -and -not (Test-Path -LiteralPath $targetDir)) {
                New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
            }

            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $targetPath, $true)

            $i++
            $ratio = [double]$i / [double]$total
            $percent = [int][Math]::Round($start + (($end - $start) * $ratio))
            Set-GuiSubProgress -Percent $percent
        }
    }
    finally {
        if ($null -ne $zip) {
            $zip.Dispose()
        }
    }
}

function Copy-DirectoryFilesWithGuiProgress {
    <#
    .SYNOPSIS
    디렉터리 파일을 재귀 복사하면서 Sub Progress를 실시간으로 갱신한다.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$DestinationDir,
        [int]$StartPercent = 0,
        [int]$EndPercent = 100
    )

    if (-not (Test-Path -LiteralPath $SourceDir)) {
        return
    }

    if (-not (Test-Path -LiteralPath $DestinationDir)) {
        New-Item -ItemType Directory -Path $DestinationDir -Force | Out-Null
    }

    $start = [Math]::Max(0, [Math]::Min($StartPercent, 100))
    $end = [Math]::Max($start, [Math]::Min($EndPercent, 100))

    $files = @(Get-ChildItem -Path $SourceDir -File -Recurse -ErrorAction SilentlyContinue)
    $total = $files.Count
    if ($total -eq 0) {
        Set-GuiSubProgress -Percent $end
        return
    }

    $baseLen = $SourceDir.TrimEnd('\\').Length
    $i = 0
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($baseLen).TrimStart('\\')
        $target = Join-Path $DestinationDir $relative
        $targetDir = Split-Path -Parent $target

        if (-not (Test-Path -LiteralPath $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        }

        Copy-Item -LiteralPath $file.FullName -Destination $target -Force

        $i++
        $ratio = [double]$i / [double]$total
        $percent = [int][Math]::Round($start + (($end - $start) * $ratio))
        Set-GuiSubProgress -Percent $percent
    }
}

function Show-StageError {
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)]$ErrorRecord
    )

    $msg = "[$Stage] Failed: $($ErrorRecord.Exception.Message)"
    Add-GuiLog $msg -ForegroundColor Red
    Set-GuiTopMost -Enabled $true
    [void][System.Windows.Forms.MessageBox]::Show($msg, "Setup Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    Wait-GuiLogWindowClose
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

# PATH 문자열을 안정적으로 비교하기 위한 정규화 키 생성.
# - 따옴표/공백을 제거하고, 가능하면 Resolve-Path 결과를 사용한다.
# - 대소문자 차이를 무시하기 위해 소문자 키를 반환한다.
function Get-PathCompareKey {
    param([string]$PathValue)

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return ""
    }

    $clean = ($PathValue -replace '^"|"$', '').Trim().TrimEnd('\\')
    if ([string]::IsNullOrWhiteSpace($clean)) {
        return ""
    }

    try {
        if (Test-Path -LiteralPath $clean) {
            return ((Resolve-Path -LiteralPath $clean).ProviderPath.TrimEnd('\\')).ToLowerInvariant()
        }
    }
    catch {
    }

    return $clean.ToLowerInvariant()
}

# User/Machine PATH를 배열로 읽고, 중복/공백 항목을 제거한다.
function Get-EnvironmentPathEntries {
    param([ValidateSet("User", "Machine")][string]$Scope)

    $raw = [System.Environment]::GetEnvironmentVariable("Path", $Scope)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    $seen = @{}
    $result = @()

    foreach ($entry in ($raw -split ";")) {
        $clean = ($entry -replace '^"|"$', '').Trim().TrimEnd('\\')
        if ([string]::IsNullOrWhiteSpace($clean)) { continue }

        $key = Get-PathCompareKey -PathValue $clean
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        if ($seen.ContainsKey($key)) { continue }

        $seen[$key] = $true
        $result += $clean
    }

    return $result
}

# PATH 배열을 다시 User/Machine 환경 변수에 기록한다.
function Set-EnvironmentPathEntries {
    param(
        [ValidateSet("User", "Machine")][string]$Scope,
        [string[]]$Entries
    )

    $sanitized = @()
    foreach ($entry in $Entries) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $sanitized += ($entry -replace '^"|"$', '').Trim().TrimEnd('\\')
    }

    $newPath = ($sanitized -join ";")
    [System.Environment]::SetEnvironmentVariable("Path", $newPath, $Scope)
}

# 후보 경로가 TensorRT 루트인지 보수적으로 판별한다.
# lib 폴더의 nvinfer 계열 DLL + bin\trtexec.exe 존재를 기준으로 삼는다.
function Test-TensorRTInstallRoot {
    param([string]$RootPath)

    if ([string]::IsNullOrWhiteSpace($RootPath)) {
        return $false
    }

    if (-not (Test-Path -LiteralPath $RootPath)) {
        return $false
    }

    $libPath = Join-Path $RootPath "lib"
    $trtexecPath = Join-Path $RootPath "bin\trtexec.exe"
    if ((-not (Test-Path -LiteralPath $libPath)) -or (-not (Test-Path -LiteralPath $trtexecPath))) {
        return $false
    }

    $nvinferDll = Get-ChildItem -Path $libPath -Filter "nvinfer*.dll" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^nvinfer(_\d+)?\.dll$' } |
        Select-Object -First 1
    $pluginDll = Get-ChildItem -Path $libPath -Filter "nvinfer_plugin*.dll" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^nvinfer_plugin(_\d+)?\.dll$' } |
        Select-Object -First 1

    return (($null -ne $nvinferDll) -and ($null -ne $pluginDll))
}

# CUDA Toolkit의 기본 설치 루트 또는 그 하위 경로인지 판별한다.
# TensorRT 정리 중에 CUDA 자체가 삭제되는 오탐을 막기 위한 방어 장치다.
function Test-IsCudaToolkitPath {
    param([string]$PathValue)

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $false
    }

    $cudaRootPatterns = @(
        '^[A-Za-z]:\\Program Files\\NVIDIA GPU Computing Toolkit\\CUDA\\v\d+\.\d+',
        '^[A-Za-z]:\\Program Files \(x86\)\\NVIDIA GPU Computing Toolkit\\CUDA\\v\d+\.\d+'
    )

    foreach ($pattern in $cudaRootPatterns) {
        if ($PathValue -match $pattern) {
            return $true
        }
    }

    return $false
}

# 경로가 TensorRT 전용 경로로 보이는지 더 엄격하게 검사한다.
# - TensorRT 이름이 포함되거나
# - TensorRT 루트로 이미 확인된 경로의 하위 경로일 때만 true를 반환한다.
function Test-IsTensorRTLikePath {
    param(
        [string]$PathValue,
        [string[]]$KnownRoots
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $false
    }

    $pathKey = Get-PathCompareKey -PathValue $PathValue
    if ([string]::IsNullOrWhiteSpace($pathKey)) {
        return $false
    }

    if (Test-IsCudaToolkitPath -PathValue $PathValue) {
        return $false
    }

    if ($pathKey -match '\\tensorrt([\\\-]|$)') {
        return $true
    }

    foreach ($root in $KnownRoots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $rootKey = Get-PathCompareKey -PathValue $root
        if ([string]::IsNullOrWhiteSpace($rootKey)) { continue }

        if (($pathKey -eq $rootKey) -or
            ($pathKey -eq "$rootKey\\lib") -or
            ($pathKey -eq "$rootKey\\bin") -or
            ($pathKey.StartsWith("$rootKey\\"))) {
            return $true
        }
    }

    return $false
}

# PATH 항목이 TensorRT 관련인지 판별한다.
# - 루트/하위(lib, bin) 직접 매칭
# - 경로명에 TensorRT 키워드가 포함된 경우
function Test-IsTensorRTPathEntry {
    param(
        [string]$PathEntry,
        [string[]]$KnownRoots
    )

    if ([string]::IsNullOrWhiteSpace($PathEntry)) {
        return $false
    }

    $entryKey = Get-PathCompareKey -PathValue $PathEntry
    if ([string]::IsNullOrWhiteSpace($entryKey)) {
        return $false
    }

    return (Test-IsTensorRTLikePath -PathValue $PathEntry -KnownRoots $KnownRoots)
}

# 기존 TensorRT와 연관된 환경 변수/경로를 모두 제거한다.
# 요구사항에 맞게 User + Machine 범위를 모두 정리한다.
# 파일 삭제와 동일한 보수적 기준을 적용:
# - PATH 항목: Test-TensorRTInstallRoot로 검증된 루트의 lib/bin만 제거
# - 환경변수 값: Test-TensorRTInstallRoot로 검증된 경로인 경우만 제거
# CUDA Toolkit 기본 경로는 절대 제거하지 않는다.
function Remove-TensorRTEnvironmentSettings {
    param([string[]]$KnownRoots)

    $report = [ordered]@{
        RemovedPathEntries = @()
        RemovedVariables = @()
    }

    # 검증된 TensorRT 루트 경로 목록 생성 (파일 삭제와 동일한 기준)
    $verifiedTrtRoots = @()
    $seen = @{}
    foreach ($root in $KnownRoots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        if (Test-IsCudaToolkitPath -PathValue $root) { continue }
        
        $key = Get-PathCompareKey -PathValue $root
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true

        if (Test-TensorRTInstallRoot -RootPath $root) {
            $verifiedTrtRoots += $root
        }
    }

    foreach ($scope in @("User", "Machine")) {
        $entries = Get-EnvironmentPathEntries -Scope $scope
        $kept = @()

        foreach ($entry in $entries) {
            $shouldRemove = $false
            
            # PATH 항목이 검증된 TensorRT 루트의 lib 또는 bin 하위 경로인지 확인
            foreach ($verifiedRoot in $verifiedTrtRoots) {
                $libPath = Join-Path $verifiedRoot "lib"
                $binPath = Join-Path $verifiedRoot "bin"
                
                $entryKey = Get-PathCompareKey -PathValue $entry
                $libKey = Get-PathCompareKey -PathValue $libPath
                $binKey = Get-PathCompareKey -PathValue $binPath
                
                if (($entryKey -eq $libKey) -or ($entryKey -eq $binKey)) {
                    $shouldRemove = $true
                    break
                }
            }

            if ($shouldRemove) {
                $report.RemovedPathEntries += "$scope::$entry"
            } else {
                $kept += $entry
            }
        }

        Set-EnvironmentPathEntries -Scope $scope -Entries $kept

        # 환경변수 값이 검증된 TensorRT 루트인 경우만 제거
        $envNames = [System.Environment]::GetEnvironmentVariables($scope).Keys | ForEach-Object { [string]$_ }
        foreach ($varName in $envNames) {
            $currentValue = [System.Environment]::GetEnvironmentVariable($varName, $scope)
            if ([string]::IsNullOrWhiteSpace($currentValue)) {
                continue
            }

            # 변수 값이 검증된 TensorRT 루트 경로와 일치하는지 확인
            $valueKey = Get-PathCompareKey -PathValue $currentValue
            $shouldRemove = $false
            foreach ($verifiedRoot in $verifiedTrtRoots) {
                $rootKey = Get-PathCompareKey -PathValue $verifiedRoot
                if ($valueKey -eq $rootKey) {
                    $shouldRemove = $true
                    break
                }
            }

            if ($shouldRemove) {
                [System.Environment]::SetEnvironmentVariable($varName, $null, $scope)
                $report.RemovedVariables += "$scope::$varName=$currentValue"
            }
        }
    }

    return [pscustomobject]$report
}

# 기존 TensorRT 설치 폴더를 삭제한다.
# - 잘못된 폴더 오삭제를 피하기 위해 Test-TensorRTInstallRoot로 검증 후 제거한다.
# - CUDA Toolkit 기본 경로는 제외한다.
function Remove-TensorRTInstallations {
    param([string[]]$CandidateRoots)

    $report = [ordered]@{
        RemovedRoots = @()
        SkippedRoots = @()
    }

    $seen = @{}
    foreach ($root in $CandidateRoots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $key = Get-PathCompareKey -PathValue $root
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true

        # CUDA Toolkit 기본 폴더는 삭제 대상에서 제외한다.
        if (Test-IsCudaToolkitPath -PathValue $root) {
            $report.SkippedRoots += $root
            continue
        }

        if (Test-TensorRTInstallRoot -RootPath $root) {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
            $report.RemovedRoots += $root
        } else {
            $report.SkippedRoots += $root
        }
    }

    return [pscustomobject]$report
}

function Invoke-PipelineSetupV2 {
    param(
        [string]$CondaEnvVer = $script:DefaultCondaEnvVer,
        [string]$EvaltoolsVer = $script:DefaultEvaltoolsVer
    )

    Initialize-GuiLogWindow
    Set-GuiStepProgress -Step 0 -Title "Initializing"

    Add-GuiLog "Version - CondaEnv: $CondaEnvVer / EvalTools: $EvaltoolsVer"

    $sourcePath = Resolve-PackageSourcePath
    Add-GuiLog "Package source root: $sourcePath" -ForegroundColor DarkGray
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
    $trtCandidates = @()

    $cudnnZipFile_1 = "cudnn-windows-x86_64-8.6.0.163_cuda11-archive.zip"
    $cudnnZipFile_2 = "cudnn-windows-x86_64-9.8.0.87_cuda12-archive.zip"
    $zlibDllFile = "zlibwapi.dll"
    $condaExeName = "Miniconda3-py310_24.9.2-0-Windows-x86_64.exe"
    $trtZipFile_1 = "TensorRT-8.5.3.1.zip"
    $trtZipFile_2 = "TensorRT-10.9.0.34.zip"
    $envZipFile_1 = "visionAI_cu11_$CondaEnvVer.zip"
    $envZipFile_2 = "visionAI_cu12_$CondaEnvVer.zip"
    $evalToolsZipFile = "Eval_Tools_$EvaltoolsVer.zip"

    Add-GuiLog "#============================================================#" -ForegroundColor Cyan
    Add-GuiLog "# Pipeline setup automation started                          #" -ForegroundColor Cyan
    Add-GuiLog "#============================================================#" -ForegroundColor Cyan
    Add-GuiLog ""
    Add-GuiLog "Pre-check: scanning current system status..." -ForegroundColor Yellow
    Set-GuiStepProgress -Step 1 -Title "Pre-check" -Running

    try {
        $nvidiaSmi = Get-Command "nvidia-smi" -ErrorAction SilentlyContinue
        if ($nvidiaSmi) {
            $driverVer = (nvidia-smi --query-gpu=driver_version --format=csv,noheader) -join ", "
            Add-GuiLog "    [OK] NVIDIA driver detected: $driverVer"
        } else {
            throw "NVIDIA driver check failed (nvidia-smi not found)."
        }
        Set-GuiSubProgress -Percent 15

        $nvccCommand = Get-Command "nvcc" -ErrorAction SilentlyContinue
        if (-not $nvccCommand) {
            throw "CUDA toolkit check failed (nvcc not found)."
        }

        $nvccPath = $nvccCommand.Source
        $cudaVerString = (& $nvccPath --version | Select-String "release").ToString()
        $cudaVerNum = [regex]::Match($cudaVerString, "release (\d+\.\d+)").Groups[1].Value
        Set-GuiSubProgress -Percent 30

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
        Add-GuiLog "    [OK] CUDA toolkit detected: $cudaVerNum"

        $cudaBinPath = Split-Path -Parent $nvccPath

        $cudnnDllCandidates = Get-ChildItem -Path $cudaBinPath -Filter "cudnn*.dll" -File -ErrorAction SilentlyContinue
        $zlibDll = Join-Path $cudaBinPath "zlibwapi.dll"

        if ($cudnnDllCandidates -and $cudnnDllCandidates.Count -gt 0) {
            $isCudnnInstalled = $true
            Add-GuiLog "    [OK] cuDNN DLLs detected."
        } else {
            Add-GuiLog "    [MISS] cuDNN DLLs not found in $cudaBinPath" -ForegroundColor Yellow
        }
        Set-GuiSubProgress -Percent 50

        if (Test-Path $zlibDll) {
            $isZlibInstalled = $true
            Add-GuiLog "    [OK] zlibwapi.dll detected."
        } else {
            Add-GuiLog "    [MISS] zlibwapi.dll not found in $cudaBinPath" -ForegroundColor Yellow
        }
        Set-GuiSubProgress -Percent 65

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
            Add-GuiLog "    [OK] Conda detected: $foundCondaPath" -ForegroundColor Green
        } else {
            Add-GuiLog "    [MISS] Conda not detected. Will install Miniconda." -ForegroundColor Yellow
        }
        Set-GuiSubProgress -Percent 80

        $allPaths = @()
        $allPaths += ([System.Environment]::GetEnvironmentVariable("Path", "Machine") -split ";")
        $allPaths += ([System.Environment]::GetEnvironmentVariable("Path", "User") -split ";")
        $allPaths = $allPaths |
            ForEach-Object { ($_ -replace '^"|"$', '').Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique

        # PATH(User+Machine)에 연결된 TensorRT 루트를 추적한다.
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

        # TensorRT 루트가 PATH에 없더라도, 파이프라인의 표준 설치 경로에 존재하면 후보로 포함한다.
        foreach ($knownRoot in @($trtDest_1, $trtDest_2)) {
            if (Test-TensorRTInstallRoot -RootPath $knownRoot) {
                $trtCandidates += $knownRoot
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
                Add-GuiLog "    [MISS] TensorRT found, but not matching CUDA target path ($trtDest). Reinstall required." -ForegroundColor Yellow
            }
        }

        if ($isTrtInstalled) {
            Add-GuiLog "    [OK] TensorRT detected: $foundTrtPath" -ForegroundColor Green
        } else {
            Add-GuiLog "    [MISS] TensorRT not detected in expected path. Install will proceed." -ForegroundColor Yellow
        }
        Set-GuiStepProgress -Step 1 -Title "Pre-check"
    }
    catch {
        Show-StageError -Stage "Pre-check" -ErrorRecord $_
        return
    }

    Show-PrecheckRuntimeSummary `
        -IsCondaInstalled $isCondaInstalled `
        -FoundCondaPath $foundCondaPath `
        -IsTrtInstalled $isTrtInstalled `
        -FoundTrtPath $foundTrtPath `
        -ExpectedTrtPath $trtDest

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
    # TensorRT는 "이미 설치됨" 상태라도 항상 정리 후 재배포 대상으로 잡는다.
    # 요구사항: 기존 TensorRT 관련 시스템 환경 변수까지 모두 삭제하고 우리 패키지로 재설치.
    if ($isTrtInstalled) {
        $installPlanKeys += "TRT"
        $installPlanText += "TensorRT cleanup + reinstall -> $trtDest"
    } else {
        $installPlanKeys += "TRT"
        $installPlanText += "TensorRT -> $trtDest"
    }

    # GUI 전용 실행: 계획 안내 후 사용자 확인을 받는다.
    if ($installPlanText.Count -eq 0) {
        Add-GuiLog "No additional system component install is required from pre-check."
        Add-GuiLog "Python environment deployment will continue."
    } else {
        $msgBody = ($installPlanText | ForEach-Object { " - $_" }) -join "`n"
        Add-GuiLog "Install targets:"
        foreach ($line in ($msgBody -split "`n")) { Add-GuiLog $line }

        if (-not (Request-GuiContinue -Prompt "Continue setup?")) {
            Add-GuiLog "Canceled by user." -ForegroundColor Red
            return
        }
    }

    try {
        Set-GuiStepProgress -Step 2 -Title "Miniconda" -Running
        if ($installPlanKeys -contains "CONDA") {
            Add-GuiLog "[1/7] Installing Miniconda..." -ForegroundColor Yellow
            $installArgs = @(
                "/S",
                "/InstallationType=AllUsers",
                "/NoShortcuts=0",
                "/RegisterPython=0",
                "/D=$condaDest"
            )
            # Miniconda 설치: 실행 중에도 Sub Progress가 멈추지 않도록 폴링 갱신한다.
            Invoke-ProcessWithGuiProgress `
                -FilePath "$sourcePath\pkgs\$condaExeName" `
                -ArgumentList $installArgs `
                -StartPercent 0 `
                -MaxPercentWhileRunning 95 `
                -TickMilliseconds 250
            if (Test-Path "$condaDest\Scripts") {
                $foundCondaPath = $condaDest
                Add-GuiLog "    [OK] Miniconda installed: $condaDest" -ForegroundColor Green
            } else {
                throw "Miniconda install failed."
            }
        } else {
            Add-GuiLog "[1/7] Miniconda install skipped." -ForegroundColor Cyan
        }
        Set-GuiStepProgress -Step 2 -Title "Miniconda"
    }
    catch {
        Show-StageError -Stage "Step 1 - Miniconda" -ErrorRecord $_
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($foundCondaPath) -and (Test-Path "$foundCondaPath\Scripts\conda.exe")) {
        $activeCondaPath = $foundCondaPath
    } else {
        $activeCondaPath = $condaDest
    }

    try {
        Set-GuiStepProgress -Step 3 -Title "TensorRT" -Running
        if ($installPlanKeys -contains "TRT") {
            Add-GuiLog "[2/7] Installing TensorRT..." -ForegroundColor Yellow

            $cleanupRoots = @()
            $cleanupRoots += $trtCandidates
            $cleanupRoots += $foundTrtPath
            $cleanupRoots += $trtDest_1
            $cleanupRoots += $trtDest_2

            $installCleanupReport = Remove-TensorRTInstallations -CandidateRoots $cleanupRoots
            foreach ($removedRoot in $installCleanupReport.RemovedRoots) {
                Add-GuiLog "    [CLEAN] Removed TensorRT root: $removedRoot" -ForegroundColor DarkYellow
            }

            $envCleanupReport = Remove-TensorRTEnvironmentSettings -KnownRoots $cleanupRoots
            foreach ($removedPathEntry in $envCleanupReport.RemovedPathEntries) {
                Add-GuiLog "    [CLEAN] PATH entry removed: $removedPathEntry" -ForegroundColor DarkYellow
            }
            foreach ($removedVar in $envCleanupReport.RemovedVariables) {
                Add-GuiLog "    [CLEAN] Env var removed: $removedVar" -ForegroundColor DarkYellow
            }

            if (-not (Test-Path "$sourcePath\pkgs\$trtZipFile")) {
                throw "TensorRT package not found: $sourcePath\pkgs\$trtZipFile"
            }
            Set-GuiSubProgress -Percent 0
            New-Item -ItemType Directory -Force -Path $trtDest | Out-Null
            Expand-ArchiveWithGuiProgress -ZipPath "$sourcePath\pkgs\$trtZipFile" -DestinationPath "$trtDest" -StartPercent 0 -EndPercent 95
            if (Test-Path "$trtDest\lib") {
                $isTrtInstalled = $true
                $foundTrtPath = $trtDest
                Add-GuiLog "    [OK] TensorRT deployed: $trtDest" -ForegroundColor Green
            } else {
                throw "TensorRT deploy failed (lib folder missing)."
            }
        } else {
            Add-GuiLog "[2/7] TensorRT install skipped." -ForegroundColor Cyan
        }
        Set-GuiStepProgress -Step 3 -Title "TensorRT"
    }
    catch {
        Show-StageError -Stage "Step 2 - TensorRT" -ErrorRecord $_
        return
    }

    try {
        Set-GuiStepProgress -Step 4 -Title "cuDNN/zlib" -Running
        if (($installPlanKeys -contains "CUDNN") -or ($installPlanKeys -contains "ZLIB")) {
            Add-GuiLog "[3/7] Deploying CUDA runtime dependencies..." -ForegroundColor Yellow
            $cudaRootPath = Split-Path -Parent $cudaBinPath

            if ($installPlanKeys -contains "CUDNN") {
                $cudnnZipPath = Join-Path "$sourcePath\pkgs" $cudnnZipFile
                if (-not (Test-Path $cudnnZipPath)) {
                    throw "cuDNN package not found: $cudnnZipPath"
                }

                $cudnnTempDir = Join-Path $env:TEMP ("cudnn_extract_" + [guid]::NewGuid().ToString("N"))
                Set-GuiSubProgress -Percent 0
                Expand-ArchiveWithGuiProgress -ZipPath $cudnnZipPath -DestinationPath $cudnnTempDir -StartPercent 0 -EndPercent 45

                $cudnnRoot = Get-ChildItem -Path $cudnnTempDir -Directory -Recurse -ErrorAction SilentlyContinue |
                    Where-Object { (Test-Path (Join-Path $_.FullName "bin")) -and (Test-Path (Join-Path $_.FullName "include")) -and (Test-Path (Join-Path $_.FullName "lib")) } |
                    Select-Object -First 1

                if ($null -eq $cudnnRoot) {
                    Remove-Item -Path $cudnnTempDir -Recurse -Force -ErrorAction SilentlyContinue
                    throw "cuDNN root (bin/include/lib) not found inside archive."
                }

                # 압축 해제/복사가 길어질 수 있어 파일 단위로 진행률을 갱신한다.
                Copy-DirectoryFilesWithGuiProgress -SourceDir (Join-Path $cudnnRoot.FullName "bin") -DestinationDir $cudaBinPath -StartPercent 45 -EndPercent 70
                Copy-DirectoryFilesWithGuiProgress -SourceDir (Join-Path $cudnnRoot.FullName "include") -DestinationDir (Join-Path $cudaRootPath "include") -StartPercent 70 -EndPercent 88
                Copy-DirectoryFilesWithGuiProgress -SourceDir (Join-Path $cudnnRoot.FullName "lib") -DestinationDir (Join-Path $cudaRootPath "lib") -StartPercent 88 -EndPercent 98
                Remove-Item -Path $cudnnTempDir -Recurse -Force -ErrorAction SilentlyContinue
                Add-GuiLog "    [OK] cuDNN deployed to CUDA folders." -ForegroundColor Green
            }

            if ($installPlanKeys -contains "ZLIB") {
                $zlibSourcePath = Join-Path "$sourcePath\pkgs" $zlibDllFile
                $zlibTargetPath = Join-Path $cudaBinPath $zlibDllFile
                if (-not (Test-Path $zlibSourcePath)) {
                    throw "zlib package not found: $zlibSourcePath"
                }
                Copy-Item -Path $zlibSourcePath -Destination $zlibTargetPath -Force
                Set-GuiSubProgress -Percent 100
                Add-GuiLog "    [OK] zlibwapi.dll deployed." -ForegroundColor Green
            }
        } else {
            Add-GuiLog "[3/7] CUDA dependency deploy skipped." -ForegroundColor Cyan
        }
        Set-GuiStepProgress -Step 4 -Title "cuDNN/zlib"
    }
    catch {
        Show-StageError -Stage "Step 3 - cuDNN/zlib" -ErrorRecord $_
        return
    }

    try {
        Set-GuiStepProgress -Step 5 -Title "Python env" -Running
        Add-GuiLog "[4/7] Deploying Python environment ($envName)..." -ForegroundColor Yellow
        $fullEnvPath = "$activeCondaPath\envs\$envName"
        $envVersionFile = Join-Path $fullEnvPath ".pipeline_env_version"
        $desiredEnvStamp = "$CondaEnvVer|$cudaTrackTag"
        $needEnvUpdate = $true

        if (Test-Path $fullEnvPath) {
            if (Test-Path $envVersionFile) {
                $installedEnvVersionRaw = Get-Content -Path $envVersionFile -ErrorAction SilentlyContinue | Select-Object -First 1
                $installedEnvVersion = if ($null -eq $installedEnvVersionRaw) { "" } else { $installedEnvVersionRaw.ToString().Trim() }
                if ($installedEnvVersion -eq $desiredEnvStamp) {
                    $needEnvUpdate = $false
                    Add-GuiLog "    [SKIP] Environment is already up to date: $desiredEnvStamp" -ForegroundColor Cyan
                }
            }
        }

        if ($needEnvUpdate) {
            if (Test-Path $fullEnvPath) {
                Set-GuiSubProgress -Percent 20
                Remove-Item -Path $fullEnvPath -Recurse -Force
            }
            New-Item -ItemType Directory -Force -Path $fullEnvPath | Out-Null
            Set-GuiSubProgress -Percent 0
            Expand-ArchiveWithGuiProgress -ZipPath "$sourcePath\pkgs\$envZipFile" -DestinationPath $fullEnvPath -StartPercent 0 -EndPercent 95
            Set-Content -Path $envVersionFile -Value $desiredEnvStamp -Encoding ASCII -Force
            Add-GuiLog "    [OK] Environment deployed: $desiredEnvStamp" -ForegroundColor Green
        }
        Set-GuiStepProgress -Step 5 -Title "Python env"
    }
    catch {
        Show-StageError -Stage "Step 4 - Python env" -ErrorRecord $_
        return
    }

    if ($isTrtInstalled -and -not [string]::IsNullOrWhiteSpace($foundTrtPath)) {
        $desiredTrtPath = $foundTrtPath
    } else {
        $desiredTrtPath = $trtDest
    }

    try {
        Set-GuiStepProgress -Step 6 -Title "PATH" -Running
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
            Add-GuiLog "[5/7] Updating user PATH for CUDA/TensorRT..." -ForegroundColor Yellow
            $isChanged = $false
            foreach ($path in $targetPaths) {
                if ((Test-Path $path) -and ($currentPath -notmatch [regex]::Escape($path))) {
                    $currentPath = $currentPath.TrimEnd(';') + ";" + $path
                    $isChanged = $true
                    Add-GuiLog "    [ADD] $path" -ForegroundColor Green
                }
            }
            if ($isChanged) {
                [System.Environment]::SetEnvironmentVariable("Path", $currentPath, "User")
            }
        } else {
            Add-GuiLog "[5/7] PATH update skipped (already up to date)." -ForegroundColor Cyan
        }
        Set-GuiStepProgress -Step 6 -Title "PATH"
    }
    catch {
        Show-StageError -Stage "Step 5 - PATH" -ErrorRecord $_
        return
    }

    try {
        Set-GuiStepProgress -Step 7 -Title "TRT_PATH" -Running
        $currentTrtPath = [System.Environment]::GetEnvironmentVariable("TRT_PATH", "User")
        $needTrtPathUpdate = ($installPlanKeys -contains "TRT") -or [string]::IsNullOrWhiteSpace($currentTrtPath) -or ($currentTrtPath -ne $desiredTrtPath)
        if ($needTrtPathUpdate) {
            Add-GuiLog "[6/7] Setting TRT_PATH..." -ForegroundColor Yellow
            [System.Environment]::SetEnvironmentVariable("TRT_PATH", $desiredTrtPath, "User")
        } else {
            Add-GuiLog "[6/7] TRT_PATH update skipped." -ForegroundColor Cyan
        }
        Set-GuiStepProgress -Step 7 -Title "TRT_PATH"
    }
    catch {
        Show-StageError -Stage "Step 6 - TRT_PATH" -ErrorRecord $_
        return
    }

    try {
        Set-GuiStepProgress -Step 8 -Title "Eval Tools" -Running
        Add-GuiLog "[7/7] Deploying Eval Tools..." -ForegroundColor Yellow
        $evalToolsVersionFile = Join-Path $evalToolsDest ".pipeline_evaltools_version"
        $desiredEvalToolsStamp = "$EvaltoolsVer"
        $needEvalToolsUpdate = $true

        if (Test-Path $evalToolsDest) {
            if (Test-Path $evalToolsVersionFile) {
                $installedEvalToolsVersionRaw = Get-Content -Path $evalToolsVersionFile -ErrorAction SilentlyContinue | Select-Object -First 1
                $installedEvalToolsVersion = if ($null -eq $installedEvalToolsVersionRaw) { "" } else { $installedEvalToolsVersionRaw.ToString().Trim() }
                if ($installedEvalToolsVersion -eq $desiredEvalToolsStamp) {
                    $needEvalToolsUpdate = $false
                    Add-GuiLog "    [SKIP] Eval Tools are already up to date: $desiredEvalToolsStamp" -ForegroundColor Cyan
                }
            }
        }

        if ($needEvalToolsUpdate) {
            if (-not (Test-Path "$sourcePath\pkgs\$evalToolsZipFile")) {
                throw "Eval Tools package not found: $sourcePath\pkgs\$evalToolsZipFile"
            }

            if (Test-Path $evalToolsDest) {
                Set-GuiSubProgress -Percent 20
                Remove-Item -Path $evalToolsDest -Recurse -Force
            }

            New-Item -ItemType Directory -Force -Path $evalToolsDest | Out-Null
            Set-GuiSubProgress -Percent 0
            Expand-ArchiveWithGuiProgress -ZipPath "$sourcePath\pkgs\$evalToolsZipFile" -DestinationPath "$evalToolsDest" -StartPercent 0 -EndPercent 95
            Set-Content -Path $evalToolsVersionFile -Value $desiredEvalToolsStamp -Encoding ASCII -Force
            Add-GuiLog "    [OK] Eval Tools deployed: $evalToolsDest ($desiredEvalToolsStamp)" -ForegroundColor Green
        }
        Set-GuiStepProgress -Step 8 -Title "Eval Tools"
    }
    catch {
        Show-StageError -Stage "Step 7 - Eval Tools" -ErrorRecord $_
        return
    }

    Add-GuiLog ""
    Add-GuiLog "#============================================================#" -ForegroundColor Cyan
    Add-GuiLog "# [DONE] All setup steps completed                           #" -ForegroundColor Cyan
    Add-GuiLog "#============================================================#" -ForegroundColor Cyan
    Add-GuiLog "Open a new terminal to apply PATH changes." -ForegroundColor Cyan
    Add-GuiLog "Conda command: conda activate $envName" -ForegroundColor Cyan
    Set-GuiStepProgress -Step 8 -Title "Completed"
    Add-GuiLog "All setup steps completed successfully."
    Wait-GuiLogWindowClose
}
