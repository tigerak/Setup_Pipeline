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

function Write-LogLine {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message)

    if (-not [string]::IsNullOrWhiteSpace($script:PlainLogPath)) {
        Add-Content -LiteralPath $script:PlainLogPath -Value (Normalize-LogText -Text $Message) -Encoding UTF8
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

function Get-ApiConfig {
    param([Parameter(Mandatory = $true)][string]$RequirementsRoot)

    $manifestPath = Join-Path $RequirementsRoot "api.in"
    $lockPath = Join-Path $RequirementsRoot "api.lock.txt"

    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Manifest not found: $manifestPath"
    }

    [pscustomobject]@{
        Name = "api"
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

function Get-ApiWheelhousePaths {
    param(
        [Parameter(Mandatory = $true)][string]$WheelRoot
    )

    [pscustomobject]@{
        TempDirectory = Join-Path (Join-Path $WheelRoot "temp") "api"
        ApprovedDirectory = Join-Path (Join-Path $WheelRoot "approved") "api"
    }
}

function New-FilteredRequirementsFile {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [switch]$ExcludeApiReference
    )

    if (-not $ExcludeApiReference) {
        return $SourcePath
    }

    $filteredPath = Join-Path $env:TEMP ("requirements_filtered_{0}.txt" -f [guid]::NewGuid().ToString("N"))
    $content = Get-Content -LiteralPath $SourcePath
    $filteredContent = foreach ($line in $content) {
        if ($line -match '^-r\s+api\.(?:in|lock\.txt)\s*$') {
            continue
        }

        $line
    }

    Set-Content -LiteralPath $filteredPath -Value $filteredContent -Encoding UTF8
    return $filteredPath
}

function Get-CondaEnvironmentNames {
    $jsonText = & conda env list --json 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to query conda environments.`n$jsonText"
    }

    $parsed = $jsonText | Out-String | ConvertFrom-Json
    $names = @()

    foreach ($envPath in $parsed.envs) {
        if ([string]::IsNullOrWhiteSpace($envPath)) { continue }
        $names += (Split-Path -Leaf $envPath)
    }

    $names | Select-Object -Unique
}

function Test-CondaEnvironmentExists {
    param([Parameter(Mandatory = $true)][string]$EnvironmentName)

    $envNames = Get-CondaEnvironmentNames
    $envNames -contains $EnvironmentName
}

function Invoke-Conda {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $displayCommand = "conda {0}" -f ($Arguments -join " ")
    Write-Info $displayCommand
    Write-LogLine -Message ("[INFO] {0}" -f $displayCommand)
    Invoke-LoggedExternalCommand -FilePath "conda" -Arguments $Arguments -ErrorMessage ("Conda command failed: {0}" -f $displayCommand)
}

function Invoke-CondaPython {
    param(
        [Parameter(Mandatory = $true)][string]$EnvironmentName,
        [Parameter(Mandatory = $true)][string[]]$PythonArguments,
        [switch]$LiveStream
    )

    $allArguments = @("run")
    if ($LiveStream) {
        $allArguments += "--live-stream"
    }
    $allArguments += @("-n", $EnvironmentName, "python") + $PythonArguments
    $displayCommand = "conda {0}" -f ($allArguments -join " ")
    Write-Info $displayCommand
    Write-LogLine -Message ("[INFO] {0}" -f $displayCommand)
    Invoke-LoggedExternalCommand -FilePath "conda" -Arguments $allArguments -ErrorMessage ("Python command failed in conda env '{0}'" -f $EnvironmentName) -LiveStream:$LiveStream
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

    Invoke-Conda -Arguments @("create", "-n", $EnvironmentName, ("python={0}" -f $RequestedPythonVersion), "-y")
}

function Remove-CondaEnvironment {
    param([Parameter(Mandatory = $true)][string]$EnvironmentName)

    try {
        Invoke-Conda -Arguments @("env", "remove", "-n", $EnvironmentName, "-y")
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
    Invoke-CondaPython -EnvironmentName $EnvironmentName -PythonArguments @("-m", "pip", "install", "--progress-bar", "on", "-r", $ManifestPath) -LiveStream
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

function Get-ValidationSettingsPath {
    return (Join-Path $PSScriptRoot 'run_requirements_validation.settings.psd1')
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

                Normalize-PackageName -Name $value
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
    param([Parameter(Mandatory = $true)][string]$ManifestPath)

    $headerLines = @()
    foreach ($line in (Get-Content -LiteralPath $ManifestPath)) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

        if ($trimmed -match '^-r\s+api\.in\s*$') {
            $headerLines += '-r api.lock.txt'
            continue
        }

        if ($trimmed.StartsWith('--')) {
            $headerLines += $trimmed
        }
    }

    return @($headerLines)
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
        [Parameter(Mandatory = $true)][string]$TrackName
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
        [Parameter(Mandatory = $true)][string]$TrackName
    )

    $headerLines = Get-LockHeaderLines -ManifestPath $ManifestPath
    $artifactLines = Get-ApprovedRequirementLines -ApprovedDirectory $ApprovedDirectory -TrackName $TrackName

    $updated = @()
    $updated += $headerLines
    $updated += $artifactLines

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
        [string]$ExcludeRequirementsPath
    )

    $headerLines = Get-LockHeaderLines -ManifestPath $ManifestPath
    $excludedPackageNames = @()
    if (-not [string]::IsNullOrWhiteSpace($ExcludeRequirementsPath) -and (Test-Path -LiteralPath $ExcludeRequirementsPath)) {
        $excludedPackageNames = Get-RequirementPackageNames -RequirementsPath $ExcludeRequirementsPath
    }

    $updated = @()
    $updated += $headerLines

    foreach ($line in (Get-FrozenRequirementLines -EnvironmentName $EnvironmentName)) {
        if ($line -match '^([A-Za-z0-9._-]+)') {
            $packageName = Normalize-PackageName -Name $matches[1]
            if ($excludedPackageNames -contains $packageName) {
                continue
            }
        }

        $updated += $line
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

function Ensure-PycudaWheelInApprovedDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$EnvironmentName,
        [Parameter(Mandatory = $true)][string]$ApprovedDirectory
    )

    $pycudaSource = Get-ChildItem -LiteralPath $ApprovedDirectory -File | Where-Object {
        $_.Name -match '^pycuda-(?<version>[^-]+)\.(tar\.gz|tar\.bz2|zip)$'
    } | Select-Object -First 1

    if (-not $pycudaSource) {
        return
    }

    $pycudaWheel = Get-ChildItem -LiteralPath $ApprovedDirectory -File | Where-Object {
        $_.Name -like 'pycuda-*.whl'
    } | Select-Object -First 1

    if ($pycudaWheel) {
        Remove-Item -LiteralPath $pycudaSource.FullName -Force
        return
    }

    $pycudaRecord = Get-ApprovedArtifactRequirementRecord -Artifact $pycudaSource
    $pycudaVersion = $pycudaRecord.Version
    try {
        Invoke-CondaPython -EnvironmentName $EnvironmentName -PythonArguments @(
            "-m", "pip", "download",
            "--progress-bar", "on",
            "--only-binary", ":all:",
            "--no-deps",
            ("pycuda=={0}" -f $pycudaVersion),
            "-d", $ApprovedDirectory
        ) -LiveStream
    }
    catch {
        Write-WarnLog ("Binary wheel download unavailable for pycuda=={0}; keeping source artifact and downloading build dependencies instead." -f $pycudaVersion)
    }

    $pycudaWheel = Get-ChildItem -LiteralPath $ApprovedDirectory -File | Where-Object {
        $_.Name -like 'pycuda-*.whl'
    } | Select-Object -First 1
    if ($pycudaWheel) {
        Remove-Item -LiteralPath $pycudaSource.FullName -Force
        Write-Ok ("Binary wheel captured for pycuda: {0}" -f $pycudaWheel.Name)
    }
}

function Build-TempWheelhouseFromManifest {
    param(
        [Parameter(Mandatory = $true)][string]$EnvironmentName,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$OutputDirectory,
        [switch]$ExcludeApiReference,
        [switch]$ClearCache
    )

    if ($ClearCache) {
        Reset-Directory -Path $OutputDirectory
    }
    else {
        Ensure-Directory -Path $OutputDirectory
    }

    $downloadRequirementsPath = New-FilteredRequirementsFile -SourcePath $ManifestPath -ExcludeApiReference:$ExcludeApiReference
    try {
        Invoke-CondaPython -EnvironmentName $EnvironmentName -PythonArguments @("-m", "pip", "download", "--progress-bar", "on", "-r", $downloadRequirementsPath, "-d", $OutputDirectory) -LiveStream
    }
    finally {
        if ($ExcludeApiReference -and (Test-Path -LiteralPath $downloadRequirementsPath)) {
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
        [switch]$ExcludeApiReference,
        [switch]$ClearApproved
    )

    if ($ClearApproved) {
        Reset-Directory -Path $ApprovedDirectory
    }
    else {
        Ensure-Directory -Path $ApprovedDirectory
    }

    $downloadRequirementsPath = New-FilteredRequirementsFile -SourcePath $RequirementsPath -ExcludeApiReference:$ExcludeApiReference
    try {
        Invoke-CondaPython -EnvironmentName $EnvironmentName -PythonArguments @(
            "-m", "pip", "download",
            "--progress-bar", "on",
            "-r", $downloadRequirementsPath,
            "-d", $ApprovedDirectory
        ) -LiveStream
    }
    finally {
        if ($ExcludeApiReference -and (Test-Path -LiteralPath $downloadRequirementsPath)) {
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

    Invoke-CondaPython -EnvironmentName $EnvironmentName -PythonArguments @("-m", "pip", "install", "--progress-bar", "on", "--upgrade", "pip") -LiveStream
    $installArguments = @(
        "-m", "pip", "install",
        "--progress-bar", "on",
        "--no-index"
    )

    foreach ($findLinkDirectory in $FindLinkDirectories) {
        $installArguments += @("--find-links", $findLinkDirectory)
    }

    $installArguments += @("-r", $TrackLockPath)

    Invoke-CondaPython -EnvironmentName $EnvironmentName -PythonArguments $installArguments -LiveStream
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

$apiConfig = Get-ApiConfig -RequirementsRoot $requirementsRoot
$apiWheelPaths = Get-ApiWheelhousePaths -WheelRoot $WheelOutputRoot
$selectedTracks = Get-SelectedTracks -RequestedTracks $Track
$apiEnvironmentName = "{0}-api" -f $EnvPrefix
$trackConfigs = foreach ($trackName in $selectedTracks) {
    Get-TrackConfig -TrackName $trackName -RequirementsRoot $requirementsRoot -EnvironmentPrefix $EnvPrefix
}

$requiresEnvironment = (-not $SkipInstall) -or (-not $SkipValidation)
$requiresOnlineEnvironment = $requiresEnvironment -or $BuildTempWheelCache -or $BuildApprovedWheelhouse
$apiLockSynced = $false
$performFinalOfflineValidation = $VerifyOfflineInstall -or $SyncLock

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
        ("API temp         : {0}" -f $apiWheelPaths.TempDirectory),
        ("API approved     : {0}" -f $apiWheelPaths.ApprovedDirectory),
        ("Log file         : {0}" -f $logFilePath)
    )

    $apiTempBuilt = $false
    $apiApprovedBuilt = $false

    foreach ($config in $trackConfigs) {
        Write-Step ("Processing track: {0}" -f $config.Name)

        if ($requiresOnlineEnvironment) {
            Ensure-CondaEnvironmentReady -EnvironmentName $config.EnvironmentName -RequestedPythonVersion $PythonVersion -Recreate:$RemoveValidationEnv -SkipCreate:$SkipCreateEnv

            if (-not $SyncLock -and -not $SkipInstall) {
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

        $wheelPaths = Get-WheelhousePaths -WheelRoot $WheelOutputRoot -TrackName $config.Name

        if ($BuildTempWheelCache -and -not $apiTempBuilt) {
            Write-Step ("Updating API temp wheelhouse: {0}" -f $apiWheelPaths.TempDirectory)
            Build-TempWheelhouseFromManifest -EnvironmentName $config.EnvironmentName -ManifestPath $apiConfig.ManifestPath -OutputDirectory $apiWheelPaths.TempDirectory -ClearCache:$ClearTempWheelCache
            $apiTempBuilt = $true
        }

        if ($BuildTempWheelCache) {
            Write-Step ("Updating track temp wheelhouse: {0}" -f $wheelPaths.TempDirectory)
            Build-TempWheelhouseFromManifest -EnvironmentName $config.EnvironmentName -ManifestPath $config.ManifestPath -OutputDirectory $wheelPaths.TempDirectory -ExcludeApiReference -ClearCache:$ClearTempWheelCache
        }

        if (($BuildApprovedWheelhouse -or $SyncLock) -and -not $apiApprovedBuilt) {
            Write-Step ("Rebuilding API approved wheelhouse from manifest: {0}" -f $apiWheelPaths.ApprovedDirectory)
            Build-ApprovedWheelhouseFromRequirements -TrackName $apiConfig.Name -EnvironmentName $config.EnvironmentName -RequirementsPath $apiConfig.ManifestPath -ApprovedDirectory $apiWheelPaths.ApprovedDirectory -ClearApproved:$ClearApprovedWheelhouse
            $apiApprovedBuilt = $true
        }

        if ($BuildApprovedWheelhouse -or $SyncLock) {
            Write-Step ("Rebuilding track approved wheelhouse from manifest: {0}" -f $wheelPaths.ApprovedDirectory)
            Build-ApprovedWheelhouseFromRequirements -TrackName $config.Name -EnvironmentName $config.EnvironmentName -RequirementsPath $config.ManifestPath -ApprovedDirectory $wheelPaths.ApprovedDirectory -ExcludeApiReference -ClearApproved:$ClearApprovedWheelhouse
        }

        if ($SyncLock -and -not $apiLockSynced) {
            Write-Step ("Syncing base lock file from approved artifacts: {0}" -f $apiConfig.LockPath)
            Sync-LockFileFromApprovedArtifacts -ManifestPath $apiConfig.ManifestPath -LockPath $apiConfig.LockPath -ApprovedDirectory $apiWheelPaths.ApprovedDirectory -TrackName $apiConfig.Name
            $apiLockSynced = $true
        }

        if ($SyncLock) {
            Write-Step ("Syncing track lock file from approved artifacts: {0}" -f $config.LockPath)
            Sync-LockFileFromApprovedArtifacts -ManifestPath $config.ManifestPath -LockPath $config.LockPath -ApprovedDirectory $wheelPaths.ApprovedDirectory -TrackName $config.Name
        }

        if ($performFinalOfflineValidation) {
            if (-not (Test-Path -LiteralPath $apiWheelPaths.ApprovedDirectory)) {
                throw "API approved wheelhouse not found: $($apiWheelPaths.ApprovedDirectory). Build wheelhouse first."
            }

            if (-not (Test-Path -LiteralPath $wheelPaths.ApprovedDirectory)) {
                throw "Approved wheelhouse not found: $($wheelPaths.ApprovedDirectory). Build wheelhouse first."
            }

            $offlineEnvironmentName = "{0}-offline" -f $config.EnvironmentName
            Write-Step ("Preparing offline validation environment: {0}" -f $offlineEnvironmentName)
            Ensure-CondaEnvironmentReady -EnvironmentName $offlineEnvironmentName -RequestedPythonVersion $PythonVersion -Recreate:$RemoveOfflineEnv -SkipCreate:$false

            Write-Step ("Installing from approved wheelhouse for track: {0}" -f $config.Name)
            Install-OfflineFromWheelhouse -EnvironmentName $offlineEnvironmentName -TrackLockPath $config.LockPath -FindLinkDirectories @($apiWheelPaths.ApprovedDirectory, $wheelPaths.ApprovedDirectory)

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