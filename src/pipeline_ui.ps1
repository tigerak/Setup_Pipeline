Set-StrictMode -Version Latest

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

function New-SetupPipelineUi {
    $ui = [pscustomobject]@{
        GuiLogForm = $null
        GuiLogRichTextBox = $null
        GuiContinueButton = $null
        GuiCancelButton = $null
        GuiCloseButton = $null
        GuiStepStatusLabel = $null
        GuiStepProgressBar = $null
        GuiSubStatusLabel = $null
        GuiSubProgressBar = $null
        GuiDecision = $null
        CurrentStep = 0
    }

    $ui | Add-Member -MemberType ScriptMethod -Name Initialize -Value {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing

        $this.GuiLogForm = New-Object System.Windows.Forms.Form
        $this.GuiLogForm.Text = "Setup Pipeline Progress"
        $this.GuiLogForm.StartPosition = "CenterScreen"
        $this.GuiLogForm.Size = New-Object System.Drawing.Size(980, 680)
        $this.GuiLogForm.TopMost = $true

        $this.GuiLogRichTextBox = New-Object System.Windows.Forms.RichTextBox
        $this.GuiLogRichTextBox.ReadOnly = $true
        $this.GuiLogRichTextBox.Dock = "Fill"
        $this.GuiLogRichTextBox.Font = New-Object System.Drawing.Font("Consolas", 10)
        $this.GuiLogRichTextBox.BackColor = [System.Drawing.Color]::White
        $this.GuiLogRichTextBox.ForeColor = [System.Drawing.Color]::Black

        $buttonPanel = New-Object System.Windows.Forms.Panel
        $buttonPanel.Dock = "Bottom"
        $buttonPanel.Height = 110

        $this.GuiStepStatusLabel = New-Object System.Windows.Forms.Label
        $this.GuiStepStatusLabel.Text = "Step progress: waiting"
        $this.GuiStepStatusLabel.AutoSize = $false
        $this.GuiStepStatusLabel.Width = 520
        $this.GuiStepStatusLabel.Height = 18
        $this.GuiStepStatusLabel.Left = 10
        $this.GuiStepStatusLabel.Top = 8
        $this.GuiStepStatusLabel.Font = New-Object System.Drawing.Font("Consolas", 9)

        $this.GuiStepProgressBar = New-Object System.Windows.Forms.ProgressBar
        $this.GuiStepProgressBar.Minimum = 0
        $this.GuiStepProgressBar.Maximum = 100
        $this.GuiStepProgressBar.Value = 0
        $this.GuiStepProgressBar.Width = 520
        $this.GuiStepProgressBar.Height = 18
        $this.GuiStepProgressBar.Left = 10
        $this.GuiStepProgressBar.Top = 28

        $this.GuiSubStatusLabel = New-Object System.Windows.Forms.Label
        $this.GuiSubStatusLabel.Text = "Sub progress: 0%"
        $this.GuiSubStatusLabel.AutoSize = $false
        $this.GuiSubStatusLabel.Width = 520
        $this.GuiSubStatusLabel.Height = 16
        $this.GuiSubStatusLabel.Left = 10
        $this.GuiSubStatusLabel.Top = 52
        $this.GuiSubStatusLabel.Font = New-Object System.Drawing.Font("Consolas", 9)

        $this.GuiSubProgressBar = New-Object System.Windows.Forms.ProgressBar
        $this.GuiSubProgressBar.Minimum = 0
        $this.GuiSubProgressBar.Maximum = 100
        $this.GuiSubProgressBar.Value = 0
        $this.GuiSubProgressBar.Width = 520
        $this.GuiSubProgressBar.Height = 18
        $this.GuiSubProgressBar.Left = 10
        $this.GuiSubProgressBar.Top = 72

        $setButtonStyle = {
            param([System.Windows.Forms.Button]$Button)

            $Button.FlatStyle = [System.Windows.Forms.FlatStyle]::Standard
            $Button.UseVisualStyleBackColor = $false
            $Button.Font = New-Object System.Drawing.Font("Segoe UI", 9)

            $enabledBackColor = [System.Drawing.SystemColors]::Control
            $enabledForeColor = [System.Drawing.SystemColors]::ControlText
            $disabledBackColor = [System.Drawing.SystemColors]::ControlLight
            $disabledForeColor = [System.Drawing.SystemColors]::GrayText

            $Button.Add_EnabledChanged({
                $button = $this
                if ($button.Enabled) {
                    $button.BackColor = [System.Drawing.SystemColors]::Control
                    $button.ForeColor = [System.Drawing.SystemColors]::ControlText
                }
                else {
                    $button.BackColor = [System.Drawing.SystemColors]::ControlLight
                    $button.ForeColor = [System.Drawing.SystemColors]::GrayText
                }
            })

            if ($Button.Enabled) {
                $Button.BackColor = $enabledBackColor
                $Button.ForeColor = $enabledForeColor
            }
            else {
                $Button.BackColor = $disabledBackColor
                $Button.ForeColor = $disabledForeColor
            }
        }

        $this.GuiContinueButton = New-Object System.Windows.Forms.Button
        $this.GuiContinueButton.Text = "Continue"
        $this.GuiContinueButton.Width = 110
        $this.GuiContinueButton.Height = 30
        $this.GuiContinueButton.Left = 560
        $this.GuiContinueButton.Top = 55
        $this.GuiContinueButton.Visible = $false
        & $setButtonStyle $this.GuiContinueButton
        $this.GuiContinueButton.Tag = $this
        $this.GuiContinueButton.Add_Click({
            $this.Tag.GuiDecision = $true
        })

        $this.GuiCancelButton = New-Object System.Windows.Forms.Button
        $this.GuiCancelButton.Text = "Cancel"
        $this.GuiCancelButton.Width = 110
        $this.GuiCancelButton.Height = 30
        $this.GuiCancelButton.Left = 680
        $this.GuiCancelButton.Top = 55
        $this.GuiCancelButton.Visible = $false
        & $setButtonStyle $this.GuiCancelButton
        $this.GuiCancelButton.Tag = $this
        $this.GuiCancelButton.Add_Click({
            $this.Tag.GuiDecision = $false
        })

        $this.GuiCloseButton = New-Object System.Windows.Forms.Button
        $this.GuiCloseButton.Text = "Close"
        $this.GuiCloseButton.Width = 110
        $this.GuiCloseButton.Height = 30
        $this.GuiCloseButton.Left = 800
        $this.GuiCloseButton.Top = 55
        $this.GuiCloseButton.Enabled = $false
        & $setButtonStyle $this.GuiCloseButton
        $this.GuiCloseButton.Tag = $this
        $this.GuiCloseButton.Add_Click({
            if ($null -ne $this.Tag.GuiLogForm -and -not $this.Tag.GuiLogForm.IsDisposed) {
                $this.Tag.GuiLogForm.Close()
            }
        })

        $buttonPanel.Controls.Add($this.GuiStepStatusLabel)
        $buttonPanel.Controls.Add($this.GuiStepProgressBar)
        $buttonPanel.Controls.Add($this.GuiSubStatusLabel)
        $buttonPanel.Controls.Add($this.GuiSubProgressBar)
        $buttonPanel.Controls.Add($this.GuiContinueButton)
        $buttonPanel.Controls.Add($this.GuiCancelButton)
        $buttonPanel.Controls.Add($this.GuiCloseButton)

        $this.GuiLogForm.Controls.Add($this.GuiLogRichTextBox)
        $this.GuiLogForm.Controls.Add($buttonPanel)
        [void]$this.GuiLogForm.Show()

        for ($i = 0; $i -lt 3; $i++) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 50
        }
    }

    $ui | Add-Member -MemberType ScriptMethod -Name SetStep -Value {
        param(
            [int]$Step,
            [string]$Title,
            [int]$TotalSteps = 6,
            [switch]$Running
        )

        if (($null -eq $this.GuiStepProgressBar) -or ($null -eq $this.GuiStepStatusLabel)) {
            return
        }

        $this.GuiStepProgressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
        $this.CurrentStep = $Step
        if ($Running) {
            $stepStartPercent = [int](($Step - 1) * 100 / $TotalSteps)
            $this.GuiStepProgressBar.Value = $stepStartPercent
            $this.GuiStepStatusLabel.Text = "Step $($Step)/$($TotalSteps): $Title..."
            $this.GuiSubProgressBar.Value = 0
            $this.GuiSubStatusLabel.Text = "Sub progress: 0%"
        }
        else {
            $stepEndPercent = [int]($Step * 100 / $TotalSteps)
            $this.GuiStepProgressBar.Value = $stepEndPercent
            $this.GuiStepStatusLabel.Text = "Step $($Step)/$($TotalSteps): $Title"
            $this.GuiSubProgressBar.Value = 100
            $this.GuiSubStatusLabel.Text = "Sub progress: 100%"
        }
        [System.Windows.Forms.Application]::DoEvents()
    }

    $ui | Add-Member -MemberType ScriptMethod -Name SetSubProgress -Value {
        param([int]$Percent)

        if ($null -eq $this.GuiSubProgressBar) { return }
        $this.GuiSubProgressBar.Value = [Math]::Max(0, [Math]::Min($Percent, 100))
        $this.GuiSubStatusLabel.Text = "Sub progress: $($this.GuiSubProgressBar.Value)%"

        if (($null -ne $this.CurrentStep) -and ($this.CurrentStep -gt 0)) {
            $totalSteps = 6
            $stepStart = [int](($this.CurrentStep - 1) * 100 / $totalSteps)
            $stepEnd = [int]($this.CurrentStep * 100 / $totalSteps)
            $stepRange = $stepEnd - $stepStart
            $subPercent = $this.GuiSubProgressBar.Value
            $stepValue = [int]($stepStart + ($stepRange * $subPercent / 100))
            $this.GuiStepProgressBar.Value = $stepValue
        }

        [System.Windows.Forms.Application]::DoEvents()
    }

    $ui | Add-Member -MemberType ScriptMethod -Name Log -Value {
        param(
            [string]$Message,
            [System.ConsoleColor]$ForegroundColor = [System.ConsoleColor]::Gray,
            [switch]$NoNewline
        )

        if ($null -ne $this.GuiLogRichTextBox -and -not $this.GuiLogForm.IsDisposed) {
            $line = if ($null -eq $Message) { "" } else { $Message }
            $color = Convert-ConsoleColorToDrawingColor -Color $ForegroundColor
            $this.GuiLogRichTextBox.SelectionStart = $this.GuiLogRichTextBox.TextLength
            $this.GuiLogRichTextBox.SelectionLength = 0
            $this.GuiLogRichTextBox.SelectionColor = $color

            if ($NoNewline) {
                $this.GuiLogRichTextBox.AppendText($line)
            }
            else {
                $this.GuiLogRichTextBox.AppendText($line + [Environment]::NewLine)
            }

            $this.GuiLogRichTextBox.SelectionColor = [System.Drawing.Color]::Black
            $this.GuiLogRichTextBox.SelectionStart = $this.GuiLogRichTextBox.TextLength
            $this.GuiLogRichTextBox.ScrollToCaret()
            [System.Windows.Forms.Application]::DoEvents()
        }
    }

    $ui | Add-Member -MemberType ScriptMethod -Name RequestContinue -Value {
        param([string]$Prompt)

        $this.SetTopMost($true)
        $this.Log("")
        $this.Log($Prompt)
        $this.Log("Use Continue or Cancel in the same window.")

        $this.GuiDecision = $null
        $this.GuiContinueButton.Visible = $true
        $this.GuiCancelButton.Visible = $true

        while ($null -eq $this.GuiDecision -and -not $this.GuiLogForm.IsDisposed) {
            [System.Windows.Forms.Application]::DoEvents()
        }

        $this.GuiContinueButton.Visible = $false
        $this.GuiCancelButton.Visible = $false
        $this.SetTopMost($false)

        return ($this.GuiDecision -eq $true)
    }

    $ui | Add-Member -MemberType ScriptMethod -Name ShowInstallDecision -Value {
        param(
            [string]$StepTitle,
            [string[]]$DetailLines,
            [bool]$IsWarning = $false
        )

        $warningAccentColor = [System.Drawing.Color]::FromArgb(150, 52, 42)

        # 일반 설치 단계용 팝업.
        $form = New-Object System.Windows.Forms.Form
        $form.Text = if ($IsWarning) { "WARNING - $StepTitle" } else { "Setup Confirmation - $StepTitle" }
        $form.Width = 860
        $form.Height = 470
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $form.TopMost = $true
        $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false

        $titleLabel = New-Object System.Windows.Forms.Label
        $titleLabel.AutoSize = $true
        $titleLabel.Left = 16
        $titleLabel.Top = 14
        $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
        $titleLabel.Text = if ($IsWarning) { "Warning: Destructive Action Confirmation" } else { "Install Step Confirmation" }
        if ($IsWarning) {
            $titleLabel.ForeColor = $warningAccentColor
        }
        $form.Controls.Add($titleLabel)

        $stepLabel = New-Object System.Windows.Forms.Label
        $stepLabel.AutoSize = $true
        $stepLabel.Left = 16
        $stepLabel.Top = 42
        $stepLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
        $stepLabel.Text = "Step: $StepTitle"
        $form.Controls.Add($stepLabel)

        $hintLabel = New-Object System.Windows.Forms.Label
        $hintLabel.AutoSize = $true
        $hintLabel.Left = 16
        $hintLabel.Top = 64
        if ($IsWarning) {
            $hintLabel.ForeColor = $warningAccentColor
            $hintLabel.Text = "This action permanently deletes existing files/environments. Review details carefully before continuing."
        }
        else {
            $hintLabel.ForeColor = [System.Drawing.Color]::DimGray
            $hintLabel.Text = "Review the step details below, then choose Install or Abort."
        }
        $form.Controls.Add($hintLabel)

        $detailView = New-Object System.Windows.Forms.ListView
        $detailView.Left = 16
        $detailView.Top = 92
        $detailView.Width = 810
        $detailView.Height = 245
        $detailView.View = [System.Windows.Forms.View]::Details
        $detailView.FullRowSelect = $true
        $detailView.GridLines = $true
        $detailView.HideSelection = $false
        $detailView.Font = New-Object System.Drawing.Font("Segoe UI", 9)
        $detailRowImageList = New-Object System.Windows.Forms.ImageList
        $detailRowImageList.ImageSize = New-Object System.Drawing.Size(1, 24)
        $detailView.SmallImageList = $detailRowImageList

        [void]$detailView.Columns.Add("Field", 220)
        [void]$detailView.Columns.Add("Details", 560)

        foreach ($rawLine in $DetailLines) {
            $line = if ($null -eq $rawLine) { "" } else { $rawLine.ToString().Trim() }
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            $itemName = "Note"
            $itemValue = $line
            if ($line -match '^([^:]{1,80}):\s*(.*)$') {
                $itemName = $matches[1].Trim()
                $itemValue = $matches[2].Trim()
            }

            $row = New-Object System.Windows.Forms.ListViewItem($itemName)
            [void]$row.SubItems.Add($itemValue)
            [void]$detailView.Items.Add($row)
        }

        if ($detailView.Items.Count -eq 0) {
            $row = New-Object System.Windows.Forms.ListViewItem("Note")
            [void]$row.SubItems.Add("No step details provided.")
            [void]$detailView.Items.Add($row)
        }

        $form.Controls.Add($detailView)

        $actionHintLabel = New-Object System.Windows.Forms.Label
        $actionHintLabel.AutoSize = $true
        $actionHintLabel.Left = 16
        $actionHintLabel.Top = 350
        $actionHintLabel.ForeColor = [System.Drawing.Color]::DimGray
        if ($IsWarning) {
            $actionHintLabel.Text = "Install: proceed with deletion and reinstall   |   Skip: leave this step untouched   |   Abort: stop the whole setup"
        }
        else {
            $actionHintLabel.Text = "Install: run this step   |   Skip: leave this step untouched   |   Abort: stop the whole setup"
        }
        $form.Controls.Add($actionHintLabel)

        $btnInstall = New-Object System.Windows.Forms.Button
        $btnInstall.Text = if ($IsWarning) { "Delete + Install" } else { "Install" }
        $btnInstall.Width = 140
        $btnInstall.Height = 32
        $btnInstall.Left = 430
        $btnInstall.Top = 374
        if ($IsWarning) {
            $btnInstall.ForeColor = $warningAccentColor
        }
        $btnInstall.Add_Click({
            $form.DialogResult = [System.Windows.Forms.DialogResult]::Yes
            $form.Close()
        })
        $form.Controls.Add($btnInstall)

        $btnSkip = New-Object System.Windows.Forms.Button
        $btnSkip.Text = "Skip"
        $btnSkip.Width = 110
        $btnSkip.Height = 32
        $btnSkip.Left = 585
        $btnSkip.Top = 374
        $btnSkip.Add_Click({
            $form.DialogResult = [System.Windows.Forms.DialogResult]::Retry
            $form.Close()
        })
        $form.Controls.Add($btnSkip)

        $btnAbort = New-Object System.Windows.Forms.Button
        $btnAbort.Text = "Abort"
        $btnAbort.Width = 100
        $btnAbort.Height = 32
        $btnAbort.Left = 710
        $btnAbort.Top = 374
        $btnAbort.Add_Click({
            $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
            $form.Close()
        })
        $form.Controls.Add($btnAbort)

        $form.Add_FormClosing({
            param($sender, $e)
            if ($sender.DialogResult -eq [System.Windows.Forms.DialogResult]::None) {
                $sender.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
            }
        })

        $form.AcceptButton = $btnInstall
        $form.CancelButton = $btnAbort

        $owner = $null
        if ($null -ne $this.GuiLogForm -and -not $this.GuiLogForm.IsDisposed) {
            $owner = $this.GuiLogForm
        }

        $dialogResult = if ($null -ne $owner) { $form.ShowDialog($owner) } else { $form.ShowDialog() }

        switch ($dialogResult) {
            ([System.Windows.Forms.DialogResult]::Yes) { return "Install" }
            ([System.Windows.Forms.DialogResult]::Retry) { return "Skip" }
            default { return "Abort" }
        }
    }

    $ui | Add-Member -MemberType ScriptMethod -Name ShowDownloadAndInstallDecision -Value {
        param(
            [string]$StepTitle,
            [string[]]$DetailLines
        )

        # 다운로드 + 설치가 필요한 단계용 팝업.
        $form = New-Object System.Windows.Forms.Form
        $form.Text = "Required files missing - $StepTitle"
        $form.Width = 1040
        $form.Height = 620
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $form.TopMost = $true
        $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false

        $titleLabel = New-Object System.Windows.Forms.Label
        $titleLabel.AutoSize = $true
        $titleLabel.Left = 16
        $titleLabel.Top = 14
        $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
        $titleLabel.Text = "Required files missing" 
        $titleLabel.ForeColor = [System.Drawing.Color]::DarkOrange
        $form.Controls.Add($titleLabel)

        $stepLabel = New-Object System.Windows.Forms.Label
        $stepLabel.AutoSize = $true
        $stepLabel.Left = 16
        $stepLabel.Top = 42
        $stepLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
        $stepLabel.Text = "Step: $StepTitle"
        $form.Controls.Add($stepLabel)

        $hintLabel = New-Object System.Windows.Forms.Label
        $hintLabel.AutoSize = $true
        $hintLabel.Left = 16
        $hintLabel.Top = 64
        $hintLabel.ForeColor = [System.Drawing.Color]::DimGray
        $hintLabel.Text = "The files below are missing. Download them now and continue installation?"
        $form.Controls.Add($hintLabel)

        $detailView = New-Object System.Windows.Forms.ListView
        $detailView.Left = 16
        $detailView.Top = 92
        $detailView.Width = 990
        $detailView.Height = 400
        $detailView.View = [System.Windows.Forms.View]::Details
        $detailView.FullRowSelect = $true
        $detailView.GridLines = $true
        $detailView.HideSelection = $false
        $detailView.Font = New-Object System.Drawing.Font("Segoe UI", 9)
        $detailRowImageList = New-Object System.Windows.Forms.ImageList
        $detailRowImageList.ImageSize = New-Object System.Drawing.Size(1, 24)
        $detailView.SmallImageList = $detailRowImageList

        [void]$detailView.Columns.Add("Field", 250)
        [void]$detailView.Columns.Add("Details", 700)

        foreach ($rawLine in $DetailLines) {
            $line = if ($null -eq $rawLine) { "" } else { $rawLine.ToString().Trim() }
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            $itemName = "Note"
            $itemValue = $line
            if ($line -match '^([^:]{1,80}):\s*(.*)$') {
                $itemName = $matches[1].Trim()
                $itemValue = $matches[2].Trim()
            }

            $row = New-Object System.Windows.Forms.ListViewItem($itemName)
            [void]$row.SubItems.Add($itemValue)
            [void]$detailView.Items.Add($row)
        }

        if ($detailView.Items.Count -eq 0) {
            $row = New-Object System.Windows.Forms.ListViewItem("Note")
            [void]$row.SubItems.Add("No missing file details provided.")
            [void]$detailView.Items.Add($row)
        }

        $form.Controls.Add($detailView)

        $actionHintLabel = New-Object System.Windows.Forms.Label
        $actionHintLabel.AutoSize = $true
        $actionHintLabel.Left = 16
        $actionHintLabel.Top = 510
        $actionHintLabel.ForeColor = [System.Drawing.Color]::DimGray
        $actionHintLabel.Text = "Download + Install: fetch the missing files and continue installation   |   Cancel: stop this download and return to step choice"
        $form.Controls.Add($actionHintLabel)

        $btnInstall = New-Object System.Windows.Forms.Button
        $btnInstall.Text = "Download + Install"
        $btnInstall.Width = 170
        $btnInstall.Height = 32
        $btnInstall.Left = 680
        $btnInstall.Top = 540
        $btnInstall.DialogResult = [System.Windows.Forms.DialogResult]::Yes
        $form.Controls.Add($btnInstall)

        $btnCancel = New-Object System.Windows.Forms.Button
        $btnCancel.Text = "Cancel"
        $btnCancel.Width = 100
        $btnCancel.Height = 32
        $btnCancel.Left = 870
        $btnCancel.Top = 540
        $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $form.Controls.Add($btnCancel)

        $form.Add_FormClosing({
            param($sender, $e)
            if ($sender.DialogResult -eq [System.Windows.Forms.DialogResult]::None) {
                $sender.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
            }
        })

        $form.AcceptButton = $btnInstall
        $form.CancelButton = $btnCancel

        $owner = $null
        if ($null -ne $this.GuiLogForm -and -not $this.GuiLogForm.IsDisposed) {
            $owner = $this.GuiLogForm
        }

        $dialogResult = if ($null -ne $owner) { $form.ShowDialog($owner) } else { $form.ShowDialog() }

        switch ($dialogResult) {
            ([System.Windows.Forms.DialogResult]::Yes) { return "Install" }
            default { return "Cancel" }
        }
    }

    $ui | Add-Member -MemberType ScriptMethod -Name ShowStepInstallDecision -Value {
        param(
            [string]$StepTitle,
            [string[]]$DetailLines,
            [bool]$IsWarning = $false
        )

        return $this.ShowInstallDecision($StepTitle, $DetailLines, $IsWarning)
    }

    $ui | Add-Member -MemberType ScriptMethod -Name SelectTensorRTProfile -Value {
        param(
            [string]$DetectedCudaVersion,
            [object[]]$Options,
            [int]$DefaultOptionNumber = 1
        )

        # TensorRT 버전/경로 선택 전용 대화상자.
        # 옵션은 config에서 구성되고, UI는 선택만 수행한다.
        $form = New-Object System.Windows.Forms.Form
        $form.Text = "TensorRT Version Selection"
        $form.Width = 980
        $form.Height = 430
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $form.TopMost = $true
        $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false

        $label = New-Object System.Windows.Forms.Label
        $label.AutoSize = $false
        $label.Left = 16
        $label.Top = 14
        $label.Width = 930
        $label.Height = 44
        $label.Text = "Detected CUDA: $DetectedCudaVersion`r`nSelect TensorRT profile to install:"
        $form.Controls.Add($label)

        $hintLabel = New-Object System.Windows.Forms.Label
        $hintLabel.AutoSize = $true
        $hintLabel.Left = 16
        $hintLabel.Top = 66
        $hintLabel.Text = "Columns: Option = selection number, Profile = TensorRT version profile, Destination = install path, Package = zip file name"
        $form.Controls.Add($hintLabel)

        $recommendLabel = New-Object System.Windows.Forms.Label
        $recommendLabel.AutoSize = $true
        $recommendLabel.Left = 16
        $recommendLabel.Top = ($hintLabel.Bottom + 8)
        $recommendLabel.ForeColor = [System.Drawing.Color]::DarkBlue
        $recommendLabel.Text = "Note: The preselected row is the recommended TensorRT version for this system."
        $form.Controls.Add($recommendLabel)

        $listView = New-Object System.Windows.Forms.ListView
        $listView.Left = 16
        $listView.Top = ($recommendLabel.Bottom + 10)
        $listView.Width = 930
        $listView.Height = 236
        $listView.View = [System.Windows.Forms.View]::Details
        $listView.FullRowSelect = $true
        $listView.GridLines = $true
        $listView.HideSelection = $false
        $listView.Font = New-Object System.Drawing.Font("Segoe UI", 10)

        # ListView Details 모드의 행 간격은 직접 지정이 제한적이라
        # SmallImageList 높이를 키워 선택 행 높이를 늘린다.
        $rowHeightImageList = New-Object System.Windows.Forms.ImageList
        $rowHeightImageList.ImageSize = New-Object System.Drawing.Size(1, 26)
        $listView.SmallImageList = $rowHeightImageList

        [void]$listView.Columns.Add("Option", 70)
        [void]$listView.Columns.Add("Profile", 210)
        [void]$listView.Columns.Add("Destination", 430)
        [void]$listView.Columns.Add("Package", 200)

        foreach ($opt in $Options) {
            $item = New-Object System.Windows.Forms.ListViewItem([string]$opt.OptionNo)
            [void]$item.SubItems.Add([string]$opt.Name)
            [void]$item.SubItems.Add([string]$opt.Destination)
            [void]$item.SubItems.Add([string]$opt.ZipFile)
            $item.Tag = $opt
            [void]$listView.Items.Add($item)
        }

        $defaultIndex = $DefaultOptionNumber - 1
        if ($defaultIndex -ge 0 -and $defaultIndex -lt $listView.Items.Count) {
            $listView.Items[$defaultIndex].Selected = $true
            $listView.Items[$defaultIndex].Focused = $true
        }
        $form.Controls.Add($listView)

        $btnOk = New-Object System.Windows.Forms.Button
        $btnOk.Text = "OK"
        $btnOk.Width = 100
        $btnOk.Height = 32
        $btnOk.Left = 730
        $btnOk.Top = 355
        $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Controls.Add($btnOk)

        $btnCancel = New-Object System.Windows.Forms.Button
        $btnCancel.Text = "Cancel"
        $btnCancel.Width = 100
        $btnCancel.Height = 32
        $btnCancel.Left = 846
        $btnCancel.Top = 355
        $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $form.Controls.Add($btnCancel)

        $form.AcceptButton = $btnOk
        $form.CancelButton = $btnCancel

        $btnOk.Add_Click({
                if ($listView.SelectedItems.Count -eq 0) {
                    [System.Windows.Forms.MessageBox]::Show(
                        "Select a TensorRT profile first.",
                        "Selection Required",
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Information
                    ) | Out-Null
                    $form.DialogResult = [System.Windows.Forms.DialogResult]::None
                }
            })

        $result = $form.ShowDialog()
        if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
            return $null
        }

        if ($listView.SelectedItems.Count -eq 0) {
            return $null
        }

        return $listView.SelectedItems[0].Tag
    }

    $ui | Add-Member -MemberType ScriptMethod -Name WaitClose -Value {
        if ($null -ne $this.GuiLogForm -and -not $this.GuiLogForm.IsDisposed) {
            $this.SetTopMost($false)
            $this.GuiCloseButton.Enabled = $true
            $this.GuiCloseButton.Visible = $true
            $this.Log("")
            $this.Log("Process finished. Review the log, then click Close to exit.")

            while (-not $this.GuiLogForm.IsDisposed) {
                [System.Windows.Forms.Application]::DoEvents()
            }
        }
    }

    $ui | Add-Member -MemberType ScriptMethod -Name WaitPaused -Value {
        if ($null -ne $this.GuiLogForm -and -not $this.GuiLogForm.IsDisposed) {
            $this.SetTopMost($false)
            $this.GuiCloseButton.Enabled = $true
            $this.GuiCloseButton.Visible = $true
            $this.Log("")
            $this.Log("Download-only mode: paused and waiting for explicit Install. Close to exit.")
            [System.Windows.Forms.Application]::DoEvents()
        }
    }

    $ui | Add-Member -MemberType ScriptMethod -Name SetTopMost -Value {
        param([bool]$Enabled)

        if (($null -eq $this.GuiLogForm) -or $this.GuiLogForm.IsDisposed) {
            return
        }

        $this.GuiLogForm.TopMost = $Enabled
        if ($Enabled) {
            $this.GuiLogForm.Activate()
        }
        [System.Windows.Forms.Application]::DoEvents()
    }

    $ui | Add-Member -MemberType ScriptMethod -Name ShowError -Value {
        param(
            [string]$Stage,
            $ErrorRecord
        )

        $msg = "[$Stage] Failed: $($ErrorRecord.Exception.Message)"
        $detailLines = @()

        if ($null -ne $ErrorRecord.Exception) {
            $detailLines += "Exception Type: $($ErrorRecord.Exception.GetType().FullName)"
        }

        if ($null -ne $ErrorRecord.InvocationInfo) {
            if (-not [string]::IsNullOrWhiteSpace($ErrorRecord.InvocationInfo.ScriptName)) {
                $detailLines += "Script: $($ErrorRecord.InvocationInfo.ScriptName)"
            }
            if ($ErrorRecord.InvocationInfo.ScriptLineNumber -gt 0) {
                $detailLines += "Line: $($ErrorRecord.InvocationInfo.ScriptLineNumber)"
            }
            if (-not [string]::IsNullOrWhiteSpace($ErrorRecord.InvocationInfo.PositionMessage)) {
                $detailLines += "Position: $($ErrorRecord.InvocationInfo.PositionMessage.Trim())"
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($ErrorRecord.ScriptStackTrace)) {
            $detailLines += "Stack:"
            $detailLines += ($ErrorRecord.ScriptStackTrace.Trim() -split "`r?`n")
        }

        $this.Log($msg, [System.ConsoleColor]::Red)
        foreach ($detailLine in $detailLines) {
            $this.Log($detailLine, [System.ConsoleColor]::DarkRed)
        }

        $this.SetTopMost($true)
        $dialogText = if ($detailLines.Count -gt 0) {
            $msg + "`n`n" + ($detailLines -join "`n")
        }
        else {
            $msg
        }
        [void][System.Windows.Forms.MessageBox]::Show($dialogText, "Setup Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        $this.WaitClose()
    }

    return $ui
}
