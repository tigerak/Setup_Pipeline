# ============================================================================
# PIPELINE_CORE.PS1 - Setup Pipeline 핵심 로직
# ============================================================================
# 역할: Miniconda, TensorRT, Python 환경 설치/배포 자동화
# 의존성: pipeline_config.ps1 (반드시 선행 로드)
# 인터페이스: GUI 모듈(WinForms) 또는 콘솔 모드 지원
# ============================================================================

Set-StrictMode -Version Latest

# ============================================================================
# 단계 1: 설정 모듈 검증
# ============================================================================
if ($null -eq $script:PipelineConfig) {
    throw "Pipeline config is not initialized. Dot-source pipeline_config.ps1 before pipeline_core.ps1."
}

# ============================================================================
# 전역 변수: 버전 및 UI 상태
# ============================================================================

# 배포 버전 관리 (config에서 상속)
# CondaEnvVer: Python visionAI 환경 버전 스탬프 (예: 260909)
# EvaltoolsVer: Eval_Tools 배포판 버전 (예: 260801)
$script:CondaEnvVer = $script:PipelineConfig.CondaEnvVer
$script:EvaltoolsVer = $script:PipelineConfig.EvaltoolsVer

# GUI 인터페이스 객체 (WinForms 또는 콘솔 래퍼)
# null = 콘솔 모드, 객체 = GUI 모드
$script:PipelineUi = $null

function Set-PipelineUi {
    param([object]$Ui)
    $script:PipelineUi = $Ui
}

function Write-UiLog {
    param(
        [string]$Message,
        [System.ConsoleColor]$ForegroundColor = [System.ConsoleColor]::Gray,
        [switch]$NoNewline
    )

    if ($null -ne $script:PipelineUi -and $script:PipelineUi.PSObject.Methods.Name -contains "Log") {
        $script:PipelineUi.Log($Message, $ForegroundColor, $NoNewline)
    }
}

function Set-UiStepProgress {
    param(
        [int]$Step,
        [string]$Title,
        [int]$TotalSteps = 6,
        [switch]$Running
    )

    if ($null -ne $script:PipelineUi -and $script:PipelineUi.PSObject.Methods.Name -contains "SetStep") {
        $script:PipelineUi.SetStep($Step, $Title, $TotalSteps, $Running)
    }
}

function Set-UiSubProgress {
    param([int]$Percent)

    if ($null -ne $script:PipelineUi -and $script:PipelineUi.PSObject.Methods.Name -contains "SetSubProgress") {
        $script:PipelineUi.SetSubProgress($Percent)
    }
}

function Request-UiContinue {
    param([string]$Prompt)

    if ($null -ne $script:PipelineUi -and $script:PipelineUi.PSObject.Methods.Name -contains "RequestContinue") {
        return $script:PipelineUi.RequestContinue($Prompt)
    }

    return $true
}

function Wait-UiLogWindowClose {
    if ($null -ne $script:PipelineUi -and $script:PipelineUi.PSObject.Methods.Name -contains "WaitClose") {
        $script:PipelineUi.WaitClose()
    }
}

function Show-UiError {
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)]$ErrorRecord
    )

    if ($null -ne $script:PipelineUi -and $script:PipelineUi.PSObject.Methods.Name -contains "ShowError") {
        $script:PipelineUi.ShowError($Stage, $ErrorRecord)
        return
    }
}

function Write-UiPrecheckSummary {
    param(
        [bool]$IsCondaInstalled,
        [string]$FoundCondaPath,
        [bool]$IsTrtInstalled,
        [string]$FoundTrtPath,
        [string]$ExpectedTrtPath
    )

    if ($null -eq $script:PipelineUi) {
        return
    }

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

    $script:PipelineUi.Log("[Pre-check Summary]")
    foreach ($line in ($condaStatus -split "`n")) { $script:PipelineUi.Log($line) }
    $script:PipelineUi.Log("")
    foreach ($line in ($trtStatus -split "`n")) { $script:PipelineUi.Log($line) }
    $script:PipelineUi.Log("")
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

function Find-7ZipExecutable {
    $command = Get-Command "7z" -ErrorAction SilentlyContinue
    if ($command -and -not [string]::IsNullOrWhiteSpace($command.Source)) {
        return $command.Source
    }

    $candidates = @(
        "C:\Program Files\7-Zip\7z.exe",
        "C:\Program Files (x86)\7-Zip\7z.exe"
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $null
}

function Install-7ZipIfMissing {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [string]$RemoteSourcePath = $null
    )

    $sevenZipPath = Find-7ZipExecutable
    if (-not [string]::IsNullOrWhiteSpace($sevenZipPath)) {
        Add-GuiLog "    [OK] 7-Zip detected: $sevenZipPath"
        return $sevenZipPath
    }

    $installerName = $script:PipelineConfig.SevenZipInstaller
    $installerPath = Join-Path (Join-Path $SourcePath "pkgs") $installerName
    if (-not (Test-Path -LiteralPath $installerPath)) {
        if (-not [string]::IsNullOrWhiteSpace($RemoteSourcePath)) {
            $syncResult = Sync-StepRequiredFiles -LocalRoot $SourcePath -RemoteRoot $RemoteSourcePath -RequiredFiles @("pkgs\$installerName") -StepTitle "Pre-check: 7-Zip" -Purpose "Download the 7-Zip installer needed for archive extraction before continuing pre-check" -RequestConfirmation:$true
            if ($syncResult -and (Test-Path -LiteralPath $installerPath)) {
                Add-GuiLog "    [SYNC] 7-Zip installer downloaded to local cache: $installerName" -ForegroundColor DarkYellow
            }
        }

        if (-not (Test-Path -LiteralPath $installerPath)) {
        throw "7-Zip installer not found: $installerPath"
        }
    }

    Add-GuiLog "    [MISS] 7-Zip not found. Installing $installerName..." -ForegroundColor Yellow
    Invoke-ProcessWithGuiProgress `
        -FilePath $installerPath `
        -ArgumentList @('/S') `
        -StartPercent 0 `
        -MaxPercentWhileRunning 10 `
        -TickMilliseconds 250

    $sevenZipPath = Find-7ZipExecutable
    if ([string]::IsNullOrWhiteSpace($sevenZipPath)) {
        throw "7-Zip installation finished, but 7z.exe was not found."
    }

    Add-GuiLog "    [OK] 7-Zip installed: $sevenZipPath" -ForegroundColor Green
    return $sevenZipPath
}

function Initialize-LocalPackageCacheLayout {
    param(
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [string]$RemoteRoot = $null
    )

    if ([string]::IsNullOrWhiteSpace($LocalRoot)) {
        throw "LocalRoot is required for cache layout."
    }

    $resolvedLocalRoot = [System.IO.Path]::GetFullPath($LocalRoot)
    $requiredDirs = @(
        "pkgs",
        "requirements",
        "requirements\wheelhouse"
    )

    foreach ($relativeDir in $requiredDirs) {
        $target = Join-Path $resolvedLocalRoot $relativeDir
        if (-not (Test-Path -LiteralPath $target)) {
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            Add-GuiLog "    [SYNC] Created local cache folder: $target" -ForegroundColor DarkGray
        }
    }

    return [pscustomobject]@{
        Root = $resolvedLocalRoot
        Pkgs = Join-Path $resolvedLocalRoot "pkgs"
        Requirements = Join-Path $resolvedLocalRoot "requirements"
        WheelhouseRoot = Join-Path $resolvedLocalRoot "requirements\wheelhouse\approved"
        WheelhouseCommon = Join-Path $resolvedLocalRoot "requirements\wheelhouse\approved\common"
        WheelhouseCu11 = Join-Path $resolvedLocalRoot "requirements\wheelhouse\approved\cu11"
        WheelhouseCu12 = Join-Path $resolvedLocalRoot "requirements\wheelhouse\approved\cu12"
    }
}

function Get-SourceArtifactFiles {
    param(
        [Parameter(Mandatory = $true)][string]$Directory
    )

    if (-not (Test-Path -LiteralPath $Directory)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $Directory -File |
            Where-Object {
                $_.Name.EndsWith('.tar.gz', [System.StringComparison]::OrdinalIgnoreCase) -or
                $_.Name.EndsWith('.tar.bz2', [System.StringComparison]::OrdinalIgnoreCase) -or
                $_.Name.EndsWith('.zip', [System.StringComparison]::OrdinalIgnoreCase)
            }
    )
}

function Get-BuildRequirementSpecsFromSourceArtifact {
    param(
        [Parameter(Mandatory = $true)][string]$ArtifactPath
    )

    $artifactName = [System.IO.Path]::GetFileName($ArtifactPath)
    $lowerName = $artifactName.ToLowerInvariant()

    if ($lowerName -like 'pycuda-*') {
        return @()
    }

    return @()
}

function Get-PinnedRequirementSpecFromLockFiles {
    param(
        [Parameter(Mandatory = $true)][string]$PackageName,
        [string[]]$LockFilePaths = @()
    )

    $normalizedPackageName = Normalize-PackageIdentifier -Value $PackageName
    if ([string]::IsNullOrWhiteSpace($normalizedPackageName)) {
        return $null
    }

    foreach ($lockFilePath in $LockFilePaths) {
        $records = @(Get-LockRequirementRecords -LockFilePath $lockFilePath)
        foreach ($record in $records) {
            if ($record.Name -eq $normalizedPackageName -and -not [string]::IsNullOrWhiteSpace($record.Version)) {
                return ('{0}=={1}' -f $record.Name, $record.Version)
            }
        }
    }

    return $null
}

function Download-BuildRequirementsForSourceArtifacts {
    param(
        [Parameter(Mandatory = $true)][string]$EnvironmentName,
        [Parameter(Mandatory = $true)][string]$ApprovedDirectory
    )

    $sourceArtifacts = @(Get-SourceArtifactFiles -Directory $ApprovedDirectory)
    if ($sourceArtifacts.Count -eq 0) {
        return
    }

    $requirementSpecs = @()
    foreach ($artifact in $sourceArtifacts) {
        $specs = @(Get-BuildRequirementSpecsFromSourceArtifact -ArtifactPath $artifact.FullName)
        foreach ($spec in $specs) {
            if (-not [string]::IsNullOrWhiteSpace($spec)) {
                $requirementSpecs += $spec
            }
        }
    }

    $uniqueRequirements = @($requirementSpecs | Select-Object -Unique)
    if ($uniqueRequirements.Count -eq 0) {
        return
    }

    $tempRequirementsPath = Join-Path ([System.IO.Path]::GetTempPath()) ("build_requirements_{0}.txt" -f [guid]::NewGuid().ToString("N"))
    Set-Content -LiteralPath $tempRequirementsPath -Value $uniqueRequirements -Encoding UTF8

    try {
        if (-not (Test-Path -LiteralPath $ApprovedDirectory)) {
            throw "Offline-only mode: source-artifact build dependency directory is missing: $ApprovedDirectory"
        }

        $localPackages = @(Get-ChildItem -LiteralPath $ApprovedDirectory -File -ErrorAction SilentlyContinue)
        if ($localPackages.Count -eq 0) {
            throw "Offline-only mode: no local wheelhouse packages are available in $ApprovedDirectory. Pre-populate the approved cache before installation."
        }

        Add-GuiLog "    [OFFLINE] Using existing local build dependency cache in $ApprovedDirectory; no external downloads are allowed." -ForegroundColor DarkYellow
    }
    finally {
        if (Test-Path -LiteralPath $tempRequirementsPath) {
            Remove-Item -LiteralPath $tempRequirementsPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Install-OfflineBuildRequirementsFromWheelhouses {
    param(
        [Parameter(Mandatory = $true)][string]$EnvironmentName,
        [Parameter(Mandatory = $true)][string[]]$ApprovedDirectories,
        [string[]]$LockFilePaths = @()
    )

    $requirementSpecs = @()

    foreach ($approvedDirectory in $ApprovedDirectories) {
        $sourceArtifacts = @(Get-SourceArtifactFiles -Directory $approvedDirectory)
        foreach ($artifact in $sourceArtifacts) {
            $specs = @(Get-BuildRequirementSpecsFromSourceArtifact -ArtifactPath $artifact.FullName)
            foreach ($spec in $specs) {
                if (-not [string]::IsNullOrWhiteSpace($spec)) {
                    $requirementSpecs += $spec.Trim()
                }
            }

            if ($artifact.Name.ToLowerInvariant() -like 'pycuda-*') {
                $numpySpec = Get-PinnedRequirementSpecFromLockFiles -PackageName 'numpy' -LockFilePaths $LockFilePaths
                if (-not [string]::IsNullOrWhiteSpace($numpySpec)) {
                    $requirementSpecs += $numpySpec
                }
                else {
                    throw "Offline-only mode: pycuda source build requires a pinned numpy package in the lock files, but none was found."
                }
            }
        }
    }

    $uniqueRequirements = @($requirementSpecs | Select-Object -Unique)
    if ($uniqueRequirements.Count -eq 0) {
        return
    }

    $findLinkArguments = @()
    foreach ($approvedDirectory in ($ApprovedDirectories | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $approvedDirectory)) {
            throw "Offline-only mode: build helper wheelhouse directory is missing: $approvedDirectory"
        }

        $findLinkArguments += @('--find-links', $approvedDirectory)
    }

    $helperRequirementsPath = Join-Path ([System.IO.Path]::GetTempPath()) ("offline_helper_requirements_{0}.txt" -f [guid]::NewGuid().ToString("N"))
    try {
        Set-Content -LiteralPath $helperRequirementsPath -Value $uniqueRequirements -Encoding UTF8
        Add-GuiLog "    [OFFLINE] Pre-installing source-build helpers from local wheelhouse: $($uniqueRequirements -join ', ')" -ForegroundColor DarkYellow

        $pipArguments = @(
            'run', '--live-stream', '-n', $EnvironmentName,
            'python', '-m', 'pip', 'install',
            '--progress-bar', 'on',
            '--no-index',
            '--no-build-isolation',
            '-r', $helperRequirementsPath
        ) + $findLinkArguments

        & $resolvedCondaExe $pipArguments 2>&1 | ForEach-Object {
            $line = $_.ToString()
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                Write-Host "        $line"
                Add-GuiLog "        $line" -ForegroundColor DarkGray
            }
        }

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to pre-install source-build helper packages in environment $EnvironmentName"
        }
    }
    finally {
        if (Test-Path -LiteralPath $helperRequirementsPath) {
            Remove-Item -LiteralPath $helperRequirementsPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Ensure-PycudaWheelInApprovedDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$EnvironmentName,
        [Parameter(Mandatory = $true)][string]$ApprovedDirectory
    )

    $pycudaSource = Get-ChildItem -LiteralPath $ApprovedDirectory -File |
        Where-Object {
            $_.Name -match '^pycuda-(?<version>[^-]+)\.(tar\.gz|tar\.bz2|zip)$'
        } |
        Select-Object -First 1

    if (-not $pycudaSource) {
        return
    }

    $pycudaWheel = Get-ChildItem -LiteralPath $ApprovedDirectory -File |
        Where-Object { $_.Name -like 'pycuda-*.whl' } |
        Select-Object -First 1

    if ($pycudaWheel) {
        Remove-Item -LiteralPath $pycudaSource.FullName -Force -ErrorAction SilentlyContinue
        return
    }

    $pycudaVersionMatch = [regex]::Match($pycudaSource.Name, '^pycuda-(?<version>.+?)(?:\.tar\.gz|\.tar\.bz2|\.zip)$')
    if (-not $pycudaVersionMatch.Success) {
        throw "Unable to parse pycuda version from source artifact: $($pycudaSource.Name)"
    }

    $pycudaVersion = $pycudaVersionMatch.Groups['version'].Value

    try {
        if (-not (Test-Path -LiteralPath $ApprovedDirectory)) {
            throw "Offline-only mode: approved wheelhouse directory is missing: $ApprovedDirectory"
        }

        $localWheelhouse = @(Get-ChildItem -LiteralPath $ApprovedDirectory -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'pycuda-*.whl' })
        if ($localWheelhouse.Count -gt 0) {
            Add-GuiLog "    [OFFLINE] Local pycuda wheel already present in $ApprovedDirectory; no external fetch is attempted." -ForegroundColor DarkYellow
            return
        }

        throw "Offline-only mode: pycuda wheel is not available in local cache for version $pycudaVersion. Pre-stage the wheel before installation."
    }
    catch {
        Add-GuiLog "    [WARN] Binary pycuda wheel unavailable in local cache; offline mode does not permit any external fetch. Keeping the source artifact and stopping instead of contacting PyPI." -ForegroundColor Yellow
    }

    $pycudaWheel = Get-ChildItem -LiteralPath $ApprovedDirectory -File |
        Where-Object { $_.Name -like 'pycuda-*.whl' } |
        Select-Object -First 1

    if ($pycudaWheel) {
        Remove-Item -LiteralPath $pycudaSource.FullName -Force -ErrorAction SilentlyContinue
        Add-GuiLog "    [OK] Binary pycuda wheel captured: $($pycudaWheel.Name)" -ForegroundColor Green
        return
    }

    Add-GuiLog "    [SYNC] pycuda source artifact remains; build dependencies are now being added for offline installation." -ForegroundColor DarkYellow
    Download-BuildRequirementsForSourceArtifacts -EnvironmentName $EnvironmentName -ApprovedDirectory $ApprovedDirectory
}

function Normalize-PackageIdentifier {
    param(
        [Parameter(Mandatory = $true)][string]$Value
    )

    $normalized = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return ""
    }

    $normalized = $normalized.Replace('_', '-')
    $normalized = $normalized.Replace('.', '-')
    $normalized = $normalized -replace '[^a-zA-Z0-9-]', '-'
    $normalized = $normalized -replace '-+', '-'
    return $normalized.Trim('-').ToLowerInvariant()
}

function Get-RequirementRecordFromSpec {
    param([Parameter(Mandatory = $true)][string]$RequirementSpec)

    $normalizedSpec = ([string]$RequirementSpec).Trim()
    if ([string]::IsNullOrWhiteSpace($normalizedSpec)) {
        throw "Requirement spec is empty."
    }

    if ($normalizedSpec -notmatch '^(?<name>[A-Za-z0-9._-]+)==(?<version>.+)$') {
        throw "Pinned requirement expected in name==version format: $RequirementSpec"
    }

    return [pscustomobject]@{
        Name = Normalize-PackageIdentifier -Value $matches['name']
        Version = $matches['version'].Trim()
        Raw = ('{0}=={1}' -f (Normalize-PackageIdentifier -Value $matches['name']), $matches['version'].Trim())
    }
}

function Get-LockRequirementRecords {
    param(
        [Parameter(Mandatory = $true)][string]$LockFilePath,
        [int]$RecursionDepth = 0
    )

    if (-not (Test-Path -LiteralPath $LockFilePath)) {
        return @()
    }

    if ($RecursionDepth -gt 10) {
        Write-Host "[WARN] Lock file recursion exceeded 10 levels; stopping to avoid infinite loop." -ForegroundColor Yellow
        return @()
    }

    $records = @()
    $lockFileDir = Split-Path -Parent $LockFilePath
    
    foreach ($rawLine in Get-Content -LiteralPath $LockFilePath) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.StartsWith('#')) { continue }
        
        # Handle -r (recursive requirement) by parsing the referenced file
        if ($line.StartsWith('-r ') -or $line.StartsWith('--requirement ')) {
            $refFile = $line -replace '^(-r\s+|--requirement\s+)', '' | ForEach-Object { $_.Trim() }
            if (-not [System.IO.Path]::IsPathRooted($refFile)) {
                $refFile = Join-Path $lockFileDir $refFile
            }
            
            if (Test-Path -LiteralPath $refFile) {
                $refRecords = @(Get-LockRequirementRecords -LockFilePath $refFile -RecursionDepth ($RecursionDepth + 1))
                $records += $refRecords
            }
            continue
        }
        
        if ($line.StartsWith('--')) { continue }

        $candidate = $line.Split(';')[0].Trim()
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }

        $match = [regex]::Match($candidate, '^(?<name>[A-Za-z0-9_.-]+)\s*(?<operator>==|~=|!=|>=|<=|>|<)?\s*(?<version>[A-Za-z0-9_.+-]+)?')
        if (-not $match.Success) {
            continue
        }

        $packageName = $match.Groups['name'].Value
        $versionValue = $match.Groups['version'].Value.Trim()
        if ([string]::IsNullOrWhiteSpace($versionValue)) {
            $versionValue = ""
        }

        $normalizedName = Normalize-PackageIdentifier -Value $packageName
        if ([string]::IsNullOrWhiteSpace($normalizedName)) {
            continue
        }

        $records += [pscustomobject]@{
            Name = $normalizedName
            Version = $versionValue.Trim()
            Raw = $candidate
        }
    }

    return @($records | Select-Object -Unique Name, Version, Raw)
}

function Get-LockHelperOnlyRequirementRecords {
    param(
        [Parameter(Mandatory = $true)][string]$LockFilePath
    )

    if (-not (Test-Path -LiteralPath $LockFilePath)) {
        return @()
    }

    $records = @()
    foreach ($rawLine in Get-Content -LiteralPath $LockFilePath) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        if ($line -match '^#\s*helper-artifact-only:\s*(?<spec>.+)$') {
            $spec = $matches['spec'].Trim()
            if ([string]::IsNullOrWhiteSpace($spec)) {
                continue
            }

            try {
                $record = Get-RequirementRecordFromSpec -RequirementSpec $spec
                $records += [pscustomobject]@{
                    Name = $record.Name
                    Version = $record.Version
                    Raw = $record.Raw
                }
            }
            catch {
                Write-WarnLog ("Ignoring malformed helper-only lock entry in {0}: {1}" -f $LockFilePath, $spec)
            }
        }
    }

    return @($records | Select-Object -Unique Name, Version, Raw)
}

function Get-LockRequirementPackageNames {
    param(
        [Parameter(Mandatory = $true)][string]$LockFilePath
    )

    $records = @(Get-LockRequirementRecords -LockFilePath $LockFilePath)
    if ($records.Count -eq 0) {
        return @()
    }

    return @($records | ForEach-Object { $_.Name } | Select-Object -Unique)
}

function Get-WheelPackageIdentifier {
    param(
        [Parameter(Mandatory = $true)][string]$FileName
    )

    $record = Get-WheelPackageRecord -FileName $FileName
    if ($null -eq $record) {
        return ""
    }

    return $record.Name
}

function Get-ArtifactPreferenceRank {
    param(
        [Parameter(Mandatory = $true)][string]$FileName
    )

    if ($FileName.EndsWith('.whl', [System.StringComparison]::OrdinalIgnoreCase)) {
        return 0
    }

    if (
        $FileName.EndsWith('.tar.gz', [System.StringComparison]::OrdinalIgnoreCase) -or
        $FileName.EndsWith('.tar.bz2', [System.StringComparison]::OrdinalIgnoreCase) -or
        $FileName.EndsWith('.zip', [System.StringComparison]::OrdinalIgnoreCase)
    ) {
        return 1
    }

    return 2
}

function Get-WheelPackageRecord {
    param(
        [Parameter(Mandatory = $true)][string]$FileName
    )

    if ([string]::IsNullOrWhiteSpace($FileName)) {
        return $null
    }

    $wheelName = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    if ($wheelName.EndsWith('.tar', [System.StringComparison]::OrdinalIgnoreCase)) {
        $wheelName = $wheelName.Substring(0, $wheelName.Length - 4)
    }

    if ($wheelName -match '^(?<name>.+)-(?<version>\d[^-]*)-(?:(?<build>\d+)-)?(?<pyver>[^-]+)-(?<abi>[^-]+)-(?<platform>[^-]+)$') {
        return [pscustomobject]@{
            Name = Normalize-PackageIdentifier -Value $Matches['name']
            Version = $Matches['version'].Trim()
            Raw = $wheelName
        }
    }

    if ($wheelName -match '^(?<name>.+)-(?<version>\d[^-]*)$') {
        return [pscustomobject]@{
            Name = Normalize-PackageIdentifier -Value $Matches['name']
            Version = $Matches['version'].Trim()
            Raw = $wheelName
        }
    }

    $parts = @($wheelName -split '-')
    if ($parts.Count -ge 2) {
        $versionCandidate = $parts[$parts.Count - 1]
        if ($versionCandidate -match '^\d') {
            $nameParts = @($parts[0..($parts.Count - 2)])
            return [pscustomobject]@{
                Name = Normalize-PackageIdentifier -Value ($nameParts -join '-')
                Version = $versionCandidate.Trim()
                Raw = $wheelName
            }
        }
    }

    return $null
}

function Sync-ApprovedWheelhouseFromLock {
    param(
        [Parameter(Mandatory = $true)][string]$LockFilePath,
        [Parameter(Mandatory = $true)][string]$TargetDirectory,
        [string]$RemoteTargetDirectory = $null
    )

    if (-not (Test-Path -LiteralPath $LockFilePath)) {
        throw "Lock file not found: $LockFilePath"
    }

    $parentDir = Split-Path -Parent $TargetDirectory
    if (-not [string]::IsNullOrWhiteSpace($parentDir) -and -not (Test-Path -LiteralPath $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
        Add-GuiLog "    [SYNC] Created wheelhouse parent folder on demand: $parentDir" -ForegroundColor DarkGray
    }

    if (-not (Test-Path -LiteralPath $TargetDirectory)) {
        New-Item -ItemType Directory -Path $TargetDirectory -Force | Out-Null
    }

    $requiredRecords = @(
        Get-LockRequirementRecords -LockFilePath $LockFilePath
        Get-LockHelperOnlyRequirementRecords -LockFilePath $LockFilePath
    )
    $localFiles = @(Get-ChildItem -LiteralPath $TargetDirectory -File -ErrorAction SilentlyContinue)
    $remoteFiles = @()
    if (-not [string]::IsNullOrWhiteSpace($RemoteTargetDirectory) -and (Test-Path -LiteralPath $RemoteTargetDirectory)) {
        $remoteFiles = @(Get-ChildItem -LiteralPath $RemoteTargetDirectory -File -ErrorAction SilentlyContinue)
    }

    if ($requiredRecords.Count -eq 0) {
        Add-GuiLog "    [WARN] No package/version records were parsed from lock file: $LockFilePath" -ForegroundColor Yellow
        return
    }

    $requiredByName = @{}
    foreach ($requiredRecord in $requiredRecords) {
        $requiredByName[$requiredRecord.Name] = $requiredRecord.Version
    }

    foreach ($localFile in $localFiles) {
        $localRecord = Get-WheelPackageRecord -FileName $localFile.Name
        if ($null -eq $localRecord) {
            continue
        }

        $requiredVersion = $requiredByName[$localRecord.Name]
        if (-not $requiredByName.ContainsKey($localRecord.Name) -or (-not [string]::IsNullOrWhiteSpace($requiredVersion) -and $requiredVersion -ne $localRecord.Version)) {
            Remove-Item -LiteralPath $localFile.FullName -Force -ErrorAction SilentlyContinue
            Add-GuiLog "    [SYNC] Removed local wheel whose package/version does not match lock: $($localFile.Name)" -ForegroundColor DarkGray
        }
    }

    foreach ($requiredRecord in $requiredRecords) {
        $localMatch = @(
            Get-ChildItem -LiteralPath $TargetDirectory -File -ErrorAction SilentlyContinue |
                Where-Object {
                    $record = Get-WheelPackageRecord -FileName $_.Name
                    $null -ne $record -and $record.Name -eq $requiredRecord.Name -and $record.Version -eq $requiredRecord.Version
                }
        )

        if ($localMatch.Count -gt 0) {
            $shouldKeepLocalMatch = $true

            if ($remoteFiles.Count -gt 0) {
                $remoteEquivalent = @(
                    $remoteFiles |
                        Where-Object {
                            $record = Get-WheelPackageRecord -FileName $_.Name
                            $null -ne $record -and $record.Name -eq $requiredRecord.Name -and $record.Version -eq $requiredRecord.Version
                        }
                )

                if ($remoteEquivalent.Count -gt 0) {
                    $bestLocalRank = ($localMatch | ForEach-Object { Get-ArtifactPreferenceRank -FileName $_.Name } | Measure-Object -Minimum).Minimum
                    $bestRemoteRank = ($remoteEquivalent | ForEach-Object { Get-ArtifactPreferenceRank -FileName $_.Name } | Measure-Object -Minimum).Minimum
                    if ($bestRemoteRank -lt $bestLocalRank) {
                        $shouldKeepLocalMatch = $false
                    }
                }
            }

            if ($shouldKeepLocalMatch) {
                continue
            }
        }

        if ($remoteFiles.Count -eq 0) {
            continue
        }

        $remoteMatch = @(
            $remoteFiles |
                Where-Object {
                    $record = Get-WheelPackageRecord -FileName $_.Name
                    $null -ne $record -and $record.Name -eq $requiredRecord.Name -and $record.Version -eq $requiredRecord.Version
                }
        )

        if ($remoteMatch.Count -eq 0) {
            continue
        }

        $selectedRemote = $remoteMatch |
            Sort-Object @{ Expression = { Get-ArtifactPreferenceRank -FileName $_.Name } }, @{ Expression = { $_.Name } } |
            Select-Object -First 1
        $targetPath = Join-Path $TargetDirectory $selectedRemote.Name
        Copy-Item -LiteralPath $selectedRemote.FullName -Destination $targetPath -Force
        Add-GuiLog "    [SYNC] Copied exact required wheel from remote cache: $($selectedRemote.Name) -> $TargetDirectory" -ForegroundColor DarkYellow
    }

    $finalFiles = @(Get-ChildItem -LiteralPath $TargetDirectory -File -ErrorAction SilentlyContinue)
    foreach ($finalFile in $finalFiles) {
        $finalRecord = Get-WheelPackageRecord -FileName $finalFile.Name
        if ($null -eq $finalRecord) {
            continue
        }

        $expectedVersion = $requiredByName[$finalRecord.Name]
        if (-not $requiredByName.ContainsKey($finalRecord.Name) -or (-not [string]::IsNullOrWhiteSpace($expectedVersion) -and $expectedVersion -ne $finalRecord.Version)) {
            Remove-Item -LiteralPath $finalFile.FullName -Force -ErrorAction SilentlyContinue
            Add-GuiLog "    [SYNC] Pruned stale wheel after exact-version lock sync: $($finalFile.Name)" -ForegroundColor DarkGray
        }
    }

    $finalRemaining = @(Get-ChildItem -LiteralPath $TargetDirectory -File -ErrorAction SilentlyContinue)
    if ($finalRemaining.Count -eq 0) {
        throw "Offline-only mode: wheelhouse directory is empty after applying exact lock requirements from $LockFilePath. Missing wheel versions are not available locally."
    }

    Add-GuiLog "    [OK] Exact-version lock-based wheelhouse sync finished: $TargetDirectory" -ForegroundColor Green
}

function Refresh-ApprovedWheelhouseFromLock {
    param(
        [Parameter(Mandatory = $true)][string]$EnvironmentName,
        [Parameter(Mandatory = $true)][string]$LockFilePath,
        [Parameter(Mandatory = $true)][string]$TargetDirectory,
        [string]$Description = "lock-based approved wheelhouse refresh",
        [string]$RemoteTargetDirectory = $null
    )

    if ([string]::IsNullOrWhiteSpace($LockFilePath)) {
        throw "LockFilePath is required for wheelhouse refresh."
    }

    if (-not (Test-Path -LiteralPath $LockFilePath)) {
        throw "Lock file not found: $LockFilePath"
    }

    Sync-ApprovedWheelhouseFromLock -LockFilePath $LockFilePath -TargetDirectory $TargetDirectory -RemoteTargetDirectory $RemoteTargetDirectory
    Ensure-PycudaWheelInApprovedDirectory -EnvironmentName $EnvironmentName -ApprovedDirectory $TargetDirectory
    Add-GuiLog "    [OFFLINE] Approved wheelhouse refreshed from lock-based local cache: $TargetDirectory" -ForegroundColor DarkYellow
    Add-GuiLog "    [OK] Approved wheelhouse ready: $TargetDirectory" -ForegroundColor Green
}

function Test-RemotePackageSourceUsable {
    param(
        [string]$RemoteRoot = $null,
        [string]$LocalRoot = $null
    )

    if ([string]::IsNullOrWhiteSpace($RemoteRoot)) {
        return $false
    }

    if ($RemoteRoot -match '^\\') {
        return $false
    }

    if (-not [string]::IsNullOrWhiteSpace($LocalRoot)) {
        try {
            $localFull = [System.IO.Path]::GetFullPath($LocalRoot)
            $remoteFull = [System.IO.Path]::GetFullPath($RemoteRoot)
            if ($remoteFull -eq $localFull) {
                return $false
            }
        }
        catch {
            return $false
        }
    }

    try {
        $null = Get-Item -LiteralPath $RemoteRoot -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Get-LocalCacheSyncPlanSummary {
    param(
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [Parameter(Mandatory = $true)][string]$RemoteRoot,
        [string[]]$RelativePaths = @()
    )

    $plan = Get-RemoteCacheSyncPlan -LocalRoot $LocalRoot -RemoteRoot $RemoteRoot -RelativePaths $RelativePaths
    $missingItems = @($plan | Where-Object { $_.Action -eq "COPY" -or $_.Action -eq "MISSING_REMOTE" })
    $skippedItems = @($plan | Where-Object { $_.Action -eq "SKIP" })
    $displayMissing = @($missingItems | Select-Object -ExpandProperty RelativePath)
    $displaySkipped = @($skippedItems | Select-Object -ExpandProperty RelativePath)

    return [pscustomobject]@{
        Plan = $plan
        MissingItems = $missingItems
        SkippedItems = $skippedItems
        MissingCount = $missingItems.Count
        SkippedCount = $skippedItems.Count
        MissingList = $displayMissing
        SkippedList = $displaySkipped
    }
}

function Get-RemoteCacheSyncPlan {
    param(
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [Parameter(Mandatory = $true)][string]$RemoteRoot,
        [string[]]$RelativePaths = @()
    )

    if (-not (Test-RemotePackageSourceUsable -RemoteRoot $RemoteRoot -LocalRoot $LocalRoot)) {
        $plan = @()
        foreach ($relativePath in $RelativePaths) {
            $targetPath = Join-Path $LocalRoot $relativePath
            $plan += [pscustomobject]@{
                RelativePath = $relativePath
                Source = $RemoteRoot
                Target = $targetPath
                RemoteExists = $false
                LocalExists = (Test-Path -LiteralPath $targetPath)
                Action = if (Test-Path -LiteralPath $targetPath) { "SKIP" } else { "MISSING_REMOTE" }
            }
        }
        return $plan
    }

    $plan = @()
    foreach ($relativePath in $RelativePaths) {
        $sourcePath = Join-Path $RemoteRoot $relativePath
        $targetPath = Join-Path $LocalRoot $relativePath
        $localExists = Test-Path -LiteralPath $targetPath
        $remoteExists = Test-Path -LiteralPath $sourcePath

        $plan += [pscustomobject]@{
            RelativePath = $relativePath
            Source = $sourcePath
            Target = $targetPath
            RemoteExists = $remoteExists
            LocalExists = $localExists
            Action = if ($remoteExists -and -not $localExists) { "COPY" } elseif ($localExists) { "SKIP" } else { "MISSING_REMOTE" }
        }
    }

    return $plan
}

function Assert-PythonRequirementsInstallPreflight {
    param(
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [Parameter(Mandatory = $true)][string]$CommonLockFile,
        [Parameter(Mandatory = $true)][string]$SelectedLockFile,
        [Parameter(Mandatory = $true)][string]$CudaTrackTag
    )

    $configuredWheelhouseRoot = $script:PipelineConfig.RequirementsWheelhouseRoot
    $approvedWheelhouseRoot = if ([string]::IsNullOrWhiteSpace($configuredWheelhouseRoot)) {
        Join-Path $LocalRoot "requirements\wheelhouse\approved"
    }
    else {
        Join-Path $LocalRoot $configuredWheelhouseRoot
    }

    $commonLockPath = Join-Path $LocalRoot $CommonLockFile
    $trackLockPath = Join-Path $LocalRoot $SelectedLockFile
    $commonWheelhousePath = Join-Path $approvedWheelhouseRoot "common"
    $trackWheelhousePath = Join-Path $approvedWheelhouseRoot $CudaTrackTag.ToLower()

    foreach ($path in @($approvedWheelhouseRoot, $commonWheelhousePath, $trackWheelhousePath)) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
            Add-GuiLog "    [SYNC] Created required wheelhouse folder on demand: $path" -ForegroundColor DarkGray
        }
    }

    $required = @(
        $commonLockPath,
        $trackLockPath,
        $commonWheelhousePath,
        $trackWheelhousePath
    )

    foreach ($path in $required) {
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Python install preflight failed: required path missing -> $path"
        }
    }

    return [pscustomobject]@{
        CommonLock = $commonLockPath
        SelectedLock = $trackLockPath
        CommonWheelhouse = $commonWheelhousePath
        TrackWheelhouse = $trackWheelhousePath
    }
}

function Sync-StepRequiredFiles {
    param(
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [string]$RemoteRoot = $null,
        [Parameter(Mandatory = $true)][string[]]$RequiredFiles,
        [Parameter(Mandatory = $true)][string]$StepTitle,
        [string]$Purpose = "Required local files for this step",
        [switch]$RequestConfirmation,
        [switch]$CompareHashForExistingFiles
    )

    function Get-FileSha256Hex {
        param([Parameter(Mandatory = $true)][string]$Path)

        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
    }

    $normalized = @(
        $RequiredFiles |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )

    if ($normalized.Count -eq 0) {
        return $true
    }

    $plan = @()
    foreach ($relativePath in $normalized) {
        $targetPath = Join-Path $LocalRoot $relativePath
        $sourcePath = if ([string]::IsNullOrWhiteSpace($RemoteRoot)) { $relativePath } else { Join-Path $RemoteRoot $relativePath }
        $localExists = Test-Path -LiteralPath $targetPath
        $remoteExists = if ([string]::IsNullOrWhiteSpace($RemoteRoot)) { $false } else { Test-Path -LiteralPath $sourcePath }
        $action = "MISSING_REMOTE"

        if ($remoteExists -and -not $localExists) {
            $action = "COPY"
        }
        elseif ($localExists) {
            if ($CompareHashForExistingFiles -and $remoteExists) {
                $localHash = Get-FileSha256Hex -Path $targetPath
                $remoteHash = Get-FileSha256Hex -Path $sourcePath
                if ($localHash -ne $remoteHash) {
                    $action = "UPDATE"
                }
                else {
                    $action = "SKIP"
                }
            }
            else {
                $action = "SKIP"
            }
        }

        $plan += [pscustomobject]@{
            RelativePath = $relativePath
            Source = $sourcePath
            Target = $targetPath
            RemoteExists = $remoteExists
            LocalExists = $localExists
            Action = $action
        }
    }

    $copyItems = @($plan | Where-Object { $_.Action -eq "COPY" -or $_.Action -eq "UPDATE" })
    $skipItems = @($plan | Where-Object { $_.Action -eq "SKIP" })
    $missingItems = @($plan | Where-Object { $_.Action -eq "MISSING_REMOTE" })
    $copyCount = @($copyItems).Count
    $skipCount = @($skipItems).Count
    $missingCount = @($missingItems).Count

    $detailLines = @(
        "Category: Step sync",
        "Purpose: $Purpose",
        "Source: $RemoteRoot",
        "Destination: $LocalRoot",
        "Files to copy/update: $copyCount",
        "Already cached: $skipCount",
        "Missing from source: $missingCount"
    )

    foreach ($item in $copyItems) {
        $actionLabel = if ($item.Action -eq "UPDATE") { "Update" } else { "Copy" }
        $detailLines += ("${actionLabel}: $($item.RelativePath)")
    }
    foreach ($item in $skipItems) { $detailLines += "Skip: $($item.RelativePath)" }

    if ($RequestConfirmation -and $copyItems.Count -gt 0) {
        $decision = Request-DownloadAndInstallDecision -StepTitle $StepTitle -DetailLines $detailLines
        if ($decision -eq "Abort" -or $decision -eq "Cancel") {
            Add-GuiLog "Step sync canceled before required files were copied: $StepTitle" -ForegroundColor Yellow
            return $false
        }
        if ($decision -eq "Install") {
            Add-GuiLog "Step sync selected by user: $StepTitle. Copying required files and continuing installation." -ForegroundColor Yellow
            foreach ($item in $copyItems) {
                if (-not (Test-Path -LiteralPath $item.Source)) {
                    Add-GuiLog "    [SYNC] source missing, cannot copy: $($item.RelativePath)" -ForegroundColor Yellow
                    continue
                }

                $targetDir = Split-Path -Parent $item.Target
                if (-not (Test-Path -LiteralPath $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
                Copy-Item -LiteralPath $item.Source -Destination $item.Target -Force
                if ($item.Action -eq "UPDATE") {
                    Add-GuiLog "    [SYNC] updated changed file from source: $($item.RelativePath)" -ForegroundColor DarkYellow
                }
                else {
                    Add-GuiLog "    [SYNC] copied required file: $($item.RelativePath)" -ForegroundColor DarkYellow
                }
            }
            foreach ($item in $skipItems) {
                Add-GuiLog "    [SKIP] already exists: $($item.RelativePath)" -ForegroundColor DarkGray
            }
            foreach ($item in $missingItems) {
                Add-GuiLog "    [MISSING] not available from source: $($item.RelativePath)" -ForegroundColor Yellow
            }
            return $true
        }
    }

    foreach ($item in $copyItems) {
        if (-not (Test-Path -LiteralPath $item.Source)) {
            Add-GuiLog "    [SYNC] source missing, cannot copy: $($item.RelativePath)" -ForegroundColor Yellow
            continue
        }

        $targetDir = Split-Path -Parent $item.Target
        if (-not (Test-Path -LiteralPath $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
        Copy-Item -LiteralPath $item.Source -Destination $item.Target -Force
        if ($item.Action -eq "UPDATE") {
            Add-GuiLog "    [SYNC] updated changed file from source: $($item.RelativePath)" -ForegroundColor DarkYellow
        }
        else {
            Add-GuiLog "    [SYNC] copied required file: $($item.RelativePath)" -ForegroundColor DarkYellow
        }
    }

    foreach ($item in $skipItems) {
        Add-GuiLog "    [SKIP] already exists: $($item.RelativePath)" -ForegroundColor DarkGray
    }

    foreach ($item in $missingItems) {
        Add-GuiLog "    [MISSING] not available from source: $($item.RelativePath)" -ForegroundColor Yellow
    }

    if ($missingItems.Count -gt 0 -and $copyItems.Count -eq 0) {
        throw "Required package(s) missing from local cache and remote source: $($missingItems.RelativePath -join ', ')"
    }

    return $true
}

function Set-GuiStepProgress {
    param(
        [int]$Step,
        [string]$Title,
        [int]$TotalSteps = 6,
        [switch]$Running
    )

    Set-UiStepProgress -Step $Step -Title $Title -TotalSteps $TotalSteps -Running:$Running
}

function Set-GuiSubProgress {
    param([int]$Percent)

    Set-UiSubProgress -Percent $Percent
}

function Add-GuiLog {
    param(
        [string]$Message,
        [System.ConsoleColor]$ForegroundColor = [System.ConsoleColor]::Gray,
        [switch]$NoNewline
    )

    Write-UiLog -Message $Message -ForegroundColor $ForegroundColor -NoNewline:$NoNewline
}

function Request-GuiContinue {
    param([string]$Prompt)

    return (Request-UiContinue -Prompt $Prompt)
}

function Resolve-CondaExecutable {
    param(
        [string]$PreferredRoot = $null
    )

    $resolved = $null
    $commandInfo = Get-Command conda -ErrorAction SilentlyContinue
    if ($null -ne $commandInfo) {
        $resolved = $commandInfo.Source
    }

    if ([string]::IsNullOrWhiteSpace($resolved)) {
        $candidateRoots = @()
        if (-not [string]::IsNullOrWhiteSpace($PreferredRoot)) {
            $candidateRoots += $PreferredRoot.TrimEnd('\\')
        }
        $candidateRoots += @(
            "C:\ProgramData\miniconda3",
            "C:\miniconda3",
            "$env:USERPROFILE\miniconda3",
            "C:\ProgramData\Anaconda3",
            "C:\Anaconda3",
            "$env:USERPROFILE\Anaconda3"
        )

        foreach ($root in ($candidateRoots | Select-Object -Unique)) {
            foreach ($candidate in @(
                (Join-Path $root "Scripts\conda.exe"),
                (Join-Path $root "Scripts\conda.bat"),
                (Join-Path $root "Scripts\conda.cmd"),
                (Join-Path $root "condabin\conda.bat"),
                (Join-Path $root "condabin\conda.cmd")
            )) {
                if (Test-Path -LiteralPath $candidate) {
                    $resolved = $candidate
                    break
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($resolved)) {
                break
            }
        }
    }

    return $resolved
}

function Ensure-PythonEnvCondaReady {
    param(
        [string]$PreferredRoot = $null,
        [string]$ActiveCondaPath = $null
    )

    $resolvedCondaExe = Resolve-CondaExecutable -PreferredRoot $PreferredRoot
    $resolvedCondaRoot = $null

    if (-not [string]::IsNullOrWhiteSpace($resolvedCondaExe)) {
        $resolvedCondaRoot = Split-Path -Parent (Split-Path -Parent $resolvedCondaExe)
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ActiveCondaPath) -and (Test-Path -LiteralPath (Join-Path $ActiveCondaPath "Scripts\conda.exe"))) {
        $resolvedCondaExe = Join-Path $ActiveCondaPath "Scripts\conda.exe"
        $resolvedCondaRoot = $ActiveCondaPath
    }

    if ([string]::IsNullOrWhiteSpace($resolvedCondaExe)) {
        Add-GuiLog "    [BLOCK] Python environment creation is not possible because no Conda executable is available." -ForegroundColor Red
        Add-GuiLog "    [INFO] Miniconda was skipped or no existing Conda/Miniconda install is on PATH. Use Step 2 to install Miniconda or activate an existing Conda root first." -ForegroundColor Yellow
        return $null
    }

    return [pscustomobject]@{
        Executable = $resolvedCondaExe
        Root = if ([string]::IsNullOrWhiteSpace($resolvedCondaRoot)) { $ActiveCondaPath } else { $resolvedCondaRoot }
    }
}

function Wait-GuiLogWindowClose {
    Wait-UiLogWindowClose
}

function Set-GuiTopMost {
    param([bool]$Enabled)

    if ($null -ne $script:PipelineUi -and $script:PipelineUi.PSObject.Methods.Name -contains "SetTopMost") {
        $script:PipelineUi.SetTopMost($Enabled)
    }
}

function Invoke-WithGuiNotOnTop {
    <#
    .SYNOPSIS
    외부 설치 프로그램 실행 시 GUI 창을 백그라운드에 두고 TopMost = false로 설정.
    GUI는 계속 visible 상태를 유지하므로 로그와 진행 상황을 볼 수 있다.
    실행 중 주기적으로 DoEvents()를 호출하여 GUI 응답성을 유지한다.
    #>
    param([Parameter(Mandatory = $true)][scriptblock]$Action)

    try {
        Set-GuiTopMost -Enabled $false
        & $Action
    }
    finally {
        Set-GuiTopMost -Enabled $true
    }
}

# ============================================================================
# 함수: 프로세스 실행 (GUI 응답성 유지)
# ============================================================================

function Invoke-ProcessWithGuiProgress {
    <#
    .SYNOPSIS
    외부 프로세스 실행 중 GUI 응답성 유지 및 진행률 애니메이션
    
    .DESCRIPTION
    - 외부 프로세스(예: Miniconda 설치, 7z 압축 해제) 실행
    - 실행 중 GUI DoEvents() 호출로 UI 블로킹 방지
    - Sub Progress 바를 왕복 애니메이션으로 갱신 (멈춤 감각 제거)
    - HideWindow 스위치로 콘솔 창 숨김 가능 (7z 등)
    
    .PARAMETER FilePath
    실행할 프로그램 경로 (예: Miniconda 설치 프로그램)
    
    .PARAMETER ArgumentList
    프로그램 인자 배열
    
    .PARAMETER HideWindow
    프로세스 창을 숨김 (예: 7z 콘솔 창 미표시)
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int]$StartPercent = 10,
        [int]$MaxPercentWhileRunning = 95,
        [int]$TickMilliseconds = 250,
        [switch]$HideWindow
    )

    try {
        Set-GuiTopMost -Enabled $false
        $start = [Math]::Max(0, [Math]::Min($StartPercent, 100))
        $maxRun = [Math]::Max($start, [Math]::Min($MaxPercentWhileRunning, 99))
        $tick = [Math]::Max(100, $TickMilliseconds)

        Set-GuiSubProgress -Percent $start
        if ($HideWindow) {
            $proc = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -WindowStyle Hidden -PassThru
        }
        else {
            $proc = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru
        }

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
        Set-GuiTopMost -Enabled $true
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

# ============================================================================
# 함수: 아카이브 압축 해제 (ZIP, 7Z 자동 판별)
# ============================================================================

function Expand-PackageArchiveWithGuiProgress {
    <#
    .SYNOPSIS
    ZIP 또는 7Z 아카이브를 자동 판별하여 압축 해제
    
    .DESCRIPTION
    - 파일 확장자로 아카이브 형식 자동 판별
    - ZIP: .NET Framework 내장 기능 사용
    - 7Z: 7z.exe CLI 호출 (설치 자동 확인)
    - GUI 진행률 바 실시간 갱신
    
    .PARAMETER ArchivePath
    압축 파일 경로 (.zip 또는 .7z)
    
    .PARAMETER DestinationPath
    압축 해제 대상 폴더
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [int]$StartPercent = 0,
        [int]$EndPercent = 100
    )

    if (-not (Test-Path -LiteralPath $ArchivePath)) {
        throw "Archive not found: $ArchivePath"
    }

    if (-not (Test-Path -LiteralPath $DestinationPath)) {
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    }

    $ext = [System.IO.Path]::GetExtension($ArchivePath).ToLowerInvariant()
    switch ($ext) {
        ".zip" {
            Expand-ArchiveWithGuiProgress -ZipPath $ArchivePath -DestinationPath $DestinationPath -StartPercent $StartPercent -EndPercent $EndPercent
            break
        }
        ".7z" {
            $sevenZipExe = Find-7ZipExecutable
            if ([string]::IsNullOrWhiteSpace($sevenZipExe)) {
                throw "7z.exe not found for extracting archive: $ArchivePath"
            }

            # ============================================================================
            # 7z.exe CLI 호출 매개변수 설명
            # ============================================================================
            # x: eXtract with full paths (전체 경로 포함 압축 해제)
            # -y: Yes to all prompts (모든 확인 프롬프트에 자동 예 응답)
            # -aoa: Overwrite All (기존 파일 무조건 덮어쓰기)
            # -bso0: Suppress output from stdout (표준 출력 숨김)
            # -bsp0: Suppress progress info (진행률 정보 숨김, 우리가 GUI로 표시하므로)
            # -o$DestinationPath: Output directory (대상 디렉터리)
            # $ArchivePath: 아카이브 파일 경로
            #
            Invoke-ProcessWithGuiProgress `
                -FilePath $sevenZipExe `
                -ArgumentList @("x", "-y", "-aoa", "-bso0", "-bsp0", "-o$DestinationPath", $ArchivePath) `
                -StartPercent $StartPercent `
                -MaxPercentWhileRunning ([Math]::Min($EndPercent, 95)) `
                -TickMilliseconds 250 `
                -HideWindow

            Set-GuiSubProgress -Percent $EndPercent
            break
        }
        ".7zip" {
            $sevenZipExe = Find-7ZipExecutable
            if ([string]::IsNullOrWhiteSpace($sevenZipExe)) {
                throw "7z.exe not found for extracting archive: $ArchivePath"
            }

            Invoke-ProcessWithGuiProgress `
                -FilePath $sevenZipExe `
                -ArgumentList @("x", "-y", "-aoa", "-bso0", "-bsp0", "-o$DestinationPath", $ArchivePath) `
                -StartPercent $StartPercent `
                -MaxPercentWhileRunning ([Math]::Min($EndPercent, 95)) `
                -TickMilliseconds 250 `
                -HideWindow

            Set-GuiSubProgress -Percent $EndPercent
            break
        }
        default {
            throw "Unsupported archive extension '$ext': $ArchivePath"
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

    Show-UiError -Stage $Stage -ErrorRecord $ErrorRecord
}

function Show-PrecheckRuntimeSummary {
    param(
        [bool]$IsCondaInstalled,
        [string]$FoundCondaPath,
        [bool]$IsTrtInstalled,
        [string]$FoundTrtPath,
        [string]$ExpectedTrtPath
    )

    Write-UiPrecheckSummary -IsCondaInstalled $IsCondaInstalled -FoundCondaPath $FoundCondaPath -IsTrtInstalled $IsTrtInstalled -FoundTrtPath $FoundTrtPath -ExpectedTrtPath $ExpectedTrtPath
}

function Request-StepInstallDecision {
    param(
        [Parameter(Mandatory = $true)][string]$StepTitle,
        [Parameter(Mandatory = $true)][string[]]$DetailLines,
        [switch]$Warning
    )

    if ($null -ne $script:PipelineUi -and $script:PipelineUi.PSObject.Methods.Name -contains "ShowInstallDecision") {
        return $script:PipelineUi.ShowInstallDecision($StepTitle, $DetailLines, [bool]$Warning)
    }

    if ($null -ne $script:PipelineUi -and $script:PipelineUi.PSObject.Methods.Name -contains "ShowStepInstallDecision") {
        return $script:PipelineUi.ShowStepInstallDecision($StepTitle, $DetailLines, [bool]$Warning)
    }

    return "Abort"
}

function Request-DownloadAndInstallDecision {
    param(
        [Parameter(Mandatory = $true)][string]$StepTitle,
        [Parameter(Mandatory = $true)][string[]]$DetailLines
    )

    if ($null -ne $script:PipelineUi -and $script:PipelineUi.PSObject.Methods.Name -contains "ShowDownloadAndInstallDecision") {
        return $script:PipelineUi.ShowDownloadAndInstallDecision($StepTitle, $DetailLines)
    }

    return "Cancel"
}

function Request-TensorRTOptionSelection {
    param(
        [Parameter(Mandatory = $true)][string]$DetectedCudaVersion,
        [Parameter(Mandatory = $true)][object[]]$Options,
        [int]$DefaultOptionNumber = 1
    )

    # TensorRT 프로필 선택 UI도 UI 모듈이 담당한다.
    if ($null -ne $script:PipelineUi -and $script:PipelineUi.PSObject.Methods.Name -contains "SelectTensorRTProfile") {
        return $script:PipelineUi.SelectTensorRTProfile($DetectedCudaVersion, $Options, $DefaultOptionNumber)
    }

    return $null
}

function Resolve-TensorRTWheelPath {
    param(
        [Parameter(Mandatory = $true)][string]$TrtRoot,
        [Parameter(Mandatory = $true)][string]$EnvPythonExe
    )

    $pythonDir = Join-Path $TrtRoot "python"
    if (-not (Test-Path -LiteralPath $pythonDir)) {
        throw "TensorRT python wheel folder not found: $pythonDir"
    }

    if (-not (Test-Path -LiteralPath $EnvPythonExe)) {
        throw "Python executable not found: $EnvPythonExe"
    }

    # 대상 가상환경의 Python ABI 태그를 구한다.
    # 예: Python 3.10 -> cp310, Python 3.11 -> cp311
    $pyTag = (& $EnvPythonExe -c "import sys; print(f'cp{sys.version_info[0]}{sys.version_info[1]}')" 2>$null | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($pyTag)) {
        throw "Failed to determine Python wheel tag from environment."
    }

    # TensorRT 배포 폴더의 python 하위에서 wheel을 수집한다.
    $allWheels = @(Get-ChildItem -Path $pythonDir -Filter "*.whl" -File -Recurse -ErrorAction SilentlyContinue)
    if ($allWheels.Count -eq 0) {
        throw "No wheel file found under: $pythonDir"
    }

    # 파일명에 tensorrt가 포함된 wheel을 우선 후보로 사용한다.
    # 배포 패키지 구성이 다를 수 있으므로 후보가 없으면 전체 wheel로 fallback 한다.
    $trtWheels = @($allWheels | Where-Object { $_.Name -match "tensorrt" })
    if ($trtWheels.Count -eq 0) {
        $trtWheels = $allWheels
    }

    # 1순위: 현재 env ABI 태그(cp310 등)가 이름에 포함된 wheel
    $abiMatchedWheels = @(
        $trtWheels |
            Where-Object { $_.Name -match [regex]::Escape($pyTag) } |
            Sort-Object -Property Name -Descending
    )

    # 패키지 우선순위: 기본 tensorrt > tensorrt_dispatch > tensorrt_lean
    # 이름 패턴 기준으로 그룹을 나눠 순차적으로 첫 항목을 선택한다.
    $preferredWheel = $null
    $priorityPatterns = @(
        '^tensorrt-[^-].*\.whl$',
        '^tensorrt_dispatch-.*\.whl$',
        '^tensorrt_lean-.*\.whl$'
    )

    foreach ($pattern in $priorityPatterns) {
        $candidate = @(
            $abiMatchedWheels |
                Where-Object { $_.Name -match $pattern } |
                Select-Object -First 1
        )
        if ($candidate.Count -gt 0 -and $null -ne $candidate[0]) {
            $preferredWheel = $candidate[0]
            break
        }
    }

    if ($null -eq $preferredWheel -and $abiMatchedWheels.Count -gt 0) {
        # 우선순위 패턴에 안 맞는 이름이어도 ABI가 맞으면 마지막 fallback으로 사용한다.
        $preferredWheel = $abiMatchedWheels[0]
    }

    if ($null -eq $preferredWheel) {
        # 2순위: 범용 태그(py3-none) wheel
        $py3MatchedWheels = @(
            $trtWheels |
                Where-Object { $_.Name -match "py3-none" } |
                Sort-Object -Property Name -Descending
        )

        foreach ($pattern in $priorityPatterns) {
            $candidate = @(
                $py3MatchedWheels |
                    Where-Object { $_.Name -match $pattern } |
                    Select-Object -First 1
            )
            if ($candidate.Count -gt 0 -and $null -ne $candidate[0]) {
                $preferredWheel = $candidate[0]
                break
            }
        }

        if ($null -eq $preferredWheel -and $py3MatchedWheels.Count -gt 0) {
            $preferredWheel = $py3MatchedWheels[0]
        }
    }

    if ($null -eq $preferredWheel) {
        throw "No compatible TensorRT wheel found for Python tag $pyTag in $pythonDir"
    }

    return $preferredWheel.FullName
}

function Install-TensorRTWheelToEnvironment {
    param(
        [Parameter(Mandatory = $true)][string]$CondaRoot,
        [Parameter(Mandatory = $true)][string]$EnvName,
        [Parameter(Mandatory = $true)][string]$TrtRoot
    )

    # conda env 내부 python으로 설치해야 env 단위 의존성이 정확히 맞는다.
    $envPythonExe = Join-Path (Join-Path $CondaRoot "envs\\$EnvName") "python.exe"
    $wheelPath = Resolve-TensorRTWheelPath -TrtRoot $TrtRoot -EnvPythonExe $envPythonExe

    Add-GuiLog "    [TRT-WHL] Selected wheel: $wheelPath" -ForegroundColor DarkGray
    Add-GuiLog "    [TRT-WHL] Installing TensorRT wheel into env '$EnvName'..." -ForegroundColor Yellow

    $pipOutput = & $envPythonExe -m pip install --no-deps --force-reinstall $wheelPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        $detail = ($pipOutput | Select-Object -First 30) -join [Environment]::NewLine
        throw "TensorRT wheel install failed.`n$detail"
    }

    Add-GuiLog "    [OK] TensorRT wheel installed in env '$EnvName'." -ForegroundColor Green
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

            # 검증 루트 기반 매칭에 걸리지 않아도 TensorRT 유사 경로는 제거한다.
            if (-not $shouldRemove -and (Test-IsTensorRTPathEntry -PathEntry $entry -KnownRoots $KnownRoots)) {
                $shouldRemove = $true
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

            # 변수 값이 TensorRT 경로로 보이거나, 변수명 자체가 TensorRT 계열이면 제거
            $valueKey = Get-PathCompareKey -PathValue $currentValue
            $shouldRemove = $false
            foreach ($verifiedRoot in $verifiedTrtRoots) {
                $rootKey = Get-PathCompareKey -PathValue $verifiedRoot
                if ($valueKey -eq $rootKey) {
                    $shouldRemove = $true
                    break
                }
            }

            if (-not $shouldRemove) {
                if ((Test-IsTensorRTLikePath -PathValue $currentValue -KnownRoots $KnownRoots) -or
                    ($varName -match '^(TRT_PATH|TENSORRT.*)$')) {
                    $shouldRemove = $true
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

    $uniqueRoots = @()
    $seen = @{}
    foreach ($root in $CandidateRoots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $key = Get-PathCompareKey -PathValue $root
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $uniqueRoots += $root
    }

    $taskTotal = $uniqueRoots.Count
    $processed = 0
    Set-GuiSubProgress -Percent 0

    foreach ($root in $uniqueRoots) {
        # CUDA Toolkit 기본 폴더는 삭제 대상에서 제외한다.
        if (Test-IsCudaToolkitPath -PathValue $root) {
            $report.SkippedRoots += $root
            continue
        }

        if (Test-TensorRTInstallRoot -RootPath $root) {
            $processed++
            $currentPercent = if ($taskTotal -gt 0) { [int](($processed / $taskTotal) * 100) } else { 0 }
            Set-GuiSubProgress -Percent ([Math]::Min(95, $currentPercent))
            Add-GuiLog "    [DELETE] Deleting TensorRT root: $root" -ForegroundColor DarkYellow
            [System.Windows.Forms.Application]::DoEvents()
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
            [System.Windows.Forms.Application]::DoEvents()
            $report.RemovedRoots += $root
        } else {
            $report.SkippedRoots += $root
        }
    }

    Set-GuiSubProgress -Percent 100
    return [pscustomobject]$report
}

# ============================================================================
# 함수: Conda 모든 설치 제거 (경로별 안전 검증)
# ============================================================================
# 역할: 지정된 Conda 루트 디렉터리 재귀 삭제
# 주의: IncludeTargetRoot=false일 때 기본 설치 경로는 보호
# 검증: 실제 Scripts\conda.exe 파일 존재 후 삭제 진행
# 보고: 삭제 성공/생략/실패 목록 반환
#
function Remove-CondaInstallations {
    param(
        [string[]]$CandidateRoots,
        [string]$TargetRoot,
        [switch]$IncludeTargetRoot
    )

    $validRoots = @()
    foreach ($root in $CandidateRoots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $normalizedRoot = $root.TrimEnd('\\')
        if ([string]::IsNullOrWhiteSpace($normalizedRoot)) { continue }
        $key = $normalizedRoot.ToLowerInvariant()
        if ((@($validRoots).Count -gt 0) -and ((@($validRoots | Where-Object { $_.Key -ieq $key })).Count -gt 0)) { continue }
        $validRoots += [pscustomobject]@{ Key = $key; Value = $normalizedRoot }
    }

    $taskTotal = @($validRoots).Count
    $jobScript = {
        param(
            [object[]]$RootEntries,
            [string]$TargetRoot,
            [bool]$IncludeTargetRoot,
            [int]$TaskTotal
        )

        function Test-ProcessPathUnderRoot {
            param(
                [AllowEmptyString()][string]$ProcessPath,
                [Parameter(Mandatory = $true)][string]$RootPath
            )

            if ([string]::IsNullOrWhiteSpace($ProcessPath) -or [string]::IsNullOrWhiteSpace($RootPath)) {
                return $false
            }

            try {
                $normalizedProcessPath = [System.IO.Path]::GetFullPath($ProcessPath).TrimEnd('\\')
                $normalizedRootPath = [System.IO.Path]::GetFullPath($RootPath).TrimEnd('\\')
            }
            catch {
                return $false
            }

            return $normalizedProcessPath.StartsWith(($normalizedRootPath + '\\'), [System.StringComparison]::OrdinalIgnoreCase)
        }

        function Get-RootOwnedProcesses {
            param([Parameter(Mandatory = $true)][string]$RootPath)

            $matched = @()
            foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
                $processPath = $null

                try {
                    $processPath = $process.Path
                }
                catch {
                    $processPath = $null
                }

                if ([string]::IsNullOrWhiteSpace($processPath)) {
                    try {
                        $processPath = $process.MainModule.FileName
                    }
                    catch {
                        $processPath = $null
                    }
                }

                if (Test-ProcessPathUnderRoot -ProcessPath $processPath -RootPath $RootPath) {
                    $matched += [pscustomobject]@{
                        Id = $process.Id
                        Name = $process.ProcessName
                        Path = $processPath
                    }
                }
            }

            return @($matched | Sort-Object Id -Unique)
        }

        function Stop-RootOwnedProcesses {
            param([Parameter(Mandatory = $true)][string]$RootPath)

            $stopped = @()
            $failed = @()
            foreach ($entry in @(Get-RootOwnedProcesses -RootPath $RootPath)) {
                try {
                    Stop-Process -Id $entry.Id -Force -ErrorAction Stop
                    $stopped += $entry
                }
                catch {
                    $failed += [pscustomobject]@{
                        Id = $entry.Id
                        Name = $entry.Name
                        Path = $entry.Path
                        Error = $_.Exception.Message
                    }
                }
            }

            return [pscustomobject]@{
                Stopped = @($stopped)
                Failed = @($failed)
            }
        }

        function Clear-DirectoryAttributesRecursively {
            param([Parameter(Mandatory = $true)][string]$RootPath)

            foreach ($item in @(Get-ChildItem -LiteralPath $RootPath -Force -Recurse -ErrorAction SilentlyContinue)) {
                try {
                    if ($item.Attributes -band [System.IO.FileAttributes]::ReadOnly) {
                        $item.Attributes = ($item.Attributes -bxor [System.IO.FileAttributes]::ReadOnly)
                    }
                }
                catch {
                }
            }
        }

        function Invoke-CondaRootUninstaller {
            param([Parameter(Mandatory = $true)][string]$RootPath)

            $uninstallerCandidates = @(
                (Join-Path $RootPath 'Uninstall-Miniconda3.exe'),
                (Join-Path $RootPath 'Uninstall-Anaconda3.exe')
            )

            foreach ($uninstallerPath in $uninstallerCandidates) {
                if (-not (Test-Path -LiteralPath $uninstallerPath)) {
                    continue
                }

                $process = $null
                try {
                    $process = Start-Process -FilePath $uninstallerPath -ArgumentList @('/S') -PassThru -Wait -WindowStyle Hidden
                    return [pscustomobject]@{
                        Attempted = $true
                        Path = $uninstallerPath
                        ExitCode = $process.ExitCode
                    }
                }
                catch {
                    return [pscustomobject]@{
                        Attempted = $true
                        Path = $uninstallerPath
                        ExitCode = $null
                        Error = $_.Exception.Message
                    }
                }
            }

            return [pscustomobject]@{
                Attempted = $false
                Path = $null
                ExitCode = $null
            }
        }

        $report = [ordered]@{
            RemovedRoots = @()
            SkippedRoots = @()
            FailedRoots = @()
        }

        $seen = @{}
        $processed = 0
        foreach ($entry in $RootEntries) {
            $root = if ($null -ne $entry -and $entry.PSObject.Properties.Name -contains "Value") { $entry.Value } else { [string]$entry }
            if ([string]::IsNullOrWhiteSpace($root)) { continue }

            $normalizedRoot = $root.TrimEnd('\\')
            $key = $normalizedRoot.ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true

            if ((-not $IncludeTargetRoot) -and ($normalizedRoot -ieq $TargetRoot.TrimEnd('\\'))) {
                $report.SkippedRoots = @($report.SkippedRoots) + @($root)
                continue
            }

            if (-not (Test-Path -LiteralPath $normalizedRoot)) {
                $report.SkippedRoots = @($report.SkippedRoots) + @($root)
                continue
            }

            $condaExe = Join-Path $normalizedRoot "Scripts\\conda.exe"
            if (-not (Test-Path -LiteralPath $condaExe)) {
                $report.SkippedRoots = @($report.SkippedRoots) + @($root)
                continue
            }

            $processed++
            $currentPercent = if ($TaskTotal -gt 0) { [int](($processed / $TaskTotal) * 100) } else { 0 }

            Write-Output ([pscustomobject]@{
                Type = "Progress"
                Root = $normalizedRoot
                Percent = [Math]::Min(99, [Math]::Max(0, $currentPercent))
                State = "Deleting"
                Processed = $processed
                Total = $TaskTotal
            })

            $uninstallResult = Invoke-CondaRootUninstaller -RootPath $normalizedRoot
            if ($uninstallResult.Attempted) {
                Write-Output ([pscustomobject]@{
                    Type = "Progress"
                    Root = $normalizedRoot
                    Percent = [Math]::Min(99, [Math]::Max(0, $currentPercent))
                    State = "RanUninstaller"
                    Processed = $processed
                    Total = $TaskTotal
                    Process = $uninstallResult.Path
                    ExitCode = $uninstallResult.ExitCode
                    Error = $uninstallResult.Error
                })
            }

            $stopResult = Stop-RootOwnedProcesses -RootPath $normalizedRoot
            foreach ($stoppedProcess in @($stopResult.Stopped)) {
                Write-Output ([pscustomobject]@{
                    Type = "Progress"
                    Root = $normalizedRoot
                    Percent = [Math]::Min(99, [Math]::Max(0, $currentPercent))
                    State = "StoppedProcess"
                    Processed = $processed
                    Total = $TaskTotal
                    Process = ("{0} [{1}]" -f $stoppedProcess.Name, $stoppedProcess.Id)
                })
            }
            foreach ($failedProcess in @($stopResult.Failed)) {
                Write-Output ([pscustomobject]@{
                    Type = "Progress"
                    Root = $normalizedRoot
                    Percent = [Math]::Min(99, [Math]::Max(0, $currentPercent))
                    State = "StopProcessFailed"
                    Processed = $processed
                    Total = $TaskTotal
                    Process = ("{0} [{1}]" -f $failedProcess.Name, $failedProcess.Id)
                    Error = $failedProcess.Error
                })
            }

            try {
                Clear-DirectoryAttributesRecursively -RootPath $normalizedRoot
                
                # 파일 레벨 잠금 처리: 읽기 전용 속성 해제
                Get-ChildItem -LiteralPath $normalizedRoot -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
                    try {
                        [System.IO.File]::SetAttributes($_.FullName, [System.IO.FileAttributes]::Normal)
                    } catch {}
                }
                
                # 첫 번째 삭제 시도
                Remove-Item -LiteralPath $normalizedRoot -Recurse -Force -ErrorAction Stop
                $report.RemovedRoots = @($report.RemovedRoots) + @($root)
                Write-Output ([pscustomobject]@{
                    Type = "Progress"
                    Root = $normalizedRoot
                    Percent = [Math]::Min(100, [Math]::Max(0, $currentPercent))
                    State = "Deleted"
                    Processed = $processed
                    Total = $TaskTotal
                })
            }
            catch {
                $firstError = $_.Exception.Message

                $retryStopResult = Stop-RootOwnedProcesses -RootPath $normalizedRoot
                foreach ($stoppedProcess in @($retryStopResult.Stopped)) {
                    Write-Output ([pscustomobject]@{
                        Type = "Progress"
                        Root = $normalizedRoot
                        Percent = [Math]::Min(99, [Math]::Max(0, $currentPercent))
                        State = "StoppedProcess"
                        Processed = $processed
                        Total = $TaskTotal
                        Process = ("{0} [{1}]" -f $stoppedProcess.Name, $stoppedProcess.Id)
                    })
                }
                foreach ($failedProcess in @($retryStopResult.Failed)) {
                    Write-Output ([pscustomobject]@{
                        Type = "Progress"
                        Root = $normalizedRoot
                        Percent = [Math]::Min(99, [Math]::Max(0, $currentPercent))
                        State = "StopProcessFailed"
                        Processed = $processed
                        Total = $TaskTotal
                        Process = ("{0} [{1}]" -f $failedProcess.Name, $failedProcess.Id)
                        Error = $failedProcess.Error
                    })
                }

                try {
                    Clear-DirectoryAttributesRecursively -RootPath $normalizedRoot
                    
                    # 재시도: 더 강한 속성 해제
                    Get-ChildItem -LiteralPath $normalizedRoot -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
                        try {
                            [System.IO.File]::SetAttributes($_.FullName, [System.IO.FileAttributes]::Normal)
                        } catch {}
                    }
                    
                    Start-Sleep -Milliseconds 500
                    Remove-Item -LiteralPath $normalizedRoot -Recurse -Force -ErrorAction Stop
                    $report.RemovedRoots = @($report.RemovedRoots) + @($root)
                    Write-Output ([pscustomobject]@{
                        Type = "Progress"
                        Root = $normalizedRoot
                        Percent = [Math]::Min(100, [Math]::Max(0, $currentPercent))
                        State = "Deleted"
                        Processed = $processed
                        Total = $TaskTotal
                    })
                }
                catch {
                    $combinedError = $_.Exception.Message
                    if (-not [string]::IsNullOrWhiteSpace($firstError) -and $combinedError -ne $firstError) {
                        $combinedError = ("{0} | retry: {1}" -f $firstError, $combinedError)
                    }

                    $report.FailedRoots = @($report.FailedRoots) + @(("{0} :: {1}" -f $root, $combinedError))
                    Write-Output ([pscustomobject]@{
                        Type = "Progress"
                        Root = $normalizedRoot
                        Percent = [Math]::Min(100, [Math]::Max(0, $currentPercent))
                        State = "Failed"
                        Processed = $processed
                        Total = $TaskTotal
                        Error = $combinedError
                    })
                }
            }
        }

        Write-Output ([pscustomobject]@{
            Type = "Report"
            Report = [pscustomobject]@{
                RemovedRoots = @($report.RemovedRoots)
                SkippedRoots = @($report.SkippedRoots)
                FailedRoots = @($report.FailedRoots)
            }
        })
    }

    $job = Start-Job -ScriptBlock $jobScript -ArgumentList @($validRoots, $TargetRoot, [bool]$IncludeTargetRoot, $taskTotal) -Name "CondaCleanup"
    $lastPercent = 0

    while ($job.State -eq "Running" -or $job.HasMoreData) {
        foreach ($item in @(Receive-Job -Job $job)) {
            if ($null -eq $item -or -not ($item -is [pscustomobject])) { continue }
            if (-not ($item.PSObject.Properties.Name -contains "Type")) { continue }

            if ($item.Type -eq "Progress") {
                $percent = [Math]::Min(100, [Math]::Max(0, [int]$item.Percent))
                if ($percent -ne $lastPercent) {
                    $lastPercent = $percent
                    Set-GuiSubProgress -Percent $percent
                    if ($null -eq $script:PipelineUi) {
                        Write-Progress -Activity "Removing existing Miniconda" -Status "Deleting $($item.Root)" -PercentComplete $percent -CurrentOperation "($($item.Processed)/$($item.Total))"
                    }
                }

                if ($item.State -eq "Deleting") {
                    Add-GuiLog "    [DELETE] Deleting Miniconda root: $($item.Root)" -ForegroundColor DarkYellow
                }
                elseif ($item.State -eq "RanUninstaller") {
                    if ([string]::IsNullOrWhiteSpace([string]$item.Error)) {
                        Add-GuiLog "    [CLEAN] Ran Conda uninstaller: $($item.Process) (exit=$($item.ExitCode))" -ForegroundColor DarkYellow
                    }
                    else {
                        Add-GuiLog "    [WARN] Conda uninstaller failed: $($item.Process) :: $($item.Error)" -ForegroundColor Yellow
                    }
                }
                elseif ($item.State -eq "StoppedProcess") {
                    Add-GuiLog "    [CLEAN] Stopped process using Conda root: $($item.Process)" -ForegroundColor DarkYellow
                }
                elseif ($item.State -eq "StopProcessFailed") {
                    Add-GuiLog "    [WARN] Failed to stop process using Conda root: $($item.Process) :: $($item.Error)" -ForegroundColor Yellow
                }
                elseif ($item.State -eq "Deleted") {
                    Add-GuiLog "    [CLEAN] Removed Conda root: $($item.Root)" -ForegroundColor DarkYellow
                }
                elseif ($item.State -eq "Failed") {
                    Add-GuiLog "    [WARN] Failed to remove Conda root: $($item.Root) :: $($item.Error)" -ForegroundColor Yellow
                }
            }
        }

        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 150
    }

    $finalOutput = @(Receive-Job -Job $job)
    $report = [ordered]@{
        RemovedRoots = @()
        SkippedRoots = @()
        FailedRoots = @()
    }

    foreach ($item in $finalOutput) {
        if ($null -eq $item -or -not ($item -is [pscustomobject])) { continue }
        if (($item.PSObject.Properties.Name -contains "Type") -and ($item.Type -eq "Report")) {
            $report = $item.Report
            break
        }
    }

    Set-GuiSubProgress -Percent 100
    if ($null -eq $script:PipelineUi) {
        Write-Progress -Activity "Removing existing Miniconda" -Status "Cleanup finished" -Completed
    }

    Remove-Job -Job $job -Force

    return [pscustomobject]@{
        RemovedRoots = @($report.RemovedRoots)
        SkippedRoots = @($report.SkippedRoots)
        FailedRoots = @($report.FailedRoots)
    }
}

function Add-EnvironmentPathEntries {
    param(
        [ValidateSet("User", "Machine")][string]$Scope,
        [string[]]$Entries
    )

    $currentEntries = @(Get-EnvironmentPathEntries -Scope $Scope)
    $currentKeys = @{}
    foreach ($entry in $currentEntries) {
        $entryKey = Get-PathCompareKey -PathValue $entry
        if (-not [string]::IsNullOrWhiteSpace($entryKey)) {
            $currentKeys[$entryKey] = $true
        }
    }

    $added = @()
    foreach ($entry in $Entries) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        if (-not (Test-Path -LiteralPath $entry)) { continue }

        $key = Get-PathCompareKey -PathValue $entry
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        if ($currentKeys.ContainsKey($key)) { continue }

        $currentEntries += $entry
        $currentKeys[$key] = $true
        $added += $entry
    }

    Set-EnvironmentPathEntries -Scope $Scope -Entries $currentEntries
    return @($added)
}

function Remove-CondaEnvironmentSettings {
    param([string[]]$KnownRoots)

    $report = [ordered]@{
        RemovedPathEntries = @()
        RemovedVariables = @()
    }

    $normalizedRoots = @()
    foreach ($root in $KnownRoots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $normalizedRoots += $root.TrimEnd('\\')
    }
    $normalizedRoots = @($normalizedRoots | Select-Object -Unique)

    foreach ($scope in @("User", "Machine")) {
        $entries = Get-EnvironmentPathEntries -Scope $scope
        $kept = @()

        foreach ($entry in $entries) {
            $entryKey = Get-PathCompareKey -PathValue $entry
            $shouldRemove = $false

            foreach ($root in $normalizedRoots) {
                $rootKey = Get-PathCompareKey -PathValue $root
                if ([string]::IsNullOrWhiteSpace($rootKey)) { continue }
                if ($entryKey -eq $rootKey -or $entryKey -eq "$rootKey\\Scripts" -or $entryKey -eq "$rootKey\\condabin" -or $entryKey.StartsWith("$rootKey\\envs\\")) {
                    $shouldRemove = $true
                    break
                }
            }

            if ($shouldRemove) {
                $report.RemovedPathEntries += "$scope::$entry"
            }
            else {
                $kept += $entry
            }
        }

        Set-EnvironmentPathEntries -Scope $scope -Entries $kept

        foreach ($varName in @("CONDA_PREFIX", "CONDA_DEFAULT_ENV", "CONDA_EXE", "CONDA_PYTHON_EXE", "_CE_M", "_CE_CONDA")) {
            $currentValue = [System.Environment]::GetEnvironmentVariable($varName, $scope)
            if (-not [string]::IsNullOrWhiteSpace($currentValue)) {
                [System.Environment]::SetEnvironmentVariable($varName, $null, $scope)
                $report.RemovedVariables += "$scope::$varName=$currentValue"
            }
        }
    }

    return [pscustomobject]$report
}

# ============================================================================
# 함수: Conda 환경 변수 등록 (경로 3개: root, Scripts, condabin)
# ============================================================================
# 역할: PATH 환경 변수에 Conda 경로 추가
# 범위: User 스코프만 (Machine/System 불필요)
# 추가 경로:
#   1. CondaRoot (메인 Conda 실행 파일)
#   2. Scripts (다양한 도구 모음, 예: activate.bat)
#   3. condabin (Conda 래퍼 스크립트)
# 보고: 추가된 경로 목록 반환
#
function Register-CondaEnvironmentSettings {
    param([Parameter(Mandatory = $true)][string]$CondaRoot)

    # 설정 변경사항 기록용 보고서 초기화
    $report = [ordered]@{
        AddedPathEntries = @()  # 추가된 PATH 엔트리 목록
        SetVariables = @()      # 추가 간 환경 변수 목록
    }

    # Conda 동작을 위한 3단계 도구 경로
    $condaPaths = @(
        $CondaRoot,                              # Conda root 디렉터리
        (Join-Path $CondaRoot "Scripts"),       # pip.exe, 가상환경 스크립트 등
        (Join-Path $CondaRoot "condabin")       # Conda 래퍼 스크립트 (리동 Batch)
    )

    # User 스코프로만 등록 (시스템 권한 불필요)
    foreach ($scope in @("User")) {
        try {
            $added = Add-EnvironmentPathEntries -Scope $scope -Entries $condaPaths
            foreach ($path in $added) {
                $report.AddedPathEntries += "$scope::$path"
            }
        }
        catch {
            $report.AddedPathEntries += "$scope::<failed> $($_.Exception.Message)"
        }
    }

    return [pscustomobject]$report
}

# ============================================================================
# 함수: TensorRT 환경 변수 등록 (경로 3개 + TRT_PATH 변수)
# ============================================================================
# 역할: PATH에 CUDA/TensorRT 경로 추가, TRT_PATH 환경 변수 설정
# 범위: User 스코프만 (Machine/System 불필요)
# 추가 경로:
#   1. CudaBinPath (CUDA toolkit\bin, cublas.dll 등)
#   2. TrtRoot\lib (TensorRT 라이브러리)
#   3. TrtRoot\bin (TensorRT 실행 파일 또는 추가 DLL)
# 변수: TRT_PATH = TensorRT 루트 (빌드 시 참조용)
# 보고: 추가된 경로 및 변수 목록 반환
#
function Register-TensorRTEnvironmentSettings {
    param(
        [Parameter(Mandatory = $true)][string]$TrtRoot,     # TensorRT 루트 디렉터리
        [Parameter(Mandatory = $true)][string]$CudaBinPath  # CUDA toolkit\bin 경로
    )

    # 설정 변경사항 기록용 보고서 초기화
    $report = [ordered]@{
        AddedPathEntries = @()  # 추가된 PATH 엔트리 목록
        SetVariables = @()      # 설정된 환경 변수 목록 (예: TRT_PATH)
    }

    # TensorRT 동작을 위한 3단계 경로 (CUDA bin, TRT lib, TRT bin)
    $trtPaths = @(
        $CudaBinPath,                   # CUDA 런타임 라이브러리들 (cublas.dll, curand.dll 등)
        (Join-Path $TrtRoot "lib"),    # TensorRT 정적/동적 라이브러리 (.lib, .dll)
        (Join-Path $TrtRoot "bin")     # TensorRT 런타임 바이너리 또는 추가 DLL
    )

    # User 스코프로만 등록 (시스템 권한 불필요)
    foreach ($scope in @("User")) {
        try {
            $added = Add-EnvironmentPathEntries -Scope $scope -Entries $trtPaths
            foreach ($path in $added) {
                $report.AddedPathEntries += "$scope::$path"
            }
        }
        catch {
            $report.AddedPathEntries += "$scope::<failed> $($_.Exception.Message)"
        }

        try {
            [System.Environment]::SetEnvironmentVariable("TRT_PATH", $TrtRoot, $scope)
            $report.SetVariables += "$scope::TRT_PATH=$TrtRoot"
        }
        catch {
            $report.SetVariables += "$scope::TRT_PATH <failed> $($_.Exception.Message)"
        }
    }

    return [pscustomobject]$report
}

# ============================================================================
# 함수: Conda 환경 인벤토리 조사 (모든 후보 경로 검색)
# ============================================================================
# 역할: 지정된 Conda 루트 디렉터리 목록에서 가상환경 발견
# 알고리즘:
#   1. 각 후보 Conda 루트 폴더 유효성 검사 (conda.exe, envs 폴더 확인)
#   2. envs 폴더 내 모든 서브디렉터리를 가상환경으로 간주
#   3. null/공백 요소 필터링 (배열 초기화 오류 방지)
# 출력: []{Root, Environments} 객체 배열 (각 후보당 하나)
# 주의: 환경 폴더 존재 여부만 확인, activate 테스트 없음
#
function Get-CondaEnvironmentInventory {
    param([string[]]$CandidateRoots)  # Conda 루트 경로 배열 (중복 제거됨)

    $inventory = @()      # 발견된 Conda root + environments 목록
    $seenRoots = @{}      # 이미 처리한 경로 (중복 방지)

    foreach ($root in $CandidateRoots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $normalizedRoot = $root.TrimEnd('\\')
        if ([string]::IsNullOrWhiteSpace($normalizedRoot)) { continue }

        $rootKey = $normalizedRoot.ToLowerInvariant()
        if ($seenRoots.ContainsKey($rootKey)) { continue }
        $seenRoots[$rootKey] = $true

        $condaExe = Join-Path $normalizedRoot "Scripts\\conda.exe"
        if (-not (Test-Path -LiteralPath $condaExe)) { continue }

        $envNames = @()
        $envsDir = Join-Path $normalizedRoot "envs"
        if (Test-Path -LiteralPath $envsDir) {
            $envNames = @(
                Get-ChildItem -Path $envsDir -Directory -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty Name |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    Sort-Object
            )
        }

        $inventory += [pscustomobject]@{
            Root = $normalizedRoot
            Environments = @($envNames)
        }
    }

    return @($inventory)
}

# ============================================================================
# 함수: 메인 파이프라인 오케스트레이션 (전체 설치/배포 워크플로우)
# ============================================================================
# 역할: Miniconda, TensorRT, Python 환경 설치 자동화 주 진입점
# 매개변수:
#   - Ui: GUI 인터페이스 객체 (null = 콘솔 모드)
#   - CondaEnvVer: Python 가상환경 버전 스탬프 (예: 260909)
#   - EvaltoolsVer: Eval_Tools 배포판 버전 (예: 260801)
# 단계: 6개 메인 단계 (초기화 → 사전검사 → 설치 → 정리 → 등록 → 완료)
# 보고: GUI 진행상황 업데이트 및 로그 기록
#
function Invoke-PipelineSetup {
    param(
        [object]$Ui = $null,                                 # GUI 인터페이스 객체
        [string]$CondaEnvVer = $script:CondaEnvVer,          # Python env 버전 (버전 추적용)
        [string]$EvaltoolsVer = $script:EvaltoolsVer          # Eval Tools 버전
    )

    if ($null -ne $Ui) {
        Set-PipelineUi -Ui $Ui
    }

    # GUI 준비: 6단계 진행률 바 초기화
    if ($null -ne $script:PipelineUi -and $script:PipelineUi.PSObject.Methods.Name -contains "SetStep") {
        $script:PipelineUi.SetStep(0, "Initializing", 6)  # 총 6단계, 현재 0단계
    }

    Add-GuiLog "Version - CondaEnv: $CondaEnvVer / EvalTools: $EvaltoolsVer"

    # ============================================================================
    # 1단계: 설치 소스 경로 및 설정값 해석
    # ============================================================================
    
    # 패키지 설치 파일(Miniconda, TensorRT 등)이 위치한 로컬 캐시 루트.
    # 사용자가 지정한 PackageSourceRoot를 우선하되, 루트와 표준 하위 디렉터리는
    # 자동으로 생성한다. 다른 루트로 fallback 하지 않는다.
    $configuredSourcePath = if ($null -eq $script:PipelineConfig.PackageSourceRoot) { $null } else { [string]$script:PipelineConfig.PackageSourceRoot }
    if ([string]::IsNullOrWhiteSpace($configuredSourcePath)) {
        $sourcePath = Resolve-PackageSourcePath
    }
    else {
        $sourcePath = [System.IO.Path]::GetFullPath($configuredSourcePath)
        if (-not (Test-Path -LiteralPath $sourcePath)) {
            New-Item -ItemType Directory -Path $sourcePath -Force | Out-Null
            Add-GuiLog "    [SYNC] Created local package root: $sourcePath" -ForegroundColor DarkGray
        }
    }
    $cacheLayout = Initialize-LocalPackageCacheLayout -LocalRoot $sourcePath -RemoteRoot $null
    $sourcePath = $cacheLayout.Root
    $remoteSourcePath = if ($script:PipelineConfig.PSObject.Properties.Name -contains "RemotePackageSourceRoot") { $script:PipelineConfig.RemotePackageSourceRoot } else { $null }
    if (-not [string]::IsNullOrWhiteSpace($remoteSourcePath)) {
        try {
            $localFull = [System.IO.Path]::GetFullPath($sourcePath)
            $remoteFull = [System.IO.Path]::GetFullPath($remoteSourcePath)
            if ($localFull -eq $remoteFull) {
                $remoteSourcePath = $null
            }
        }
        catch {
            $remoteSourcePath = $null
        }
    }

    $cacheLayout = Initialize-LocalPackageCacheLayout -LocalRoot $sourcePath -RemoteRoot $null
    Add-GuiLog "Package source root: $($cacheLayout.Root)" -ForegroundColor DarkGray
    if (-not [string]::IsNullOrWhiteSpace($remoteSourcePath) -and (Test-Path -LiteralPath $remoteSourcePath)) {
        Add-GuiLog "Remote package source is optional backup only; this step will fetch required files individually." -ForegroundColor DarkGray
    }
    $targetCudaVersion_1 = $script:PipelineConfig.TargetCudaVersion_1
    $targetCudaVersion_2 = $script:PipelineConfig.TargetCudaVersion_2

    # 설치 경로/프로필 정책은 config 계층에서만 정의한다.
    $condaDest = $script:PipelineConfig.CondaDest
    $trtProfilesRaw = @(Get-PipelineTensorRTProfiles)

    # 유효한 TensorRT 프로필만 필터링 (Destination, ZipFile 모두 필수)
    $trtProfiles = @(
        $trtProfilesRaw |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_.Destination) -and -not [string]::IsNullOrWhiteSpace($_.ZipFile) }
    )
    if ($trtProfiles.Count -eq 0) {
        throw "No TensorRT profile is configured."
    }

    # 이후 정리/탐지 로직에서 전체 후보 루트가 필요하므로 배열로 보관한다.
    $allTrtRoots = @($trtProfiles | ForEach-Object { $_.Destination })

    # 프로필 인덱스에 따른 설치 경로 할당 (최대 3개 프로필)
    $trtDest_1 = if ($trtProfiles.Count -ge 1) { $trtProfiles[0].Destination } else { $null }
    $trtDest_2 = if ($trtProfiles.Count -ge 2) { $trtProfiles[1].Destination } else { $null }
    $trtDest_3 = if ($trtProfiles.Count -ge 3) { $trtProfiles[2].Destination } else { $null }
    $evalToolsDest = $script:PipelineConfig.EvalToolsDest
    $envName = $script:PipelineConfig.DefaultEnvName

    # ============================================================================
    # 2단계: 사전 검사 (기존 설치 탐지)
    # ============================================================================
    
    # 각 의존성 탐지 플래그 초기화
    $isCudnnInstalled = $false     # cuDNN 라이브러리 설치 여부
    $isZlibInstalled = $false      # zlib 의존성 설치 여부
    $isCondaInstalled = $false     # Miniconda 설치 여부
    $isTrtInstalled = $false       # TensorRT 설치 여부
    $foundCondaPath = $null        # 발견된 Conda 경로 (단일)
    $foundCondaPaths = @()         # 발견된 모든 Conda 경로 (배열)
    $nonTargetCondaPaths = @()
    $hasCondaPathMismatch = $false
    $foundTrtPath = $null
    $trtCandidates = @()

    $cudnnZipFile_1 = $script:PipelineConfig.CudnnZipFile_1
    $cudnnZipFile_2 = $script:PipelineConfig.CudnnZipFile_2
    $zlibDllFile = $script:PipelineConfig.ZlibDllFile
    $condaExeName = $script:PipelineConfig.CondaExeName
    $evalToolsZipPattern = $script:PipelineConfig.EvalToolsZipPattern
    $evalToolsZipFile = ($evalToolsZipPattern -f $EvaltoolsVer)
    # Python 환경 설정 (offline conda env + pip install)
    $pythonVersion = $script:PipelineConfig.PythonVersion
    $requirementsWheelhouseRoot = $script:PipelineConfig.RequirementsWheelhouseRoot
    $requirementsLockFile_Cu11 = $script:PipelineConfig.RequirementsLockFile_Cu11
    $requirementsLockFile_Cu12 = $script:PipelineConfig.RequirementsLockFile_Cu12

    Add-GuiLog "#============================================================#" -ForegroundColor Cyan
    Add-GuiLog "# Pipeline setup automation started                          #" -ForegroundColor Cyan
    Add-GuiLog "#============================================================#" -ForegroundColor Cyan
    Add-GuiLog ""
    Add-GuiLog "Pre-check: scanning current system status..." -ForegroundColor Yellow
    Set-GuiStepProgress -Step 1 -Title "Pre-check" -Running

    try {
        Install-7ZipIfMissing -SourcePath $sourcePath -RemoteSourcePath $remoteSourcePath
        Set-GuiSubProgress -Percent 10

        $nvidiaSmi = Get-Command "nvidia-smi" -ErrorAction SilentlyContinue
        if ($nvidiaSmi) {
            $driverVer = (nvidia-smi --query-gpu=driver_version --format=csv,noheader) -join ", "
            Add-GuiLog "    [OK] NVIDIA driver detected: $driverVer"
        } else {
            throw "NVIDIA driver check failed (nvidia-smi not found)."
        }
        Set-GuiSubProgress -Percent 20

        $nvccCommand = Get-Command "nvcc" -ErrorAction SilentlyContinue
        if (-not $nvccCommand) {
            throw "CUDA toolkit check failed (nvcc not found)."
        }

        $nvccPath = $nvccCommand.Source
        $cudaVerString = (& $nvccPath --version | Select-String "release").ToString()
        $cudaVerNum = [regex]::Match($cudaVerString, "release (\d+\.\d+)").Groups[1].Value
        $cudaVerNum = if ([string]::IsNullOrWhiteSpace($cudaVerNum)) { "" } else { $cudaVerNum.Trim() }
        $cudaVerNum = if ($cudaVerNum -match '^(\d+)\.(\d+)(?:\.\d+)?$') { "$($Matches[1]).$($Matches[2])" } else { $cudaVerNum }
        $targetCudaVersion_1 = Normalize-CudaVersionLabel -Version $targetCudaVersion_1
        $targetCudaVersion_2 = @($targetCudaVersion_2 | ForEach-Object { Normalize-CudaVersionLabel -Version $_ })
        Set-GuiSubProgress -Percent 35

        # CUDA 버전별 기본 선택 번호도 config 정책을 따른다.
        $defaultTrtOptionNo = Get-DefaultTensorRTOptionNumber -CudaVersion $cudaVerNum -TargetCudaVersion_1 $targetCudaVersion_1 -TargetCudaVersion_2 $targetCudaVersion_2

        switch ($true) {
            ($cudaVerNum -eq $targetCudaVersion_1) {
                $cudnnZipFile = $cudnnZipFile_1
                $cudaTrackTag = "cu11"
            }
            ($cudaVerNum -in $targetCudaVersion_2) {
                $cudnnZipFile = $cudnnZipFile_2
                $cudaTrackTag = "cu12"
            }
            default {
                throw "Unsupported CUDA version: $cudaVerNum (required: $targetCudaVersion_1 or $($targetCudaVersion_2 -join ', '))."
            }
        }

        $selectedTrtProfile = Request-TensorRTOptionSelection -DetectedCudaVersion $cudaVerNum -Options $trtProfiles -DefaultOptionNumber $defaultTrtOptionNo
        if ($null -eq $selectedTrtProfile) {
            Add-GuiLog "Canceled by user at TensorRT version selection." -ForegroundColor Red
            return
        }

        $trtDest = $selectedTrtProfile.Destination
        $trtZipFile = $selectedTrtProfile.ZipFile
        Add-GuiLog "    [OK] Selected TensorRT profile: $($selectedTrtProfile.Name) -> $trtDest"

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
        Set-GuiSubProgress -Percent 55

        if (Test-Path $zlibDll) {
            $isZlibInstalled = $true
            Add-GuiLog "    [OK] zlibwapi.dll detected."
        } else {
            Add-GuiLog "    [MISS] zlibwapi.dll not found in $cudaBinPath" -ForegroundColor Yellow
        }
        Set-GuiSubProgress -Percent 70

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
                $foundCondaPaths += $path.TrimEnd('\\')
            }
        }

        if ($foundCondaPaths.Count -gt 0) {
            $isCondaInstalled = $true
            $foundCondaPaths = $foundCondaPaths | Select-Object -Unique

            $targetCondaPath = $condaDest.TrimEnd('\\')
            $matchedTargetConda = $foundCondaPaths |
                Where-Object { $_.TrimEnd('\\') -ieq $targetCondaPath } |
                Select-Object -First 1

            if ($matchedTargetConda) {
                $foundCondaPath = $matchedTargetConda
            }
            else {
                $foundCondaPath = $foundCondaPaths[0]
            }

            $nonTargetCondaPaths = @(
                $foundCondaPaths |
                    Where-Object { $_.TrimEnd('\\') -ine $targetCondaPath }
            )
            $hasCondaPathMismatch = ($nonTargetCondaPaths.Count -gt 0)

            Add-GuiLog "    [OK] Conda detected: $foundCondaPath" -ForegroundColor Green
            if ($hasCondaPathMismatch) {
                Add-GuiLog "    [MISS] Conda exists in non-target path(s). Reinstall to target path will be planned: $condaDest" -ForegroundColor Yellow
            }
        } else {
            Add-GuiLog "    [MISS] Conda not detected. Will install Miniconda." -ForegroundColor Yellow
        }
        Set-GuiSubProgress -Percent 85

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
        foreach ($knownRoot in $allTrtRoots) {
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
                $selectedRoot = $matchedExpectedTrt.TrimEnd('\\')
                $selectedRootKey = Get-PathCompareKey -PathValue $selectedRoot
                $selectedLibKey = Get-PathCompareKey -PathValue (Join-Path $selectedRoot "lib")
                $selectedBinKey = Get-PathCompareKey -PathValue (Join-Path $selectedRoot "bin")

                $userTrtPath = [System.Environment]::GetEnvironmentVariable("TRT_PATH", "User")
                $machineTrtPath = [System.Environment]::GetEnvironmentVariable("TRT_PATH", "Machine")
                $userTrtPathKey = Get-PathCompareKey -PathValue $userTrtPath
                $machineTrtPathKey = Get-PathCompareKey -PathValue $machineTrtPath

                $pathContainsSelected = $false
                foreach ($entry in $allPaths) {
                    $entryKey = Get-PathCompareKey -PathValue $entry
                    if ($entryKey -eq $selectedLibKey -or $entryKey -eq $selectedBinKey) {
                        $pathContainsSelected = $true
                        break
                    }
                }

                $trtPathMatchesSelected = ($userTrtPathKey -eq $selectedRootKey) -or ($machineTrtPathKey -eq $selectedRootKey)

                if ($trtPathMatchesSelected -or $pathContainsSelected) {
                    $isTrtInstalled = $true
                    $foundTrtPath = $matchedExpectedTrt
                }
                else {
                    Add-GuiLog "    [MISS] TensorRT files exist at selected path, but active PATH/TRT_PATH point to a different version. Reinstall required." -ForegroundColor Yellow
                }
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
    } elseif ($hasCondaPathMismatch) {
        $installPlanKeys += "CONDA"
        $installPlanText += "Conda cleanup + reinstall to target path -> $condaDest"
    } else {
        $installPlanText += "Miniconda reinstall available at Step 2 -> $condaDest"
    }
    # TensorRT 설치 계획 규칙
    # - Step3에서 Install을 선택하면 기존 설치 유무와 상관없이 정리 후 재설치한다.
    # - 여기의 계획은 사전 안내용으로만 사용된다.
    if (-not $isTrtInstalled) {
        $installPlanKeys += "TRT"
        $installPlanText += "TensorRT -> $trtDest"
    } else {
        $installPlanText += "TensorRT reinstall available at Step 3 -> $trtDest"
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
        do {
            $stepDecision = Request-StepInstallDecision -StepTitle "Step 2 - Miniconda" -DetailLines @(
                "Category: Runtime Dependency",
                "Subject: Miniconda",
                "Source: $condaExeName",
                "Target: $condaDest",
                "Action: Full reinstall (remove existing Conda + install /S)",
                "Status: " + ($(if ([string]::IsNullOrWhiteSpace($foundCondaPath)) { "Not found" } else { "Detected at $foundCondaPath" })),
                "Pre-check: " + ($(if (-not $isCondaInstalled) { "Not installed" } elseif ($hasCondaPathMismatch) { "Installed in non-target path(s)" } else { "Installed in target path" })),
                "Note: Install executes full cleanup + reinstall even when target path already matches.",
                "System Env: Cleanup removes User/Machine entries; registration adds User entries only"
            )

            if ($stepDecision -eq "Abort") {
                Add-GuiLog "Canceled by user at Step 2 (Miniconda)." -ForegroundColor Red
                return
            }

            Set-GuiStepProgress -Step 2 -Title "Miniconda" -Running
            if ($stepDecision -eq "Skip") {
                Add-GuiLog "[1/5] Miniconda step skipped by user." -ForegroundColor Yellow
                break
            }

            $condaFile = "pkgs\$condaExeName"
            $syncResult = Sync-StepRequiredFiles -LocalRoot $sourcePath -RemoteRoot $remoteSourcePath -RequiredFiles @($condaFile) -StepTitle "Step 2 - Miniconda" -Purpose "Download the Miniconda installer needed for this step before installation" -RequestConfirmation:$true
            if (-not $syncResult) {
                Add-GuiLog "[1/5] Miniconda sync canceled or unavailable. Re-showing the step decision." -ForegroundColor Yellow
                continue
            }
            if (-not (Test-Path -LiteralPath (Join-Path $sourcePath $condaFile))) {
                throw "Required Miniconda installer is still missing in PackageSourceRoot after sync: $sourcePath\$condaFile"
            }
            Add-GuiLog "[1/5] Reinstalling Miniconda (full cleanup)..." -ForegroundColor Yellow

            $condaCleanupCandidates = @()
            $condaCleanupCandidates += $foundCondaPaths
            $condaCleanupCandidates += $commonCondaPaths
            $condaCleanupCandidates += $condaDest
            $condaCleanupCandidates = @(
                $condaCleanupCandidates |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    Select-Object -Unique
            )

            $condaInventory = @(Get-CondaEnvironmentInventory -CandidateRoots $condaCleanupCandidates)
            $hasAnyEnvFolders = $false
            $deleteTargetRootsForWarning = @()

            foreach ($item in $condaInventory) {
                $validEnvNames = @($item.Environments | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                if ($validEnvNames.Count -gt 0) {
                    $hasAnyEnvFolders = $true
                    $deleteTargetRootsForWarning += $item.Root
                }
            }

            if ($hasAnyEnvFolders -and $deleteTargetRootsForWarning.Count -gt 0) {
                $confirmDetailLines = @(
                    "Category: Safety Confirmation",
                    "Subject: Conda cleanup before reinstall",
                    "Action: Delete all detected Conda roots and contained virtual environments",
                    "Target: $condaDest",
                    "Note: This deletion is permanent"
                )

                foreach ($root in $deleteTargetRootsForWarning) {
                    $item = $condaInventory | Where-Object { $_.Root -ieq $root } | Select-Object -First 1
                    if ($null -eq $item) { continue }
                    $validEnvNames = @($item.Environments | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                    $envText = if ($validEnvNames.Count -gt 0) { ($validEnvNames -join ", ") } else { "(none)" }
                    $confirmDetailLines += "Conda Root: $($item.Root)"
                    $confirmDetailLines += "Env Names: $envText"
                }

                $cleanupConfirmDecision = Request-StepInstallDecision -StepTitle "Step 2 - Confirm Conda Cleanup" -DetailLines $confirmDetailLines -Warning
                if ($cleanupConfirmDecision -eq "Abort") {
                    Add-GuiLog "Miniconda reinstall canceled by user at cleanup confirmation." -ForegroundColor Red
                    return
                }
                if ($cleanupConfirmDecision -eq "Skip") {
                    Add-GuiLog "Miniconda reinstall skipped at cleanup confirmation - moving to next step." -ForegroundColor Yellow
                    break
                }
            }
            else {
                Add-GuiLog "    [INFO] No active Miniconda delete targets were found. Cleanup will continue without a warning popup." -ForegroundColor DarkGray
            }

            $condaCleanupReport = Remove-CondaInstallations -CandidateRoots $condaCleanupCandidates -TargetRoot $condaDest -IncludeTargetRoot
            foreach ($removedRoot in @($condaCleanupReport.RemovedRoots)) {
                Add-GuiLog "    [CLEAN] Removed Conda root: $removedRoot" -ForegroundColor DarkYellow
            }
            foreach ($failedRoot in @($condaCleanupReport.FailedRoots)) {
                Add-GuiLog "    [WARN] Failed to remove Conda root: $failedRoot" -ForegroundColor Yellow
            }
            if (@($condaCleanupReport.FailedRoots).Count -gt 0) {
                throw "Conda cleanup failed. Please close processes using Conda and retry."
            }

            $condaEnvCleanupReport = Remove-CondaEnvironmentSettings -KnownRoots $condaCleanupCandidates
            foreach ($removedPathEntry in $condaEnvCleanupReport.RemovedPathEntries) {
                Add-GuiLog "    [CLEAN] PATH entry removed: $removedPathEntry" -ForegroundColor DarkYellow
            }

            $installArgs = @(
                "/S",
                "/InstallationType=AllUsers",
                "/NoShortcuts=0",
                "/RegisterPython=0",
                "/D=$condaDest"
            )

            Invoke-ProcessWithGuiProgress `
                -FilePath "$sourcePath\pkgs\$condaExeName" `
                -ArgumentList $installArgs `
                -StartPercent 0 `
                -MaxPercentWhileRunning 95 `
                -TickMilliseconds 250

            if (Test-Path "$condaDest\Scripts") {
                $foundCondaPath = $condaDest
                Add-GuiLog "    [OK] Miniconda installed: $condaDest" -ForegroundColor Green

                $condaEnvRegisterReport = Register-CondaEnvironmentSettings -CondaRoot $condaDest
                foreach ($addedPathEntry in $condaEnvRegisterReport.AddedPathEntries) {
                    Add-GuiLog "    [ENV][USER-ONLY] PATH entry registered: $addedPathEntry" -ForegroundColor Green
                }
            }
            else {
                throw "Miniconda install failed."
            }

            $resolvedCondaExe = Resolve-CondaExecutable -PreferredRoot $condaDest
            if (-not [string]::IsNullOrWhiteSpace($resolvedCondaExe)) {
                $activeCondaPath = Split-Path -Parent (Split-Path -Parent $resolvedCondaExe)
            }
            else {
                $activeCondaPath = $condaDest
            }

            break
        } while ($true)
        Set-GuiStepProgress -Step 2 -Title "Miniconda"
    }
    catch {
        if ($_.Exception.Message -match 'Download-only request accepted') {
            Add-GuiLog "[PAUSE] Download-only selection accepted. setup is paused until Install is chosen explicitly." -ForegroundColor Yellow
            throw
        }
        Show-StageError -Stage "Step 1 - Miniconda" -ErrorRecord $_
        return
    }

    $resolvedCondaExe = Resolve-CondaExecutable -PreferredRoot $condaDest
    if (-not [string]::IsNullOrWhiteSpace($foundCondaPath) -and (Test-Path "$foundCondaPath\Scripts\conda.exe")) {
        $activeCondaPath = $foundCondaPath
    }
    elseif (-not [string]::IsNullOrWhiteSpace($resolvedCondaExe)) {
        $activeCondaPath = Split-Path -Parent (Split-Path -Parent $resolvedCondaExe)
    }
    else {
        $activeCondaPath = $condaDest
    }

    if ([string]::IsNullOrWhiteSpace($resolvedCondaExe)) {
        throw "Conda executable is not available. Install Miniconda or ensure an existing Conda installation is on PATH before creating the Python environment."
    }

    try {
        do {
            $stepDecision = Request-StepInstallDecision -StepTitle "Step 3 - TensorRT" -DetailLines @(
            "Category: Runtime Dependency",
            "Subject: TensorRT",
            "Profile: $($selectedTrtProfile.Name)",
            "Source: $trtZipFile",
            "Target: $trtDest",
            "Action: Full reinstall (remove existing TensorRT + deploy selected profile)",
            "CUDA Track: $cudaTrackTag",
            "Pre-check: " + ($(if ($isTrtInstalled) { "Detected at target path" } elseif (-not [string]::IsNullOrWhiteSpace($foundTrtPath)) { "Detected at non-target path" } else { "Not detected" })),
            "System Env: Cleanup removes User/Machine PATH + TRT_PATH; registration writes User only"
        )

        if ($stepDecision -eq "Abort") {
            Add-GuiLog "Canceled by user at Step 3 (TensorRT)." -ForegroundColor Red
            return
        }

        Set-GuiStepProgress -Step 3 -Title "TensorRT" -Running
        if ($stepDecision -eq "Skip") {
            Add-GuiLog "[2/5] TensorRT step skipped by user." -ForegroundColor Yellow
            break
        }

        $trtArchive = "pkgs\$trtZipFile"
        $syncResult = Sync-StepRequiredFiles -LocalRoot $sourcePath -RemoteRoot $remoteSourcePath -RequiredFiles @($trtArchive) -StepTitle "Step 3 - TensorRT" -Purpose "Download the selected TensorRT archive needed for this step before installation" -RequestConfirmation:$true
        if (-not $syncResult) {
            Add-GuiLog "[2/5] TensorRT sync canceled or unavailable. Re-showing the step decision." -ForegroundColor Yellow
            continue
        }
        if (-not (Test-Path -LiteralPath (Join-Path $sourcePath $trtArchive))) {
            throw "Required TensorRT archive is still missing in PackageSourceRoot after sync: $sourcePath\$trtArchive"
        }
        Add-GuiLog "[2/5] Reinstalling TensorRT (full cleanup)..." -ForegroundColor Yellow

        $cleanupRoots = @()
        $cleanupRoots += $trtCandidates
        $cleanupRoots += $foundTrtPath
        $cleanupRoots += $trtDest_1
        $cleanupRoots += $trtDest_2
        $cleanupRoots += $trtDest_3

        $installCleanupReport = Remove-TensorRTInstallations -CandidateRoots $cleanupRoots
        foreach ($removedRoot in $installCleanupReport.RemovedRoots) {
            Add-GuiLog "    [CLEAN] Removed TensorRT root: $removedRoot" -ForegroundColor DarkYellow
        }
        foreach ($skippedRoot in $installCleanupReport.SkippedRoots) {
            Add-GuiLog "    [CLEAN] Skipped TensorRT root: $skippedRoot" -ForegroundColor DarkGray
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
        Expand-PackageArchiveWithGuiProgress -ArchivePath "$sourcePath\pkgs\$trtZipFile" -DestinationPath "$trtDest" -StartPercent 0 -EndPercent 95
        if (Test-Path "$trtDest\lib") {
            $isTrtInstalled = $true
            $foundTrtPath = $trtDest
            Add-GuiLog "    [OK] TensorRT deployed: $trtDest" -ForegroundColor Green

            $trtEnvRegisterReport = Register-TensorRTEnvironmentSettings -TrtRoot $trtDest -CudaBinPath $cudaBinPath
            foreach ($addedPathEntry in $trtEnvRegisterReport.AddedPathEntries) {
                Add-GuiLog "    [ENV][USER-ONLY] PATH entry registered: $addedPathEntry" -ForegroundColor Green
            }
            foreach ($setVar in $trtEnvRegisterReport.SetVariables) {
                Add-GuiLog "    [ENV][USER-ONLY] Variable updated: $setVar" -ForegroundColor Green
            }
        } else {
            throw "TensorRT deploy failed (lib folder missing)."
        }
        break
    } while ($true)
    Set-GuiStepProgress -Step 3 -Title "TensorRT"
}
catch {
        if ($_.Exception.Message -match 'Download-only request accepted') {
            Add-GuiLog "[PAUSE] Download-only selection accepted. setup is paused until Install is chosen explicitly." -ForegroundColor Yellow
            throw
        }
        Show-StageError -Stage "Step 2 - TensorRT" -ErrorRecord $_
        return
    }

    try {
        do {
        $stepDecision = Request-StepInstallDecision -StepTitle "Step 4 - cuDNN / zlib" -DetailLines @(
            "Category: Runtime Dependency",
            "Subject: cuDNN / zlib",
            "Source (cu11): $cudnnZipFile_1",
            "Source (cu12): $cudnnZipFile_2",
            "Source (selected cuDNN): $cudnnZipFile",
            "Source (zlib): $zlibDllFile",
            "Target: $cudaBinPath",
            "Action: Deploy selected CUDA runtime dependencies",
            "Pre-check: " + ($(if (($installPlanKeys -contains "CUDNN") -or ($installPlanKeys -contains "ZLIB")) { "Deploy planned" } else { "Already installed -> normally skipped" }))
        )

        if ($stepDecision -eq "Abort") {
            Add-GuiLog "Canceled by user at Step 4 (cuDNN/zlib)." -ForegroundColor Red
            return
        }

        Set-GuiStepProgress -Step 4 -Title "cuDNN/zlib" -Running
        if ($stepDecision -eq "Skip") {
            Add-GuiLog "[3/5] cuDNN/zlib step skipped by user." -ForegroundColor Yellow
            break
        } elseif (($installPlanKeys -contains "CUDNN") -or ($installPlanKeys -contains "ZLIB")) {
            $cudaDependencyFiles = @()
            if ($installPlanKeys -contains "CUDNN") { $cudaDependencyFiles += "pkgs\$cudnnZipFile" }
            if ($installPlanKeys -contains "ZLIB") { $cudaDependencyFiles += "pkgs\$zlibDllFile" }
            if ($cudaDependencyFiles.Count -gt 0) {
                $syncResult = Sync-StepRequiredFiles -LocalRoot $sourcePath -RemoteRoot $remoteSourcePath -RequiredFiles $cudaDependencyFiles -StepTitle "Step 4 - cuDNN / zlib" -Purpose "Download the CUDA runtime files needed for this step before installation" -RequestConfirmation:$true
                if (-not $syncResult) {
                    Add-GuiLog "[3/5] CUDA dependency sync canceled or unavailable. Re-showing the step decision." -ForegroundColor Yellow
                    continue
                }
            }
            if ($installPlanKeys -contains "CUDNN" -and -not (Test-Path -LiteralPath (Join-Path $sourcePath "pkgs\$cudnnZipFile"))) {
                throw "Required cuDNN package is still missing in PackageSourceRoot after sync: $sourcePath\pkgs\$cudnnZipFile"
            }
            if ($installPlanKeys -contains "ZLIB" -and -not (Test-Path -LiteralPath (Join-Path $sourcePath "pkgs\$zlibDllFile"))) {
                throw "Required zlib package is still missing in PackageSourceRoot after sync: $sourcePath\pkgs\$zlibDllFile"
            }
            Add-GuiLog "[3/5] Deploying CUDA runtime dependencies..." -ForegroundColor Yellow
            $cudaRootPath = Split-Path -Parent $cudaBinPath

            if ($installPlanKeys -contains "CUDNN") {
                $cudnnZipPath = Join-Path "$sourcePath\pkgs" $cudnnZipFile
                if (-not (Test-Path $cudnnZipPath)) {
                    throw "cuDNN package not found: $cudnnZipPath"
                }

                # ============================================================================
                # cuDNN 아카이브 압축 해제 및 폴더 구조 3단계 탐색
                # ============================================================================
                # 문제: 7z/ZIP 아카이브의 폴더 구조가 일관성 없음
                #   - 때로 직접: temp/bin, temp/include, temp/lib (래핑 없음)
                #   - 때로 래퍼: temp/cudnn-xxx/bin, temp/cudnn-xxx/include, temp/cudnn-xxx/lib
                # 해결: 3단계 탐색으로 모든 경우 대응
                # 주의: 이 동작은 7z 압축 구조의 정상 변이, 파일 손상 아님
                #
                $cudnnTempDir = Join-Path $env:TEMP ("cudnn_extract_" + [guid]::NewGuid().ToString("N"))
                Set-GuiSubProgress -Percent 0
                Expand-PackageArchiveWithGuiProgress -ArchivePath $cudnnZipPath -DestinationPath $cudnnTempDir -StartPercent 0 -EndPercent 45

                # 탐색 순서 (성공하면 다음 단계 건너뜀):
                
                # 1단계: 임시폴더 직접 확인 (bin/include/lib 바로 위치)
                $cudnnRoot = $null
                if ((Test-Path (Join-Path $cudnnTempDir "bin")) -and (Test-Path (Join-Path $cudnnTempDir "include")) -and (Test-Path (Join-Path $cudnnTempDir "lib"))) {
                    $cudnnRoot = Get-Item -Path $cudnnTempDir
                }
                
                # 2단계: 임시폴더 안 첫 번째 하위폴더 확인 (7z 표준 래퍼 구조)
                if ($null -eq $cudnnRoot) {
                    $firstSubDir = Get-ChildItem -Path $cudnnTempDir -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($null -ne $firstSubDir -and (Test-Path (Join-Path $firstSubDir.FullName "bin")) -and (Test-Path (Join-Path $firstSubDir.FullName "include")) -and (Test-Path (Join-Path $firstSubDir.FullName "lib"))) {
                        $cudnnRoot = $firstSubDir
                    }
                }
                
                # 3단계: 재귀적으로 탐색 (비표준/중첩 구조 대응)
                if ($null -eq $cudnnRoot) {
                    $cudnnRoot = Get-ChildItem -Path $cudnnTempDir -Directory -Recurse -ErrorAction SilentlyContinue |
                        Where-Object { (Test-Path (Join-Path $_.FullName "bin")) -and (Test-Path (Join-Path $_.FullName "include")) -and (Test-Path (Join-Path $_.FullName "lib")) } |
                        Select-Object -First 1
                }

                # 모든 탐색 단계 실패 → 아카이브 구조 오류
                if ($null -eq $cudnnRoot) {
                    Remove-Item -Path $cudnnTempDir -Recurse -Force -ErrorAction SilentlyContinue
                    throw "cuDNN root (bin/include/lib) not found inside archive."
                }

                # ============================================================================
                # cuDNN 파일들을 CUDA 루트로 복사 (진행률 세분화)
                # ============================================================================
                # bin: 런타임 라이브러리 (예: cudnn.dll)
                # include: 헤더 파일 (예: cudnn.h)
                # lib: 정적/임포트 라이브러리 (예: cudnn.lib)
                # 파일 단위 진행률 갱신으로 길어진 복사 시간 동안 UI 멈춤 방지
                #
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
            Add-GuiLog "    [INFO] OK selected, but cuDNN/zlib are already present. Reinstall is skipped." -ForegroundColor Cyan
            Add-GuiLog "[3/5] CUDA dependency deploy skipped." -ForegroundColor Cyan
        }
        break
    } while ($true)
    Set-GuiStepProgress -Step 4 -Title "cuDNN/zlib"
}
catch {
        if ($_.Exception.Message -match 'Download-only request accepted') {
            Add-GuiLog "[PAUSE] Download-only selection accepted. setup is paused until Install is chosen explicitly." -ForegroundColor Yellow
            throw
        }
        Show-StageError -Stage "Step 3 - cuDNN/zlib" -ErrorRecord $_
        return
    }

    try {
        # 지정된 CUDA 트랙에 따른 lock 파일 결정
        # common.lock.txt는 공통 베이스이므로, 선택된 CUDA 트랙 설치 시 반드시 같이 준비해야 한다.
        $commonLockFile = $script:PipelineConfig.RequirementsLockFile_Common
        $selectedLockFile = switch ($cudaTrackTag.ToLower()) {
            "cu11" { $requirementsLockFile_Cu11 }
            "cu12" { $requirementsLockFile_Cu12 }
            default { $requirementsLockFile_Cu11 }
        }

        # 절대 경로로 변환 (로컬 캐시 루트를 기본으로 사용하고,
        # 원격 공유 파일은 로컬에 없는 경우에만 복사해 사용한다.)
        $commonLockFilePath = Join-Path $sourcePath $commonLockFile
        $lockFilePath = Join-Path $sourcePath $selectedLockFile
        $approvedWheelhouseRoot = Join-Path $sourcePath $requirementsWheelhouseRoot
        $wheelhouseCommonPath = Join-Path $approvedWheelhouseRoot "common"
        $wheelhouseTrackPath = Join-Path $approvedWheelhouseRoot $cudaTrackTag.ToLower()

        Add-GuiLog "[SYNC-PLAN] Preparing local package cache for Python env step..." -ForegroundColor Cyan
        $pythonEnvSyncFiles = @(
            $commonLockFile,
            $selectedLockFile
        )

        do {
            $syncDecision = Request-StepInstallDecision -StepTitle "Step 5 - Python env (cache sync)" -DetailLines @(
                "Category: Local cache sync",
                "Subject: Python env prerequisites",
                "Source: $remoteSourcePath",
                "Destination: $sourcePath",
                "Files: $($pythonEnvSyncFiles -join ', ')",
                "Action: Download missing lock files required before creating the Python env"
            )

            if ($syncDecision -eq "Abort") {
                Add-GuiLog "Canceled by user before Python env cache sync." -ForegroundColor Red
                return
            }

            if ($syncDecision -eq "Skip") {
                Add-GuiLog "[SYNC] Python env cache sync skipped by user; proceeding without downloaded lock files." -ForegroundColor Yellow
                break
            }

            $syncResult = Sync-StepRequiredFiles -LocalRoot $sourcePath -RemoteRoot $remoteSourcePath -RequiredFiles $pythonEnvSyncFiles -StepTitle "Pre-sync: local cache" -Purpose "Sync the shared common lock and the selected CUDA lock before refreshing the approved wheelhouse for this CUDA track" -RequestConfirmation:$true -CompareHashForExistingFiles:$true
            if (-not $syncResult) {
                Add-GuiLog "[SYNC] Lock/wheelhouse download was canceled; re-opening the Python env step decision." -ForegroundColor Yellow
                continue
            }
            break
        } while ($true)

        if (-not [string]::IsNullOrWhiteSpace($remoteSourcePath)) {
            $remoteCommonLockPath = Join-Path $remoteSourcePath $commonLockFile
            if (Test-Path -LiteralPath $remoteCommonLockPath) {
                if (-not (Test-Path -LiteralPath $commonLockFilePath)) {
                    Copy-Item -LiteralPath $remoteCommonLockPath -Destination $commonLockFilePath -Force
                    Add-GuiLog "    [SYNC] Copied shared common lock file to local cache: $commonLockFilePath" -ForegroundColor DarkYellow
                }
                else {
                    $localCommonLockHash = (Get-FileHash -LiteralPath $commonLockFilePath -Algorithm SHA256).Hash.ToUpperInvariant()
                    $remoteCommonLockHash = (Get-FileHash -LiteralPath $remoteCommonLockPath -Algorithm SHA256).Hash.ToUpperInvariant()
                    if ($localCommonLockHash -ne $remoteCommonLockHash) {
                        Copy-Item -LiteralPath $remoteCommonLockPath -Destination $commonLockFilePath -Force
                        Add-GuiLog "    [SYNC] Updated shared common lock file because SHA256 changed: $commonLockFilePath" -ForegroundColor DarkYellow
                    }
                    else {
                        Add-GuiLog "    [SKIP] Common lock file already matches remote SHA256: $commonLockFilePath" -ForegroundColor DarkGray
                    }
                }
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($remoteSourcePath)) {
            $remoteSelectedLockPath = Join-Path $remoteSourcePath $selectedLockFile
            if (Test-Path -LiteralPath $remoteSelectedLockPath) {
                if (-not (Test-Path -LiteralPath $lockFilePath)) {
                    Copy-Item -LiteralPath $remoteSelectedLockPath -Destination $lockFilePath -Force
                    Add-GuiLog "    [SYNC] Copied selected CUDA lock file to local cache: $lockFilePath" -ForegroundColor DarkYellow
                }
                else {
                    $localSelectedLockHash = (Get-FileHash -LiteralPath $lockFilePath -Algorithm SHA256).Hash.ToUpperInvariant()
                    $remoteSelectedLockHash = (Get-FileHash -LiteralPath $remoteSelectedLockPath -Algorithm SHA256).Hash.ToUpperInvariant()
                    if ($localSelectedLockHash -ne $remoteSelectedLockHash) {
                        Copy-Item -LiteralPath $remoteSelectedLockPath -Destination $lockFilePath -Force
                        Add-GuiLog "    [SYNC] Updated selected CUDA lock file because SHA256 changed: $lockFilePath" -ForegroundColor DarkYellow
                    }
                    else {
                        Add-GuiLog "    [SKIP] Selected CUDA lock file already matches remote SHA256: $lockFilePath" -ForegroundColor DarkGray
                    }
                }
            }
        }

        $preflight = Assert-PythonRequirementsInstallPreflight -LocalRoot $sourcePath -CommonLockFile $commonLockFile -SelectedLockFile $selectedLockFile -CudaTrackTag $cudaTrackTag
        Add-GuiLog "    [OK] Python install preflight passed: $($preflight.CommonLock) | $($preflight.SelectedLock)" -ForegroundColor Green
        Add-GuiLog "    [OK] Approved wheelhouse verified: $($preflight.CommonWheelhouse) | $($preflight.TrackWheelhouse)" -ForegroundColor Green

        $condaGuard = Ensure-PythonEnvCondaReady -PreferredRoot $condaDest -ActiveCondaPath $activeCondaPath
        if ($null -eq $condaGuard) {
            return
        }

        $resolvedCondaExe = $condaGuard.Executable
        if (-not [string]::IsNullOrWhiteSpace($condaGuard.Root)) {
            $activeCondaPath = $condaGuard.Root
        }

        $stepDecision = Request-StepInstallDecision -StepTitle "Step 5 - Python env" -DetailLines @(
            "Category: Python Environment",
            "Subject: Conda env (offline)",
            "Name: $envName",
            "Python: $pythonVersion",
            "Source: Miniconda local pkgs + wheelhouse",
            "Target: $activeCondaPath\envs\$envName",
            "Action: Create env (conda offline) + install packages (pip offline)",
            "CUDA Track: $cudaTrackTag",
            "Version Stamp: $CondaEnvVer | $cudaTrackTag"
        )

        if ($stepDecision -eq "Abort") {
            Add-GuiLog "Canceled by user at Step 5 (Python env)." -ForegroundColor Red
            return
        }

        Set-GuiStepProgress -Step 5 -Title "Python env" -Running
        if ($stepDecision -eq "Skip") {
            Add-GuiLog "[4/5] Python env step skipped by user." -ForegroundColor Yellow
            Set-GuiStepProgress -Step 5 -Title "Python env"
        }
        else {
            Add-GuiLog "[4/5] Creating and configuring Python environment ($envName)..." -ForegroundColor Yellow
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
                        Add-GuiLog "    [INFO] OK selected, but Python env reinstall is skipped because version stamp matches." -ForegroundColor Cyan
                    }
                }
            }

            if ($needEnvUpdate) {
                if (Test-Path $fullEnvPath) {
                    Set-GuiSubProgress -Percent 20
                    Add-GuiLog "    [INFO] Removing existing environment..." -ForegroundColor DarkYellow
                    Remove-Item -Path $fullEnvPath -Recurse -Force -ErrorAction SilentlyContinue
                }

                Set-GuiSubProgress -Percent 0
                Add-GuiLog "    [1/3] Creating base Python $pythonVersion environment (offline)..." -ForegroundColor Cyan
                & $resolvedCondaExe create --offline -n $envName python=$pythonVersion -y 2>&1 | ForEach-Object {
                    $line = if ($null -eq $_) { "" } else { $_.ToString() }
                    if ($line -match "(successfully|error|failed)" -or $line.Length -lt 5) {
                        Add-GuiLog "        $line" -ForegroundColor DarkGray
                    }
                }
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to create conda environment $envName"
                }
                Add-GuiLog "    [OK] Base Python environment created: $envName" -ForegroundColor Green
                Set-GuiSubProgress -Percent 40

                Add-GuiLog "    [2/3] Refreshing approved wheelhouse from lock files..." -ForegroundColor Cyan
                $remoteCommonWheelhousePath = if (-not [string]::IsNullOrWhiteSpace($remoteSourcePath)) { Join-Path $remoteSourcePath $requirementsWheelhouseRoot } else { $null }
                $remoteTrackWheelhousePath = if (-not [string]::IsNullOrWhiteSpace($remoteSourcePath)) { Join-Path $remoteSourcePath $requirementsWheelhouseRoot } else { $null }

                if (-not [string]::IsNullOrWhiteSpace($remoteCommonWheelhousePath)) {
                    $remoteCommonWheelhousePath = Join-Path $remoteCommonWheelhousePath "common"
                }
                if (-not [string]::IsNullOrWhiteSpace($remoteTrackWheelhousePath)) {
                    $remoteTrackWheelhousePath = Join-Path $remoteTrackWheelhousePath $cudaTrackTag.ToLower()
                }

                Refresh-ApprovedWheelhouseFromLock -EnvironmentName $envName -LockFilePath $commonLockFilePath -TargetDirectory $wheelhouseCommonPath -Description "shared common wheelhouse refresh" -RemoteTargetDirectory $remoteCommonWheelhousePath
                Refresh-ApprovedWheelhouseFromLock -EnvironmentName $envName -LockFilePath $lockFilePath -TargetDirectory $wheelhouseTrackPath -Description "CUDA track wheelhouse refresh" -RemoteTargetDirectory $remoteTrackWheelhousePath
                $preflight = Assert-PythonRequirementsInstallPreflight -LocalRoot $sourcePath -CommonLockFile $commonLockFile -SelectedLockFile $selectedLockFile -CudaTrackTag $cudaTrackTag
                Add-GuiLog "    [OK] Approved wheelhouse refreshed from lock files: $($preflight.CommonWheelhouse) | $($preflight.TrackWheelhouse)" -ForegroundColor Green
                Set-GuiSubProgress -Percent 70

                Set-GuiSubProgress -Percent 70
                $pipVersionOutput = & $resolvedCondaExe run -n $envName python -m pip --version 2>&1
                $pipVersionText = ($pipVersionOutput | Out-String).Trim()
                if (-not [string]::IsNullOrWhiteSpace($pipVersionText)) {
                    $pipVersionText = $pipVersionText -replace 'pip\s+', ''
                }

                Add-GuiLog "    [SKIP] Offline mode: pip upgrade is disabled; current version is $pipVersionText" -ForegroundColor Cyan
                Set-GuiSubProgress -Percent 80

                Set-GuiSubProgress -Percent 80
                Add-GuiLog "    [4/4] Installing packages from approved wheelhouse ($cudaTrackTag)..." -ForegroundColor Cyan

                if (-not (Test-Path $lockFilePath)) {
                    throw "Lock file not found: $lockFilePath"
                }
                if (-not (Test-Path $wheelhouseCommonPath)) {
                    throw "Common wheelhouse not found: $wheelhouseCommonPath"
                }
                if (-not (Test-Path $wheelhouseTrackPath)) {
                    throw "Track wheelhouse ($cudaTrackTag) not found: $wheelhouseTrackPath"
                }

                Install-OfflineBuildRequirementsFromWheelhouses -EnvironmentName $envName -ApprovedDirectories @($wheelhouseCommonPath, $wheelhouseTrackPath) -LockFilePaths @($commonLockFilePath, $lockFilePath)

                $pipInstallLines = @()
                & $resolvedCondaExe run --live-stream -n $envName python -m pip install --progress-bar on --no-index --no-build-isolation --find-links $wheelhouseCommonPath --find-links $wheelhouseTrackPath -r $lockFilePath 2>&1 | ForEach-Object {
                    $line = $_.ToString()
                    if (-not [string]::IsNullOrWhiteSpace($line)) {
                        $pipInstallLines += $line
                        Write-Host "        $line"
                        Add-GuiLog "        $line" -ForegroundColor DarkGray
                    }
                }
                if ($LASTEXITCODE -ne 0) {
                    $pipFailureSummary = @($pipInstallLines | Select-Object -Last 8) -join ' | '
                    if ([string]::IsNullOrWhiteSpace($pipFailureSummary)) {
                        throw "Failed to install packages in environment $envName"
                    }

                    throw "Failed to install packages in environment $envName :: $pipFailureSummary"
                }
                Add-GuiLog "    [OK] Packages installed from wheelhouse" -ForegroundColor Green
                Set-GuiSubProgress -Percent 95

                Set-Content -Path $envVersionFile -Value $desiredEnvStamp -Encoding ASCII -Force
                Add-GuiLog "    [OK] Environment configured: $desiredEnvStamp" -ForegroundColor Green
            }

            $trtWheelRoot = if (-not [string]::IsNullOrWhiteSpace($foundTrtPath)) { $foundTrtPath } else { $trtDest }
            Install-TensorRTWheelToEnvironment -CondaRoot $activeCondaPath -EnvName $envName -TrtRoot $trtWheelRoot

            Set-GuiStepProgress -Step 5 -Title "Python env"
        }
    }
    catch {
        if ($_.Exception.Message -match 'Download-only request accepted') {
            Add-GuiLog "[PAUSE] Download-only selection accepted. setup is paused until Install is chosen explicitly." -ForegroundColor Yellow
            throw
        }
        Show-StageError -Stage "Step 4 - Python env" -ErrorRecord $_
        return
    }

    try {
        $localEvalToolsZip = Join-Path $sourcePath "pkgs\$evalToolsZipFile"
        $remoteEvalToolsZip = Join-Path $remoteSourcePath "pkgs\$evalToolsZipFile"

        do {
            $stepDecision = Request-StepInstallDecision -StepTitle "Step 6 - Eval Tools" -DetailLines @(
                "Category: Tooling",
                "Subject: Eval Tools",
                "Source: $evalToolsZipFile",
                "Target: $evalToolsDest",
                "Action: Deploy package and write version tag",
                "Version Tag: $EvaltoolsVer"
            )

            if ($stepDecision -eq "Abort") {
                Add-GuiLog "Canceled by user at Step 6 (Eval Tools)." -ForegroundColor Red
                return
            }

            Set-GuiStepProgress -Step 6 -Title "Eval Tools" -Running
            if ($stepDecision -eq "Skip") {
                Add-GuiLog "[5/5] Eval Tools step skipped by user." -ForegroundColor Yellow
                break
            }

            $needEvalToolsSync = -not (Test-Path -LiteralPath $localEvalToolsZip)
            if ($needEvalToolsSync) {
                $syncResult = Sync-StepRequiredFiles -LocalRoot $sourcePath -RemoteRoot $remoteSourcePath -RequiredFiles @("pkgs\$evalToolsZipFile") -StepTitle "Step 6 - Eval Tools" -Purpose "Download the Eval Tools archive needed for this step before installation" -RequestConfirmation:$true
                if (-not $syncResult) {
                    Add-GuiLog "[5/5] Eval Tools package could not be synced, so the step decision is being re-asked." -ForegroundColor Yellow
                    continue
                }

                if (-not (Test-Path -LiteralPath $localEvalToolsZip)) {
                    throw "Eval Tools package not found after sync: $localEvalToolsZip"
                }
            }

            Add-GuiLog "[5/5] Deploying Eval Tools..." -ForegroundColor Yellow
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
                        Add-GuiLog "    [INFO] OK selected, but Eval Tools reinstall is skipped because version tag matches." -ForegroundColor Cyan
                    }
                }
            }

            if ($needEvalToolsUpdate) {
                if (-not (Test-Path -LiteralPath $localEvalToolsZip)) {
                    throw "Eval Tools package not found: $localEvalToolsZip"
                }

                if (Test-Path $evalToolsDest) {
                    Set-GuiSubProgress -Percent 20
                    Remove-Item -Path $evalToolsDest -Recurse -Force
                }

                New-Item -ItemType Directory -Force -Path $evalToolsDest | Out-Null
                Set-GuiSubProgress -Percent 0
                Expand-PackageArchiveWithGuiProgress -ArchivePath $localEvalToolsZip -DestinationPath "$evalToolsDest" -StartPercent 0 -EndPercent 95
                Set-Content -Path $evalToolsVersionFile -Value $desiredEvalToolsStamp -Encoding ASCII -Force
                Add-GuiLog "    [OK] Eval Tools deployed: $evalToolsDest ($desiredEvalToolsStamp)" -ForegroundColor Green
            }

            $shortcutScriptPath = Join-Path $evalToolsDest "create_shortcut.py"
            if (Test-Path -LiteralPath $shortcutScriptPath) {
                Add-GuiLog "    [INFO] Creating Eval Tools desktop shortcut..." -ForegroundColor Cyan
                $shortcutOutput = & $resolvedCondaExe run --live-stream -n $envName python $shortcutScriptPath 2>&1
                foreach ($line in @($shortcutOutput)) {
                    $text = if ($null -eq $line) { "" } else { $line.ToString().Trim() }
                    if (-not [string]::IsNullOrWhiteSpace($text)) {
                        Add-GuiLog "        $text" -ForegroundColor DarkGray
                    }
                }

                if ($LASTEXITCODE -ne 0) {
                    Add-GuiLog "    [WARN] Eval Tools shortcut creation failed. You can run create_shortcut.py manually later." -ForegroundColor Yellow
                }
                else {
                    Add-GuiLog "    [OK] Eval Tools shortcut created." -ForegroundColor Green
                }
            }
            else {
                Add-GuiLog "    [WARN] Shortcut script not found: $shortcutScriptPath" -ForegroundColor Yellow
            }

            break
        } while ($true)
        Set-GuiStepProgress -Step 6 -Title "Eval Tools"
    }
    catch {
        if ($_.Exception.Message -match 'Download-only request accepted') {
            Add-GuiLog "[PAUSE] Download-only selection accepted. setup is paused until Install is chosen explicitly." -ForegroundColor Yellow
            throw
        }
        Show-StageError -Stage "Step 6 - Eval Tools" -ErrorRecord $_
        return
    }

    Add-GuiLog ""
    Add-GuiLog "#============================================================#" -ForegroundColor Cyan
    Add-GuiLog "# [DONE] All setup steps completed                           #" -ForegroundColor Cyan
    Add-GuiLog "#============================================================#" -ForegroundColor Cyan
    Add-GuiLog "Open a new terminal to apply USER PATH changes." -ForegroundColor Cyan
    Add-GuiLog "Conda command: conda activate $envName" -ForegroundColor Cyan
    Set-GuiStepProgress -Step 6 -Title "Completed"
    Add-GuiLog "All setup steps completed successfully."
    Wait-GuiLogWindowClose
}
