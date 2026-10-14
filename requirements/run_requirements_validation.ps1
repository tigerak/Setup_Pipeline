[CmdletBinding()]
param(
    [ValidateSet("cu11", "cu12", "all")]
    [string[]]$Track = @("cu11"),

    [string]$EnvPrefix = "req",

    [string]$PythonVersion = "3.10",

    [switch]$SyncLock,

    [Alias("DownloadWheels")]
    [switch]$BuildTempWheelCache,

    [switch]$BuildApprovedWheelhouse,

    [switch]$VerifyOfflineInstall,

    [string]$WheelOutputRoot = "",

    [string]$LogRoot = "",

    [Alias("ForceRecreateEnv")]
    [switch]$RemoveValidationEnv,

    [switch]$ClearTempWheelCache,

    [switch]$ClearApprovedWheelhouse,

    [switch]$RemoveOfflineEnv,

    [switch]$SkipCreateEnv,

    [switch]$SkipInstall,

    [switch]$SkipValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($SyncLock -and -not $BuildApprovedWheelhouse) {
    $BuildApprovedWheelhouse = $true
}

$script:PlainLogPath = $null
$script:SidecarLogPath = $null
$script:ValidationSettings = $null

function New-LogFilePath {
    param(
        [Parameter(Mandatory = $true)][string]$BaseDirectory,
        [Parameter(Mandatory = $true)][string[]]$TrackNames
    )

    if (-not (Test-Path -LiteralPath $BaseDirectory)) {
        New-Item -ItemType Directory -Path $BaseDirectory | Out-Null
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $trackToken = ($TrackNames | Select-Object -Unique) -join "-"
    if ([string]::IsNullOrWhiteSpace($trackToken)) {
        $trackToken = "unknown"
    }

    Join-Path $BaseDirectory ("requirements_validation_{0}_{1}.log" -f $trackToken, $timestamp)
}

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Gray
}

function Write-WarnLog {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-SectionSummary {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string[]]$Lines
    )

    Write-Host ""
    Write-Host ("==> {0}" -f $Title) -ForegroundColor Cyan
    foreach ($line in $Lines) {
        Write-Info $line
    }
}

function Normalize-LogText {
    param([AllowEmptyString()][string]$Text)

    if ($null -eq $Text) {
        return ""
    }

    return ($Text -replace "`0", "")
}

function Add-LogContentWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message
    )

    $normalizedMessage = Normalize-LogText -Text $Message
    $maxAttempts = 5

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            $fileStream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            try {
                $writer = New-Object System.IO.StreamWriter($fileStream, [System.Text.UTF8Encoding]::new($false))
                try {
                    $writer.WriteLine($normalizedMessage)
                    $writer.Flush()
                }
                finally {
                    $writer.Dispose()
                }
            }
            finally {
                $fileStream.Dispose()
            }

            return
        }
        catch [System.IO.IOException] {
            if ($attempt -eq $maxAttempts) {
                Write-Host ("[WARN] Runtime log write skipped after file-lock retries: {0}" -f $Path) -ForegroundColor Yellow
                return
            }

            Start-Sleep -Milliseconds (50 * $attempt)
        }
    }
}

function Write-LogLine {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message)

    if (-not [string]::IsNullOrWhiteSpace($script:PlainLogPath)) {
        Add-LogContentWithRetry -Path $script:PlainLogPath -Message $Message
    }
}

function Join-CommandArguments {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $escaped = foreach ($argument in $Arguments) {
        if ($argument -match '[\s"]') {
            '"{0}"' -f ($argument -replace '"', '\"')
        }
        else {
            $argument
        }
    }

    $escaped -join ' '
}

function Write-CommandOutputText {
    param([AllowEmptyString()][string]$Text)

    if ($null -eq $Text) {
        return
    }

    $normalizedText = Normalize-LogText -Text $Text
    $lines = $normalizedText -split "`r?`n", 0, [System.StringSplitOptions]::None

    foreach ($line in $lines) {
        Write-LogLine -Message $line
        Write-Host $line
    }
}

function Invoke-LoggedExternalCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$ErrorMessage,
        [switch]$LiveStream
    )

    if ($LiveStream) {
        $previousErrorActionPreference = $ErrorActionPreference

        try {
            $ErrorActionPreference = "Continue"
            & $FilePath @Arguments
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        if ($LASTEXITCODE -ne 0) {
            throw ("{0} (exit code {1})" -f $ErrorMessage, $LASTEXITCODE)
        }

        return
    }

    $command = Get-Command $FilePath -ErrorAction Stop
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $command.Source
    $startInfo.Arguments = Join-CommandArguments -Arguments $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $exitCode = $process.ExitCode
    }
    finally {
        $process.Dispose()
    }

    Write-CommandOutputText -Text $stdout
    Write-CommandOutputText -Text $stderr

    if ($exitCode -ne 0) {
        throw ("{0} (exit code {1})" -f $ErrorMessage, $exitCode)
    }
}

function Assert-CommandExists {
    param([Parameter(Mandatory = $true)][string]$Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "Required command not found: $Name"
    }
}

function Get-SelectedTracks {
    param([string[]]$RequestedTracks)

    if ($RequestedTracks -contains "all") {
        return @("cu11", "cu12")
    }

    $RequestedTracks | Select-Object -Unique
}

function Get-CommonConfig {
    param([Parameter(Mandatory = $true)][string]$RequirementsRoot)

    $manifestPath = Join-Path $RequirementsRoot "common.in"
    $lockPath = Join-Path $RequirementsRoot "common.lock.txt"

    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Manifest not found: $manifestPath"
    }

    [pscustomobject]@{
        Name = "common"
        ManifestPath = $manifestPath
        LockPath = $lockPath
    }
}

function Get-TrackConfig {
    param(
        [Parameter(Mandatory = $true)][string]$TrackName,
        [Parameter(Mandatory = $true)][string]$RequirementsRoot,
        [Parameter(Mandatory = $true)][string]$EnvironmentPrefix
    )

    $manifestPath = Join-Path $RequirementsRoot ("{0}.in" -f $TrackName)
    $lockPath = Join-Path $RequirementsRoot ("{0}.lock.txt" -f $TrackName)
    $environmentName = "{0}-{1}" -f $EnvironmentPrefix, $TrackName

    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Manifest not found: $manifestPath"
    }

    [pscustomobject]@{
        Name = $TrackName
        ManifestPath = $manifestPath
        LockPath = $lockPath
        EnvironmentName = $environmentName
    }
}

function Get-WheelhousePaths {
    param(
        [Parameter(Mandatory = $true)][string]$WheelRoot,
        [Parameter(Mandatory = $true)][string]$TrackName
    )

    [pscustomobject]@{
        TempDirectory = Join-Path (Join-Path $WheelRoot "temp") $TrackName
        ApprovedDirectory = Join-Path (Join-Path $WheelRoot "approved") $TrackName
    }
}

function Get-CommonWheelhousePaths {
    param(
        [Parameter(Mandatory = $true)][string]$WheelRoot
    )

    [pscustomobject]@{
        TempDirectory = Join-Path (Join-Path $WheelRoot "temp") "common"
        ApprovedDirectory = Join-Path (Join-Path $WheelRoot "approved") "common"
    }
}

function New-FilteredRequirementsFile {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [switch]$ExcludeCommonReference,
        [switch]$ExcludeOfflineDirectives
    )

    if (-not $ExcludeCommonReference -and -not $ExcludeOfflineDirectives) {
        return $SourcePath
    }

    $filteredPath = Join-Path $env:TEMP ("requirements_filtered_{0}.txt" -f [guid]::NewGuid().ToString("N"))
    $content = Get-Content -LiteralPath $SourcePath
    $filteredContent = foreach ($line in $content) {
        $trimmedLine = $line.Trim()

        if ($ExcludeCommonReference -and $trimmedLine -match '^-r\s+common\.(?:in|lock\.txt)\s*$') {
            continue
        }

        if ($ExcludeOfflineDirectives -and $trimmedLine -match '^--no-index\s*$') {
            continue
        }

        if ($ExcludeOfflineDirectives -and $trimmedLine -match '^--find-links(?:\s+|=).+$') {
            continue
        }

        $line
    }

    Set-Content -LiteralPath $filteredPath -Value $filteredContent -Encoding UTF8
    return $filteredPath
}

function Test-CondaEnvironmentExists {
    param([Parameter(Mandatory = $true)][string]$EnvironmentName)

    try {
        $envListOutput = & conda env list 2>&1
        if ($LASTEXITCODE -ne 0 -or $null -eq $envListOutput) {
            return $false
        }

        foreach ($line in ($envListOutput -split "`r?`n")) {
            $trimmed = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
            if ($trimmed.StartsWith('#')) { continue }

            if ($trimmed -match '^(?<name>\S+)\s+(?<path>.+)$') {
                if ($matches['name'] -ieq $EnvironmentName) {
                    return $true
                }

                if ($matches['path'] -ieq (Join-Path (Split-Path -Parent $matches['path']) $EnvironmentName)) {
                    return $true
                }
            }
        }

        return $false
    }
    catch {
        return $false
    }
}

function Invoke-CondaCommand {
    param(
        [Parameter(Mandatory = $true, ValueFromRemainingArguments = $true)]
        [string[]]$CommandArguments
    )

    $displayCommand = "conda {0}" -f ($CommandArguments -join " ")
    Write-Info $displayCommand
    Write-LogLine -Message ("[INFO] {0}" -f $displayCommand)

    $condaExe = Get-Command conda.exe -ErrorAction Stop
    # Create temp files for output to avoid PowerShell treating stderr as errors
    $tempOutputFile = [System.IO.Path]::GetTempFileName()
    $tempErrorFile = [System.IO.Path]::GetTempFileName()
    
    try {
        # Run conda and capture output separately
        $process = Start-Process -FilePath $condaExe.Source `
                                -ArgumentList $CommandArguments `
                                -RedirectStandardOutput $tempOutputFile `
                                -RedirectStandardError $tempErrorFile `
                                -NoNewWindow `
                                -PassThru `
                                -Wait
        
        # Read and display stdout
        $output = @()
        if (Test-Path $tempOutputFile) {
            $output += Get-Content -Path $tempOutputFile -ErrorAction SilentlyContinue
        }
        if ($output) {
            $output | ForEach-Object {
                Write-CommandOutputText -Text $_
            }
        }
        
        # For conda output to stderr (warnings), just log them without causing failure
        $errorOutput = @()
        if (Test-Path $tempErrorFile) {
            $errorOutput = Get-Content -Path $tempErrorFile -ErrorAction SilentlyContinue
            if ($errorOutput) {
                $errorOutput | ForEach-Object {
                    if ($_ -and $_.ToString().Trim()) {
                        Write-LogLine -Message ("[CONDA] {0}" -f $_)
                    }
                }
            }
        }
        
        # Check the actual exit code
        $exitCode = $process.ExitCode
        $combinedOutputText = ((@($output) + @($errorOutput)) | Out-String)
        
        # Conda sometimes exits with 1 even on success (Windows file locking warnings during cleanup)
        # For conda create: if exit is 1, assume success if output shows completion or the env now exists.
        if ($exitCode -ne 0) {
            if ($CommandArguments -contains "create" -and $exitCode -eq 1) {
                $environmentName = $null
                $nameIndex = [Array]::IndexOf($CommandArguments, "-n")
                if ($nameIndex -ge 0 -and ($nameIndex + 1) -lt $CommandArguments.Count) {
                    $environmentName = $CommandArguments[$nameIndex + 1]
                }

                if (
                    $combinedOutputText -like "*To activate this environment*" -or
                    $combinedOutputText -like "*conda activate*" -or
                    (-not [string]::IsNullOrWhiteSpace($environmentName) -and (Test-CondaEnvironmentExists -EnvironmentName $environmentName))
                ) {
                    Write-LogLine -Message ("[INFO] Environment created successfully (ignoring exit code 1 due to Windows cleanup warnings)"
                    )
                    return
                }
            }
            
            throw ("Conda command failed with exit code {0}: {1}" -f $exitCode, $displayCommand)
        }
    } finally {
        Remove-Item -Path $tempOutputFile, $tempErrorFile -ErrorAction SilentlyContinue
    }
}

function Test-CondaRunSupportsLiveStream {
    $helpArguments = @("run", "--help")
    $helpOutput = & conda @helpArguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    return (($helpOutput | Out-String) -match '--live-stream')
}

function Invoke-CondaPython {
    param(
        [Parameter(Mandatory = $true)][string]$EnvironmentName,
        [Parameter(Mandatory = $true)][string[]]$PythonArguments,
        [switch]$LiveStream
    )

    $allArguments = @("run")
    if ($LiveStream -and (Test-CondaRunSupportsLiveStream)) {
        $allArguments += "--live-stream"
    }
    elseif ($LiveStream) {
        Write-WarnLog ("Current conda version does not support '--live-stream'; continuing without it for environment '{0}'." -f $EnvironmentName)
    }

    $allArguments += @("-n", $EnvironmentName, "python") + $PythonArguments
    $displayCommand = "conda {0}" -f ($allArguments -join " ")
    Write-Info $displayCommand
    Write-LogLine -Message ("[INFO] {0}" -f $displayCommand)

    if ($LiveStream) {
        & conda @allArguments
        if ($LASTEXITCODE -ne 0) {
            throw ("Python command failed in conda env '{0}'" -f $EnvironmentName)
        }
        return
    }

    $output = & conda @allArguments 2>&1
    if ($null -ne $output) {
        $output | ForEach-Object {
            Write-CommandOutputText -Text $_.ToString()
        }
    }

    if ($LASTEXITCODE -ne 0) {
        throw ("Python command failed in conda env '{0}'" -f $EnvironmentName)
    }
}

function Invoke-CondaPythonCapture {
    param(
        [Parameter(Mandatory = $true)][string]$EnvironmentName,
        [Parameter(Mandatory = $true)][string[]]$PythonArguments
    )

    $allArguments = @("run", "-n", $EnvironmentName, "python") + $PythonArguments
    $displayCommand = "conda {0}" -f ($allArguments -join " ")
    Write-Info $displayCommand
    Write-LogLine -Message ("[INFO] {0}" -f $displayCommand)

    $condaCommand = Get-Command "conda" -ErrorAction Stop
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $condaCommand.Source
    $startInfo.Arguments = Join-CommandArguments -Arguments $allArguments
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $exitCode = $process.ExitCode
    }
    finally {
        $process.Dispose()
    }

    Write-CommandOutputText -Text $stderr

    if ($exitCode -ne 0) {
        throw ("Python command failed in conda env '{0}' (exit code {1})" -f $EnvironmentName, $exitCode)
    }

    return (Normalize-LogText -Text $stdout)
}

function New-CondaEnvironment {
    param(
        [Parameter(Mandatory = $true)][string]$EnvironmentName,
        [Parameter(Mandatory = $true)][string]$RequestedPythonVersion
    )

    Invoke-CondaCommand "create" "-n" $EnvironmentName ("python={0}" -f $RequestedPythonVersion) "-y"
}

function Remove-CondaEnvironment {
    param([Parameter(Mandatory = $true)][string]$EnvironmentName)

    try {
        Invoke-CondaCommand "env" "remove" "-n" $EnvironmentName "-y"
    }
    catch {
        if (-not (Test-CondaEnvironmentExists -EnvironmentName $EnvironmentName)) {
            Write-WarnLog ("Environment removal reported an error, but the environment is already absent: {0}" -f $EnvironmentName)
            return
        }

        throw
    }
}

function Install-Manifest {
    param(
        [Parameter(Mandatory = $true)][string]$EnvironmentName,
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )

    Invoke-CondaPython -EnvironmentName $EnvironmentName -PythonArguments @("-m", "pip", "install", "--progress-bar", "on", "--upgrade", "pip") -LiveStream
    Invoke-CondaPython -EnvironmentName $EnvironmentName -PythonArguments @("-m", "pip", "install", "--progress-bar", "on", "--no-build-isolation", "-r", $ManifestPath) -LiveStream
}

function Normalize-PackageName {
    param([Parameter(Mandatory = $true)][string]$Name)

    return (($Name.Trim().ToLowerInvariant()) -replace '[-_.]+', '-')
}

function Get-RequirementPackageNames {
    param([Parameter(Mandatory = $true)][string]$RequirementsPath)

    $packageNames = @()
    foreach ($line in (Get-Content -LiteralPath $RequirementsPath)) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        if ($trimmed.StartsWith('#')) { continue }
        if ($trimmed.StartsWith('-')) { continue }

        if ($trimmed -match '^([A-Za-z0-9._-]+)') {
            $packageNames += (Normalize-PackageName -Name $matches[1])
        }
    }

    return @($packageNames | Select-Object -Unique)
}

function Get-PinnedRequirementsFromFile {
    param(
        [Parameter(Mandatory = $true)][string]$RequirementsPath,
        [string[]]$VisitedPaths = @()
    )

    $resolvedPath = (Resolve-Path -LiteralPath $RequirementsPath).Path
    if ($resolvedPath -in $VisitedPaths) {
        return @()
    }

    $nextVisitedPaths = @($VisitedPaths + $resolvedPath)
    $requirementsDirectory = Split-Path -Parent $resolvedPath
    $records = @()

    foreach ($line in (Get-Content -LiteralPath $resolvedPath)) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        if ($trimmed.StartsWith('#')) { continue }

        if ($trimmed -match '^-r\s+(?<include>.+)$') {
            $includePath = $matches['include'].Trim()
            if (-not [System.IO.Path]::IsPathRooted($includePath)) {
                $includePath = Join-Path $requirementsDirectory $includePath
            }

            $records += Get-PinnedRequirementsFromFile -RequirementsPath $includePath -VisitedPaths $nextVisitedPaths
            continue
        }

        if ($trimmed.StartsWith('-')) { continue }

        if ($trimmed -match '^(?<name>[A-Za-z0-9._-]+)==(?<version>.+)$') {
            $records += [pscustomobject]@{
                Name = Normalize-PackageName -Name $matches['name']
                Version = $matches['version'].Trim()
            }
        }
    }

    return @($records)
}

function Get-ValidationSettingsPath {
    return (Join-Path $PSScriptRoot 'run_requirements_validation.settings.psd1')
}

function Normalize-RequirementSpec {
    param([AllowEmptyString()][string]$Value)

    $trimmed = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return $trimmed
    }

    if ($trimmed -match '^(?<name>[A-Za-z0-9][A-Za-z0-9._-]*)(?<extras>\[[^\]]+\])?(?<rest>.*)$') {
        $normalizedName = Normalize-PackageName -Name $matches['name']
        return ($normalizedName + $matches['extras'] + $matches['rest']).Trim()
    }

    return $trimmed
}

function ConvertTo-NormalizedPackageList {
    param([AllowEmptyCollection()][object[]]$PackageNames)

    return @(
        @($PackageNames) |
            ForEach-Object {
                if ($null -eq $_) {
                    return
                }

                $value = ([string]$_).Trim()
                if ([string]::IsNullOrWhiteSpace($value)) {
                    return
                }

                Normalize-RequirementSpec -Value $value
            } |
            Select-Object -Unique
    )
}

function Get-TrackValidationSettings {
    param([Parameter(Mandatory = $true)][string]$TrackName)

    if ($null -eq $script:ValidationSettings) {
        throw 'Validation settings are not loaded.'
    }

    $tracks = $script:ValidationSettings['Tracks']
    if ($null -eq $tracks) {
        throw 'Validation settings do not define a Tracks section.'
    }

    $sourceBuildRequirementMap = @{}
    $lockExcludePackages = @()

    foreach ($settingsKey in @('default', $TrackName)) {
        if (-not $tracks.ContainsKey($settingsKey)) {
            continue
        }

        $trackSettings = $tracks[$settingsKey]
        if ($null -eq $trackSettings) {
            continue
        }

        if ($trackSettings.ContainsKey('SourceBuildRequirementMap')) {
            foreach ($entry in $trackSettings['SourceBuildRequirementMap'].GetEnumerator()) {
                $normalizedKey = Normalize-PackageName -Name ([string]$entry.Key)
                $sourceBuildRequirementMap[$normalizedKey] = @(ConvertTo-NormalizedPackageList -PackageNames $entry.Value)
            }
        }

        if ($trackSettings.ContainsKey('LockExcludePackages')) {
            $lockExcludePackages += @(ConvertTo-NormalizedPackageList -PackageNames $trackSettings['LockExcludePackages'])
        }
    }

    if (-not $sourceBuildRequirementMap.ContainsKey('default')) {
        throw 'Validation settings must define Tracks.default.SourceBuildRequirementMap.default.'
    }

    [pscustomobject]@{
        SourceBuildRequirementMap = $sourceBuildRequirementMap
        LockExcludePackages = @($lockExcludePackages | Select-Object -Unique)
    }
}

$settingsPath = Get-ValidationSettingsPath
if (-not (Test-Path -LiteralPath $settingsPath)) {
    throw "Validation settings file not found: $settingsPath"
}

$script:ValidationSettings = Import-PowerShellDataFile -LiteralPath $settingsPath

if ($null -eq $script:ValidationSettings['Tracks'] -or -not $script:ValidationSettings['Tracks'].ContainsKey('default')) {
    throw "Validation settings file is missing Tracks.default: $settingsPath"
}

function Get-LockHeaderLines {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [string[]]$FindLinkDirectories = @()
    )

    $manifestName = Split-Path -Leaf $ManifestPath
    if ($manifestName -ieq 'common.in') {
        return @(
            '--find-links wheelhouse/approved/common',
            '--no-index'
        )
    }

    $trackName = [System.IO.Path]::GetFileNameWithoutExtension($manifestName)
    return @(
        '-r common.lock.txt',
        ('--find-links wheelhouse/approved/{0}' -f $trackName),
        '--no-index'
    )
}

function Get-FrozenRequirementLines {
    param([Parameter(Mandatory = $true)][string]$EnvironmentName)

    $freezeOutput = Invoke-CondaPythonCapture -EnvironmentName $EnvironmentName -PythonArguments @("-m", "pip", "freeze")
    $lines = ($freezeOutput -split "`r`n|`n|`r")
    return @($lines | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-ArtifactBaseName {
    param([Parameter(Mandatory = $true)][string]$FileName)

    foreach ($suffix in @('.tar.gz', '.tar.bz2', '.zip', '.whl')) {
        if ($FileName.EndsWith($suffix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $FileName.Substring(0, $FileName.Length - $suffix.Length)
        }
    }

    throw "Unsupported artifact format: $FileName"
}

function Get-ApprovedArtifactRequirementRecord {
    param([Parameter(Mandatory = $true)][System.IO.FileInfo]$Artifact)

    $artifactName = $Artifact.Name
    if ($artifactName.EndsWith('.whl', [System.StringComparison]::OrdinalIgnoreCase)) {
        $nameParts = (Get-ArtifactBaseName -FileName $artifactName) -split '-'
        if ($nameParts.Count -lt 5) {
            throw "Unexpected wheel file name: $artifactName"
        }

        $distributionParts = $nameParts[0..($nameParts.Count - 4)]
        if ($distributionParts.Count -lt 2) {
            throw "Unexpected wheel file name: $artifactName"
        }

        $hasBuildTag = $distributionParts.Count -ge 3 -and $distributionParts[-1] -match '^\d'
        if ($hasBuildTag) {
            $version = $distributionParts[-2]
            $nameSegments = $distributionParts[0..($distributionParts.Count - 3)]
        }
        else {
            $version = $distributionParts[-1]
            $nameSegments = $distributionParts[0..($distributionParts.Count - 2)]
        }

        if ($nameSegments.Count -eq 0) {
            throw "Unexpected wheel file name: $artifactName"
        }

        return [pscustomobject]@{
            Name = Normalize-PackageName -Name ($nameSegments -join '-')
            Version = $version
        }
    }

    $baseName = Get-ArtifactBaseName -FileName $artifactName
    if ($baseName -notmatch '^(?<name>.+)-(?<version>[^-]+)$') {
        throw "Unexpected source artifact file name: $artifactName"
    }

    return [pscustomobject]@{
        Name = Normalize-PackageName -Name $matches['name']
        Version = $matches['version']
    }
}

function Get-ApprovedRequirementLines {
    param(
        [Parameter(Mandatory = $true)][string]$ApprovedDirectory,
        [Parameter(Mandatory = $true)][string]$TrackName,
        [string[]]$ExcludedPackageNames = @()
    )

    if (-not (Test-Path -LiteralPath $ApprovedDirectory)) {
        throw "Approved directory not found: $ApprovedDirectory"
    }

    $trackSettings = Get-TrackValidationSettings -TrackName $TrackName

    $recordsByName = @{}
    foreach ($artifact in (Get-ChildItem -LiteralPath $ApprovedDirectory -File | Sort-Object Name)) {
        $record = Get-ApprovedArtifactRequirementRecord -Artifact $artifact
        if ($record.Name -in $trackSettings.LockExcludePackages) {
            continue
        }
        if ($record.Name -in $ExcludedPackageNames) {
            continue
        }
        $recordsByName[$record.Name] = $record.Version
    }

    return @(
        $recordsByName.Keys |
            Sort-Object |
            ForEach-Object { '{0}=={1}' -f $_, $recordsByName[$_] }
    )
}

function Sync-LockFileFromApprovedArtifacts {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$LockPath,
        [Parameter(Mandatory = $true)][string]$ApprovedDirectory,
        [Parameter(Mandatory = $true)][string]$TrackName,
        [string]$EnvironmentName = $null,
        [string[]]$ExcludedPackageNames = @(),
        [string[]]$CommentedRequirementSpecs = @()
    )

    $headerLines = Get-LockHeaderLines -ManifestPath $ManifestPath
    $manifestName = Split-Path -Leaf $ManifestPath
    $commentLines = @()
    
    # For common lock, pin the full approved artifact set so offline installs do not
    # need to resolve transitive dependencies from an index at install time.
    if ($manifestName -ieq 'common.in') {
        $trackSettings = Get-TrackValidationSettings -TrackName $TrackName
        $lockExcludePackages = @($trackSettings.LockExcludePackages)

        $artifactRequirementLines = @(Get-ApprovedRequirementLines -ApprovedDirectory $ApprovedDirectory -TrackName $TrackName)

        $manifestPinnedRequirements = @(Get-PinnedRequirementsFromFile -RequirementsPath $ManifestPath | ForEach-Object { '{0}=={1}' -f $_.Name, $_.Version })
        $manifestPinnedLookup = @{}
        foreach ($requirementLine in $manifestPinnedRequirements) {
            $manifestPinnedLookup[$requirementLine] = $true
        }

        $helperOnlySpecs = @(
            ConvertTo-NormalizedPackageList -PackageNames $CommentedRequirementSpecs |
                Where-Object { -not $manifestPinnedLookup.ContainsKey($_) }
        )
        $helperOnlyLookup = @{}
        foreach ($requirementLine in $helperOnlySpecs) {
            $helperOnlyLookup[$requirementLine] = $true
        }

        $requirementLines = @(
            $artifactRequirementLines |
                Where-Object {
                    if ($_.StartsWith('#')) { return $false }

                    if ($_.Trim().StartsWith('-')) { return $false }

                    $record = ConvertTo-RequirementRecord -RequirementSpec $_
                    $record.Name -notin $lockExcludePackages
                } |
                Where-Object { -not $helperOnlyLookup.ContainsKey($_) } |
                Select-Object -Unique |
                Sort-Object
        )

        $installedRequirementLookup = @{}
        foreach ($requirementLine in $requirementLines) {
            $record = ConvertTo-RequirementRecord -RequirementSpec $requirementLine
            $installedRequirementLookup[$record.Spec] = $true
        }

        $commentLines = @(
            $helperOnlySpecs |
                Where-Object { -not $installedRequirementLookup.ContainsKey($_) } |
                Sort-Object |
                ForEach-Object { '# helper-artifact-only: {0}' -f $_ }
        )
    }
    else {
        # For track-specific locks, use approved directory with exclusions
        $artifactLines = Get-ApprovedRequirementLines -ApprovedDirectory $ApprovedDirectory -TrackName $TrackName -ExcludedPackageNames $ExcludedPackageNames
        $artifactLookup = @{}
        foreach ($line in $artifactLines) {
            if ($line -match '^([A-Za-z0-9._-]+)==') {
                $pkgName = Normalize-PackageName -Name $matches[1]
                $artifactLookup[$pkgName] = $line
            }
        }
        
        # Get manifest requirements to ensure completeness
        $manifestRequirements = Get-RequirementPackageNames -RequirementsPath $ManifestPath
        foreach ($manifestPkg in $manifestRequirements) {
            $normalizedName = Normalize-PackageName -Name $manifestPkg
            if ($normalizedName -notin $artifactLookup.Keys) {
                foreach ($artifact in (Get-ChildItem -LiteralPath $ApprovedDirectory -File)) {
                    $record = Get-ApprovedArtifactRequirementRecord -Artifact $artifact
                    if ($record.Name -eq $normalizedName) {
                        $artifactLookup[$normalizedName] = ('{0}=={1}' -f $record.Name, $record.Version)
                        break
                    }
                }
            }
        }
        
        $requirementLines = @($artifactLookup.Values | Sort-Object)
    }

    $updated = @()
    $updated += $headerLines
    $updated += $requirementLines
    $updated += $commentLines

    Set-Content -LiteralPath $LockPath -Value $updated -Encoding UTF8
    Write-Ok ("Lock file updated from approved artifacts: {0}" -f $LockPath)
}

function Invoke-ValidationSnippet {
    param(
        [Parameter(Mandatory = $true)][string]$EnvironmentName,
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Write-Step $Description

    $tempScriptPath = Join-Path $env:TEMP ("requirements_validation_{0}.py" -f [guid]::NewGuid().ToString("N"))

    try {
        Set-Content -LiteralPath $tempScriptPath -Value $Code -Encoding UTF8
        Invoke-CondaPython -EnvironmentName $EnvironmentName -PythonArguments @($tempScriptPath)
    }
    finally {
        if (Test-Path -LiteralPath $tempScriptPath) {
            Remove-Item -LiteralPath $tempScriptPath -Force
        }
    }
}

function Test-ApiTrack {
    param([Parameter(Mandatory = $true)][string]$EnvironmentName)

    Invoke-ValidationSnippet -EnvironmentName $EnvironmentName -Description "API import validation" -Code @"
import fastapi, uvicorn, pydantic, requests
print(f'fastapi={fastapi.__version__}')
print(f'uvicorn={uvicorn.__version__}')
print(f'pydantic={pydantic.__version__}')
print(f'requests={requests.__version__}')
"@

    Invoke-ValidationSnippet -EnvironmentName $EnvironmentName -Description "FastAPI app bootstrap validation" -Code @"
from fastapi import FastAPI
app = FastAPI()
print('fastapi_app_bootstrap=ok')
"@
}

function Test-GpuTrack {
    param(
        [Parameter(Mandatory = $true)][string]$EnvironmentName,
        [Parameter(Mandatory = $true)][string]$TrackName
    )

    Invoke-ValidationSnippet -EnvironmentName $EnvironmentName -Description ("PyTorch CUDA validation ({0})" -f $TrackName) -Code @"
import torch, torchvision
print(f'torch={torch.__version__}')
print(f'torchvision={torchvision.__version__}')
print(f'cuda_available={torch.cuda.is_available()}')
print(f'cuda_version={torch.version.cuda}')
if not torch.cuda.is_available():
    raise SystemExit('CUDA validation failed: torch.cuda.is_available() returned False')
print('cuda_validation=passed')
"@

    Invoke-ValidationSnippet -EnvironmentName $EnvironmentName -Description ("ONNX stack import validation ({0})" -f $TrackName) -Code @"
from importlib.metadata import version
import onnx, onnxsim, onnx2torch, pycuda, onnxruntime as ort
print(f'onnx={onnx.__version__}')
print(f'onnxsim={onnxsim.__version__}')
print(f"onnx2torch={version('onnx2torch')}")
print(f'onnxruntime={ort.__version__}')
"@

    Invoke-ValidationSnippet -EnvironmentName $EnvironmentName -Description ("ONNX Runtime provider validation ({0})" -f $TrackName) -Code @"
import onnxruntime as ort
providers = ort.get_available_providers()
print('providers=' + ', '.join(providers))
"@
}

function Sync-LockFile {
    param(
        [Parameter(Mandatory = $true)][string]$EnvironmentName,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$LockPath,
        [string[]]$FindLinkDirectories = @(),
        [string[]]$FilterPackageNames = @()
    )

    $headerLines = Get-LockHeaderLines -ManifestPath $ManifestPath -FindLinkDirectories $FindLinkDirectories

    $updated = @()
    $updated += $headerLines

    foreach ($line in (Get-FrozenRequirementLines -EnvironmentName $EnvironmentName)) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            # FilterPackageNames이 지정되면 해당 패키지만 포함
            if ($FilterPackageNames.Count -gt 0) {
                if ($line -match '^([A-Za-z0-9._-]+)') {
                    $packageName = Normalize-PackageName -Name $matches[1]
                    if ($packageName -notin $FilterPackageNames) {
                        continue
                    }
                }
            }
            
            $updated += $line
        }
    }

    Set-Content -LiteralPath $LockPath -Value $updated -Encoding UTF8
    Write-Ok ("Lock file updated: {0}" -f $LockPath)
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Reset-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }

    New-Item -ItemType Directory -Path $Path | Out-Null
}

function Get-SourceArtifactFiles {
    param([Parameter(Mandatory = $true)][string]$Directory)

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

function Assert-OfflineArtifactsAvailable {
    param(
        [Parameter(Mandatory = $true)][string]$TrackLockPath,
        [Parameter(Mandatory = $true)][string[]]$FindLinkDirectories
    )

    $artifactIndex = @{}
    foreach ($directory in $FindLinkDirectories) {
        if (-not (Test-Path -LiteralPath $directory)) {
            throw "Offline package directory not found: $directory"
        }

        foreach ($artifact in (Get-ChildItem -LiteralPath $directory -File)) {
            $record = Get-ApprovedArtifactRequirementRecord -Artifact $artifact
            if (-not $artifactIndex.ContainsKey($record.Name)) {
                $artifactIndex[$record.Name] = @{}
            }

            $artifactIndex[$record.Name][$record.Version] = $artifact.FullName
        }
    }

    $missingRequirements = @()
    foreach ($requirement in (Get-PinnedRequirementsFromFile -RequirementsPath $TrackLockPath)) {
        if (-not $artifactIndex.ContainsKey($requirement.Name) -or -not $artifactIndex[$requirement.Name].ContainsKey($requirement.Version)) {
            $missingRequirements += ('{0}=={1}' -f $requirement.Name, $requirement.Version)
        }
    }

    if ($missingRequirements.Count -gt 0) {
        $missingList = ($missingRequirements | Sort-Object -Unique) -join ', '
        $directoryList = ($FindLinkDirectories | ForEach-Object { '"{0}"' -f $_ }) -join ', '
        throw ("Offline package set is incomplete. Missing artifacts for: {0}. Checked directories: {1}" -f $missingList, $directoryList)
    }
}

function ConvertTo-RequirementRecord {
    param([Parameter(Mandatory = $true)][string]$RequirementSpec)

    $normalizedSpec = Normalize-RequirementSpec -Value $RequirementSpec
    if ($normalizedSpec -notmatch '^(?<name>[A-Za-z0-9._-]+)==(?<version>.+)$') {
        throw "Pinned requirement expected in name==version format: $RequirementSpec"
    }

    return [pscustomobject]@{
        Name = Normalize-PackageName -Name $matches['name']
        Version = $matches['version'].Trim()
        Spec = ('{0}=={1}' -f (Normalize-PackageName -Name $matches['name']), $matches['version'].Trim())
    }
}

function Get-RequiredSharedBuildRequirementSpecsForApprovedDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$ApprovedDirectory,
        [Parameter(Mandatory = $true)][string]$TrackName
    )

    $sourceArtifacts = @(Get-SourceArtifactFiles -Directory $ApprovedDirectory)
    if ($sourceArtifacts.Count -eq 0) {
        return @()
    }

    $sharedPackageNames = @((Get-TrackValidationSettings -TrackName $TrackName).LockExcludePackages)
    $requirementSpecs = @()
    foreach ($artifact in $sourceArtifacts) {
        $requirementSpecs += Get-BuildRequirementSpecsFromSourceArtifact -ArtifactPath $artifact.FullName -TrackName $TrackName
    }

    return @(
        ConvertTo-NormalizedPackageList -PackageNames $requirementSpecs |
            Where-Object {
                $record = ConvertTo-RequirementRecord -RequirementSpec $_
                $record.Name -in $sharedPackageNames
            }
    )
}

function Sync-SharedArtifactsToCommonApproved {
    param(
        [Parameter(Mandatory = $true)][string]$CommonApprovedDirectory,
        [Parameter(Mandatory = $true)][string[]]$SourceDirectories,
        [Parameter(Mandatory = $true)][string[]]$RequirementSpecs
    )

    Ensure-Directory -Path $CommonApprovedDirectory

    foreach ($requirementSpec in (ConvertTo-NormalizedPackageList -PackageNames $RequirementSpecs)) {
        $requirement = ConvertTo-RequirementRecord -RequirementSpec $requirementSpec
        $artifactFound = $null

        foreach ($directory in @($CommonApprovedDirectory) + $SourceDirectories) {
            if (-not (Test-Path -LiteralPath $directory)) {
                continue
            }

            foreach ($artifact in (Get-ChildItem -LiteralPath $directory -File)) {
                $record = Get-ApprovedArtifactRequirementRecord -Artifact $artifact
                if ($record.Name -eq $requirement.Name -and $record.Version -eq $requirement.Version) {
                    $artifactFound = $artifact
                    break
                }
            }

            if ($null -ne $artifactFound) {
                break
            }
        }

        if ($null -eq $artifactFound) {
            throw ("Required shared helper artifact not found for offline client bundle: {0}" -f $requirement.Spec)
        }

        $destinationPath = Join-Path $CommonApprovedDirectory $artifactFound.Name
        if ($artifactFound.DirectoryName -ne $CommonApprovedDirectory) {
            Copy-Item -LiteralPath $artifactFound.FullName -Destination $destinationPath -Force
            Write-Ok ("Copied shared helper artifact to common approved: {0}" -f $artifactFound.Name)
        }
    }
}

function Trim-CommonApprovedSharedArtifacts {
    param(
        [Parameter(Mandatory = $true)][string]$CommonApprovedDirectory,
        [Parameter(Mandatory = $true)][string]$TrackName,
        [AllowEmptyCollection()][string[]]$KeepRequirementSpecs = @(),
        [switch]$Prune
    )

    if (-not (Test-Path -LiteralPath $CommonApprovedDirectory)) {
        return
    }

    if (-not $Prune) {
        Write-Info ("Preserving existing shared helper artifacts in common approved because approved rebuild is running in update mode.")
        return
    }

    $sharedPackageNames = @((Get-TrackValidationSettings -TrackName $TrackName).LockExcludePackages)
    $keepLookup = @{}
    foreach ($requirementSpec in (ConvertTo-NormalizedPackageList -PackageNames $KeepRequirementSpecs)) {
        $record = ConvertTo-RequirementRecord -RequirementSpec $requirementSpec
        if (-not $keepLookup.ContainsKey($record.Name)) {
            $keepLookup[$record.Name] = @{}
        }

        $keepLookup[$record.Name][$record.Version] = $true
    }

    foreach ($artifact in (Get-ChildItem -LiteralPath $CommonApprovedDirectory -File)) {
        $record = Get-ApprovedArtifactRequirementRecord -Artifact $artifact
        if ($record.Name -notin $sharedPackageNames) {
            continue
        }

        $keepArtifact = $keepLookup.ContainsKey($record.Name) -and $keepLookup[$record.Name].ContainsKey($record.Version)
        if (-not $keepArtifact) {
            Remove-Item -LiteralPath $artifact.FullName -Force
            Write-Info ("Removed unused shared helper artifact from common approved: {0}" -f $artifact.Name)
        }
    }
}

function Confirm-SharedArtifactsReadyForOfflineBundle {
    param(
        [Parameter(Mandatory = $true)][string]$CommonApprovedDirectory,
        [Parameter(Mandatory = $true)][string]$TrackName,
        [AllowEmptyCollection()][string[]]$RequirementSpecs = @()
    )

    if (-not (Test-Path -LiteralPath $CommonApprovedDirectory)) {
        throw "Common approved wheelhouse not found: $CommonApprovedDirectory"
    }

    $requiredSharedSpecs = @(ConvertTo-NormalizedPackageList -PackageNames $RequirementSpecs)
    if ($requiredSharedSpecs.Count -eq 0) {
        Write-Info ("No shared helper artifacts are required for offline bundle on track '{0}'." -f $TrackName)
        return
    }

    $artifactIndex = @{}
    foreach ($artifact in (Get-ChildItem -LiteralPath $CommonApprovedDirectory -File | Sort-Object Name)) {
        $record = Get-ApprovedArtifactRequirementRecord -Artifact $artifact
        if (-not $artifactIndex.ContainsKey($record.Name)) {
            $artifactIndex[$record.Name] = @{}
        }

        $artifactIndex[$record.Name][$record.Version] = $artifact.Name
    }

    foreach ($requirementSpec in $requiredSharedSpecs) {
        $requirement = ConvertTo-RequirementRecord -RequirementSpec $requirementSpec
        if (-not $artifactIndex.ContainsKey($requirement.Name) -or -not $artifactIndex[$requirement.Name].ContainsKey($requirement.Version)) {
            throw ("Offline client bundle is missing shared wheel '{0}=={1}' in common approved directory: {2}" -f $requirement.Name, $requirement.Version, $CommonApprovedDirectory)
        }

        Write-Ok ("Offline client bundle shared wheel ready: {0}=={1} -> {2}" -f $requirement.Name, $requirement.Version, $artifactIndex[$requirement.Name][$requirement.Version])
    }
}

function Get-BuildRequirementSpecsFromSourceArtifact {
    param(
        [Parameter(Mandatory = $true)][string]$ArtifactPath,
        [Parameter(Mandatory = $true)][string]$TrackName
    )

    $artifact = Get-Item -LiteralPath $ArtifactPath
    $record = Get-ApprovedArtifactRequirementRecord -Artifact $artifact
    $trackSettings = Get-TrackValidationSettings -TrackName $TrackName

    if ($trackSettings.SourceBuildRequirementMap.ContainsKey($record.Name)) {
        return @($trackSettings.SourceBuildRequirementMap[$record.Name])
    }

    return @($trackSettings.SourceBuildRequirementMap['default'])
}

function Install-BaseBuildHelpersInEnvironment {
    param(
        [Parameter(Mandatory = $true)][string]$EnvironmentName,
        [Parameter(Mandatory = $true)][string]$TrackName
    )

    $trackSettings = Get-TrackValidationSettings -TrackName $TrackName
    $requirementSpecs = @(ConvertTo-NormalizedPackageList -PackageNames $trackSettings.SourceBuildRequirementMap['default'])
    if ($requirementSpecs.Count -eq 0) {
        return
    }

    $requirementsPath = Join-Path $env:TEMP ("build_helper_bootstrap_{0}.txt" -f [guid]::NewGuid().ToString("N"))
    try {
        Set-Content -LiteralPath $requirementsPath -Value $requirementSpecs -Encoding UTF8
        Invoke-CondaPython -EnvironmentName $EnvironmentName -PythonArguments @(
            "-m", "pip", "install",
            "--progress-bar", "on",
            "-r", $requirementsPath
        ) -LiveStream
    }
    finally {
        if (Test-Path -LiteralPath $requirementsPath) {
            Remove-Item -LiteralPath $requirementsPath -Force
        }
    }
}

function Download-BuildRequirementsForSourceArtifacts {
    param(
        [Parameter(Mandatory = $true)][string]$EnvironmentName,
        [Parameter(Mandatory = $true)][string]$ApprovedDirectory,
        [Parameter(Mandatory = $true)][string]$TrackName
    )

    $sourceArtifacts = @(Get-SourceArtifactFiles -Directory $ApprovedDirectory)
    if ($sourceArtifacts.Count -eq 0) {
        return
    }

    $requirementSpecs = @()
    foreach ($artifact in $sourceArtifacts) {
        $requirementSpecs += Get-BuildRequirementSpecsFromSourceArtifact -ArtifactPath $artifact.FullName -TrackName $TrackName
    }

    $uniqueRequirementSpecs = @($requirementSpecs | Select-Object -Unique)
    if ($uniqueRequirementSpecs.Count -eq 0) {
        return
    }

    $requirementsPath = Join-Path $env:TEMP ("build_requirements_{0}.txt" -f [guid]::NewGuid().ToString("N"))
    try {
        Set-Content -LiteralPath $requirementsPath -Value $uniqueRequirementSpecs -Encoding UTF8
        Invoke-CondaPython -EnvironmentName $EnvironmentName -PythonArguments @(
            "-m", "pip", "download",
            "--progress-bar", "on",
            "-r", $requirementsPath,
            "-d", $ApprovedDirectory
        ) -LiveStream
    }
    finally {
        if (Test-Path -LiteralPath $requirementsPath) {
            Remove-Item -LiteralPath $requirementsPath -Force
        }
    }

    Write-Ok ("Build dependencies downloaded for source artifacts: {0}" -f $ApprovedDirectory)
}

function Ensure-AllSourceArtifactsConvertedToWheels {
    param(
        [Parameter(Mandatory = $true)][string]$EnvironmentName,
        [Parameter(Mandatory = $true)][string]$ApprovedDirectory
    )

    $sourceArtifacts = @(Get-SourceArtifactFiles -Directory $ApprovedDirectory)
    if ($sourceArtifacts.Count -eq 0) {
        return
    }

    foreach ($source in $sourceArtifacts) {
        $record = Get-ApprovedArtifactRequirementRecord -Artifact $source
        
        Write-Step ("Building wheel from source: {0}=={1}" -f $record.Name, $record.Version)
        
        # 이미 wheel이 있으면 source 파일만 삭제
        $existingWheels = @(Get-ChildItem -LiteralPath $ApprovedDirectory -File | Where-Object {
            ($_.Name -like "$($record.Name.Replace('-', '_'))*-*.whl") -or ($_.Name -like "$($record.Name.Replace('_', '-'))*-*.whl")
        })
        
        if ($existingWheels.Count -gt 0) {
            Remove-Item -LiteralPath $source.FullName -Force
            $wheelNames = @($existingWheels | ForEach-Object { $_.Name })
            Write-Ok ("Removed source artifact. Found wheels: {0}" -f ([string]::Join(", ", $wheelNames)))
            continue
        }
        
        # pip wheel로 source 파일을 빌드해서 wheel 생성
        Write-Info ("Building wheel from source artifact: {0}" -f $source.Name)
        try {
            Invoke-CondaPython -EnvironmentName $EnvironmentName -PythonArguments @(
                "-m", "pip", "wheel",
                "--no-deps",
                "--wheel-dir", $ApprovedDirectory,
                $source.FullName
            ) -LiveStream
            
            # 빌드 성공 확인
            $newWheels = @(Get-ChildItem -LiteralPath $ApprovedDirectory -File | Where-Object {
                ($_.Name -like "$($record.Name.Replace('-', '_'))*-*.whl") -or ($_.Name -like "$($record.Name.Replace('_', '-'))*-*.whl")
            })
            
            if ($newWheels.Count -gt 0) {
                Remove-Item -LiteralPath $source.FullName -Force
                $wheelNames = @($newWheels | ForEach-Object { $_.Name })
                Write-Ok ("Successfully built wheel from source: {0}" -f ([string]::Join(", ", $wheelNames)))
            }
            else {
                throw "Wheel file not found after build attempt"
            }
        }
        catch {
            Write-WarnLog ("Failed to build wheel for {0}=={1}: {2}" -f $record.Name, $record.Version, $_.Exception.Message)
            Write-WarnLog ("Keeping source artifact {0}" -f $source.Name)
        }
    }
}

function Ensure-PycudaWheelInApprovedDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$EnvironmentName,
        [Parameter(Mandatory = $true)][string]$ApprovedDirectory
    )

    # 이 함수는 호환성 유지를 위해 남겨둠 (새로운 일반화 함수에 위임)
    Ensure-AllSourceArtifactsConvertedToWheels -EnvironmentName $EnvironmentName -ApprovedDirectory $ApprovedDirectory
}

function Build-TempWheelhouseFromManifest {
    param(
        [Parameter(Mandatory = $true)][string]$EnvironmentName,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$OutputDirectory,
        [switch]$ExcludeCommonReference,
        [switch]$ClearCache
    )

    if ($ClearCache) {
        Reset-Directory -Path $OutputDirectory
    }
    else {
        Ensure-Directory -Path $OutputDirectory
    }

    $downloadRequirementsPath = New-FilteredRequirementsFile -SourcePath $ManifestPath -ExcludeCommonReference:$ExcludeCommonReference
    try {
        Invoke-CondaPython -EnvironmentName $EnvironmentName -PythonArguments @("-m", "pip", "download", "--progress-bar", "on", "--no-build-isolation", "-r", $downloadRequirementsPath, "-d", $OutputDirectory) -LiveStream
    }
    finally {
        if ($ExcludeCommonReference -and (Test-Path -LiteralPath $downloadRequirementsPath)) {
            Remove-Item -LiteralPath $downloadRequirementsPath -Force
        }
    }

    Write-Ok ("Temp wheel cache updated from manifest: {0}" -f $OutputDirectory)
}

function Build-ApprovedWheelhouseFromRequirements {
    param(
        [Parameter(Mandatory = $true)][string]$TrackName,
        [Parameter(Mandatory = $true)][string]$EnvironmentName,
        [Parameter(Mandatory = $true)][string]$RequirementsPath,
        [Parameter(Mandatory = $true)][string]$ApprovedDirectory,
        [switch]$ExcludeCommonReference,
        [switch]$ClearApproved
    )

    if ($ClearApproved) {
        Reset-Directory -Path $ApprovedDirectory
    }
    else {
        Ensure-Directory -Path $ApprovedDirectory
    }

    $isLockFileInput = (Split-Path -Leaf $RequirementsPath) -like '*.lock.txt'
    $downloadRequirementsPath = New-FilteredRequirementsFile -SourcePath $RequirementsPath -ExcludeCommonReference:$ExcludeCommonReference -ExcludeOfflineDirectives:$isLockFileInput
    try {
        Install-BaseBuildHelpersInEnvironment -EnvironmentName $EnvironmentName -TrackName $TrackName
        Invoke-CondaPython -EnvironmentName $EnvironmentName -PythonArguments @(
            "-m", "pip", "download",
            "--progress-bar", "on",
            "--no-build-isolation",
            "-r", $downloadRequirementsPath,
            "-d", $ApprovedDirectory
        ) -LiveStream
    }
    finally {
        if ($downloadRequirementsPath -ne $RequirementsPath -and (Test-Path -LiteralPath $downloadRequirementsPath)) {
            Remove-Item -LiteralPath $downloadRequirementsPath -Force
        }
    }

    Ensure-PycudaWheelInApprovedDirectory -EnvironmentName $EnvironmentName -ApprovedDirectory $ApprovedDirectory
    Download-BuildRequirementsForSourceArtifacts -EnvironmentName $EnvironmentName -ApprovedDirectory $ApprovedDirectory -TrackName $TrackName

    Write-Ok ("Approved wheelhouse rebuilt from requirements: {0}" -f $ApprovedDirectory)
}

function Ensure-CondaEnvironmentReady {
    param(
        [Parameter(Mandatory = $true)][string]$EnvironmentName,
        [Parameter(Mandatory = $true)][string]$RequestedPythonVersion,
        [switch]$Recreate,
        [switch]$SkipCreate
    )

    $envExists = Test-CondaEnvironmentExists -EnvironmentName $EnvironmentName
    if ($envExists -and $Recreate) {
        Write-WarnLog ("Removing existing environment: {0}" -f $EnvironmentName)
        Remove-CondaEnvironment -EnvironmentName $EnvironmentName
        $envExists = $false
    }

    if (-not $envExists -and -not $SkipCreate) {
        Write-Step ("Creating environment: {0}" -f $EnvironmentName)
        New-CondaEnvironment -EnvironmentName $EnvironmentName -RequestedPythonVersion $RequestedPythonVersion
        $envExists = $true
    }
    elseif ($envExists -and -not $SkipCreate) {
        Write-Info ("Reusing existing environment: {0}" -f $EnvironmentName)
    }

    if (-not $envExists) {
        throw "Environment does not exist: $EnvironmentName"
    }
}

function Install-OfflineFromWheelhouse {
    param(
        [Parameter(Mandatory = $true)][string]$EnvironmentName,
        [Parameter(Mandatory = $true)][string]$TrackLockPath,
        [Parameter(Mandatory = $true)][string[]]$FindLinkDirectories
    )

    Assert-OfflineArtifactsAvailable -TrackLockPath $TrackLockPath -FindLinkDirectories $FindLinkDirectories

    $installDirectory = Split-Path -Parent $TrackLockPath
    Push-Location -LiteralPath $installDirectory
    try {
        $installArguments = @(
            "-m", "pip", "install",
            "--progress-bar", "on",
            "--no-index",
            "--no-build-isolation",
            "-r", (Split-Path -Leaf $TrackLockPath)
        )

        Invoke-CondaPython -EnvironmentName $EnvironmentName -PythonArguments $installArguments -LiveStream
    }
    finally {
        Pop-Location
    }
}

$requirementsRoot = $PSScriptRoot
$workspaceRoot = Split-Path -Parent $requirementsRoot
if ([string]::IsNullOrWhiteSpace($WheelOutputRoot)) {
    $WheelOutputRoot = Join-Path $requirementsRoot "wheelhouse"
}
elseif (-not [System.IO.Path]::IsPathRooted($WheelOutputRoot)) {
    $WheelOutputRoot = Join-Path $workspaceRoot $WheelOutputRoot
}
if ([string]::IsNullOrWhiteSpace($LogRoot)) {
    $LogRoot = Join-Path $requirementsRoot "logs"
}
elseif (-not [System.IO.Path]::IsPathRooted($LogRoot)) {
    $LogRoot = Join-Path $workspaceRoot $LogRoot
}

Assert-CommandExists -Name "conda"

$commonConfig = Get-CommonConfig -RequirementsRoot $requirementsRoot
$commonWheelPaths = Get-CommonWheelhousePaths -WheelRoot $WheelOutputRoot
$selectedTracks = Get-SelectedTracks -RequestedTracks $Track
$trackConfigs = foreach ($trackName in $selectedTracks) {
    Get-TrackConfig -TrackName $trackName -RequirementsRoot $requirementsRoot -EnvironmentPrefix $EnvPrefix
}

$requiresEnvironment = (-not $SkipInstall) -or (-not $SkipValidation)
$requiresOnlineEnvironment = $requiresEnvironment -or $BuildTempWheelCache -or $BuildApprovedWheelhouse
$performFinalOfflineValidation = $VerifyOfflineInstall -or $SyncLock
$commonLockPackageNames = @()

$logFilePath = New-LogFilePath -BaseDirectory $LogRoot -TrackNames $selectedTracks
$script:SidecarLogPath = [System.IO.Path]::ChangeExtension($logFilePath, ".runtime.log")
$script:PlainLogPath = $script:SidecarLogPath
if (Test-Path -LiteralPath $script:SidecarLogPath) {
    Remove-Item -LiteralPath $script:SidecarLogPath -Force
}
Start-Transcript -Path $logFilePath -Force | Out-Null

try {
    Write-Step "Requirements validation started"
    Write-SectionSummary -Title "Run configuration" -Lines @(
        ("Tracks           : {0}" -f ($selectedTracks -join ", ")),
        ("Requirements root: {0}" -f $requirementsRoot),
        ("Wheel root       : {0}" -f $WheelOutputRoot),
        ("Common temp      : {0}" -f $commonWheelPaths.TempDirectory),
        ("Common approved  : {0}" -f $commonWheelPaths.ApprovedDirectory),
        ("Log file         : {0}" -f $logFilePath)
    )

    $commonTempBuilt = $false
    $commonApprovedBuilt = $false
    $requiredSharedHelperSpecs = @()

    foreach ($config in $trackConfigs) {
        Write-Step ("Processing track: {0}" -f $config.Name)
        $wheelPaths = Get-WheelhousePaths -WheelRoot $WheelOutputRoot -TrackName $config.Name

        if ($requiresOnlineEnvironment) {
            Ensure-CondaEnvironmentReady -EnvironmentName $config.EnvironmentName -RequestedPythonVersion $PythonVersion -Recreate:$RemoveValidationEnv -SkipCreate:$SkipCreateEnv

            if (-not $SkipInstall -and -not $SyncLock) {
                Write-Step ("Installing manifest: {0}" -f $config.ManifestPath)
                Install-Manifest -EnvironmentName $config.EnvironmentName -ManifestPath $config.ManifestPath
            }

            if (-not $SyncLock -and -not $SkipValidation) {
                Test-ApiTrack -EnvironmentName $config.EnvironmentName
                Test-GpuTrack -EnvironmentName $config.EnvironmentName -TrackName $config.Name
            }
        }
        else {
            Write-Info ("Environment steps skipped for track '{0}' because only sync operations were requested." -f $config.Name)
        }

        if ($BuildTempWheelCache -and -not $commonTempBuilt) {
            Write-Step ("Updating common temp wheelhouse: {0}" -f $commonWheelPaths.TempDirectory)
            Build-TempWheelhouseFromManifest -EnvironmentName $config.EnvironmentName -ManifestPath $commonConfig.ManifestPath -OutputDirectory $commonWheelPaths.TempDirectory -ClearCache:$ClearTempWheelCache
            $commonTempBuilt = $true
        }

        if ($BuildTempWheelCache) {
            Write-Step ("Updating track temp wheelhouse: {0}" -f $wheelPaths.TempDirectory)
            Build-TempWheelhouseFromManifest -EnvironmentName $config.EnvironmentName -ManifestPath $config.ManifestPath -OutputDirectory $wheelPaths.TempDirectory -ExcludeCommonReference -ClearCache:$ClearTempWheelCache
        }

        if ($SyncLock -and -not $commonApprovedBuilt) {
            Write-Step ("Rebuilding common approved wheelhouse from manifest: {0}" -f $commonWheelPaths.ApprovedDirectory)
            Build-ApprovedWheelhouseFromRequirements -TrackName $commonConfig.Name -EnvironmentName $config.EnvironmentName -RequirementsPath $commonConfig.ManifestPath -ApprovedDirectory $commonWheelPaths.ApprovedDirectory -ClearApproved:$ClearApprovedWheelhouse
            $commonApprovedBuilt = $true
        }

        if ($BuildApprovedWheelhouse -and -not $SyncLock -and -not $commonApprovedBuilt) {
            Write-Step ("Rebuilding common approved wheelhouse from manifest: {0}" -f $commonWheelPaths.ApprovedDirectory)
            Build-ApprovedWheelhouseFromRequirements -TrackName $commonConfig.Name -EnvironmentName $config.EnvironmentName -RequirementsPath $commonConfig.ManifestPath -ApprovedDirectory $commonWheelPaths.ApprovedDirectory -ClearApproved:$ClearApprovedWheelhouse
            $commonApprovedBuilt = $true
        }

        if ($SyncLock) {
            Write-Step ("Rebuilding track approved wheelhouse from manifest: {0}" -f $wheelPaths.ApprovedDirectory)
            Build-ApprovedWheelhouseFromRequirements -TrackName $config.Name -EnvironmentName $config.EnvironmentName -RequirementsPath $config.ManifestPath -ApprovedDirectory $wheelPaths.ApprovedDirectory -ExcludeCommonReference -ClearApproved:$ClearApprovedWheelhouse
        }

        if ($BuildApprovedWheelhouse -and -not $SyncLock) {
            Write-Step ("Rebuilding track approved wheelhouse from manifest: {0}" -f $wheelPaths.ApprovedDirectory)
            Build-ApprovedWheelhouseFromRequirements -TrackName $config.Name -EnvironmentName $config.EnvironmentName -RequirementsPath $config.ManifestPath -ApprovedDirectory $wheelPaths.ApprovedDirectory -ExcludeCommonReference -ClearApproved:$ClearApprovedWheelhouse

            $trackSharedHelperSpecs = @(Get-RequiredSharedBuildRequirementSpecsForApprovedDirectory -ApprovedDirectory $wheelPaths.ApprovedDirectory -TrackName $config.Name)
            if ($trackSharedHelperSpecs -and $trackSharedHelperSpecs.Count -gt 0) {
                $requiredSharedHelperSpecs = @(ConvertTo-NormalizedPackageList -PackageNames ($requiredSharedHelperSpecs + $trackSharedHelperSpecs))
                Sync-SharedArtifactsToCommonApproved -CommonApprovedDirectory $commonWheelPaths.ApprovedDirectory -SourceDirectories @($wheelPaths.ApprovedDirectory) -RequirementSpecs $requiredSharedHelperSpecs
                Trim-CommonApprovedSharedArtifacts -CommonApprovedDirectory $commonWheelPaths.ApprovedDirectory -TrackName $config.Name -KeepRequirementSpecs $requiredSharedHelperSpecs -Prune:$ClearApprovedWheelhouse
            }
        }

        if ($SyncLock) {
            $trackSharedHelperSpecs = @(Get-RequiredSharedBuildRequirementSpecsForApprovedDirectory -ApprovedDirectory $wheelPaths.ApprovedDirectory -TrackName $config.Name)
            if ($trackSharedHelperSpecs -and $trackSharedHelperSpecs.Count -gt 0) {
                $requiredSharedHelperSpecs = @(ConvertTo-NormalizedPackageList -PackageNames ($requiredSharedHelperSpecs + $trackSharedHelperSpecs))
                Sync-SharedArtifactsToCommonApproved -CommonApprovedDirectory $commonWheelPaths.ApprovedDirectory -SourceDirectories @($wheelPaths.ApprovedDirectory) -RequirementSpecs $requiredSharedHelperSpecs
                Trim-CommonApprovedSharedArtifacts -CommonApprovedDirectory $commonWheelPaths.ApprovedDirectory -TrackName $config.Name -KeepRequirementSpecs $requiredSharedHelperSpecs -Prune:$ClearApprovedWheelhouse
            }

            if (-not (Test-Path -LiteralPath $commonWheelPaths.ApprovedDirectory)) {
                throw "Common approved wheelhouse not found: $($commonWheelPaths.ApprovedDirectory). Build wheelhouse first."
            }

            Write-Step ("Creating common lock file from approved artifacts: {0}" -f $commonConfig.LockPath)
            Sync-LockFileFromApprovedArtifacts -ManifestPath $commonConfig.ManifestPath -LockPath $commonConfig.LockPath -ApprovedDirectory $commonWheelPaths.ApprovedDirectory -TrackName $commonConfig.Name -EnvironmentName $config.EnvironmentName -CommentedRequirementSpecs $requiredSharedHelperSpecs
            $commonLockPackageNames = @((Get-PinnedRequirementsFromFile -RequirementsPath $commonConfig.LockPath) | ForEach-Object { $_.Name } | Select-Object -Unique)

            Write-Step ("Creating track lock file from approved artifacts: {0}" -f $config.LockPath)
            Sync-LockFileFromApprovedArtifacts -ManifestPath $config.ManifestPath -LockPath $config.LockPath -ApprovedDirectory $wheelPaths.ApprovedDirectory -TrackName $config.Name -ExcludedPackageNames $commonLockPackageNames

            Write-Step ("Verifying shared wheels for offline client bundle: {0}" -f $config.Name)
            if ($trackSharedHelperSpecs -and $trackSharedHelperSpecs.Count -gt 0) {
                Confirm-SharedArtifactsReadyForOfflineBundle -CommonApprovedDirectory $commonWheelPaths.ApprovedDirectory -TrackName $config.Name -RequirementSpecs $trackSharedHelperSpecs
            }
        }

        if ($performFinalOfflineValidation) {
            if (-not (Test-Path -LiteralPath $commonWheelPaths.ApprovedDirectory)) {
                throw "Common approved wheelhouse not found: $($commonWheelPaths.ApprovedDirectory). Build wheelhouse first."
            }

            if (-not (Test-Path -LiteralPath $wheelPaths.ApprovedDirectory)) {
                throw "Approved wheelhouse not found: $($wheelPaths.ApprovedDirectory). Build wheelhouse first."
            }

            $offlineEnvironmentName = "{0}-offline" -f $config.EnvironmentName
            Write-Step ("Preparing offline validation environment: {0}" -f $offlineEnvironmentName)
            Ensure-CondaEnvironmentReady -EnvironmentName $offlineEnvironmentName -RequestedPythonVersion $PythonVersion -Recreate:$RemoveOfflineEnv -SkipCreate:$false

            Write-Step ("Installing from approved wheelhouse for track: {0}" -f $config.Name)
            Install-OfflineFromWheelhouse -EnvironmentName $offlineEnvironmentName -TrackLockPath $config.LockPath -FindLinkDirectories @($commonWheelPaths.ApprovedDirectory, $wheelPaths.ApprovedDirectory)

            Write-Step ("Running offline validation for track: {0}" -f $config.Name)
            Test-ApiTrack -EnvironmentName $offlineEnvironmentName
            Test-GpuTrack -EnvironmentName $offlineEnvironmentName -TrackName $config.Name
        }

        Write-Ok ("Track completed: {0}" -f $config.Name)
    }

    Write-Ok "All requested tracks completed successfully."
    Write-Info ("Transcript saved: {0}" -f $logFilePath)
}
finally {
    Stop-Transcript | Out-Null

    if (-not [string]::IsNullOrWhiteSpace($script:SidecarLogPath) -and (Test-Path -LiteralPath $script:SidecarLogPath)) {
        Add-Content -LiteralPath $logFilePath -Value ""
        Add-Content -LiteralPath $logFilePath -Value "==== Runtime Output ===="
        Get-Content -LiteralPath $script:SidecarLogPath | Add-Content -LiteralPath $logFilePath
        Remove-Item -LiteralPath $script:SidecarLogPath -Force
    }
}