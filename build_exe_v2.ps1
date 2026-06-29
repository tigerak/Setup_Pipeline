param(
    [ValidateSet("gui", "dev")]
    [string]$Target = "gui",

    [string]$OutDir = "dist",

    [string]$Title = "Vision AI Env Installer",
    [string]$Description = "Vision AI Env Setup Pipeline launcher",
    [string]$Product = "Vision AI Env Setup Pipeline",
    [string]$Company = "LG Ensol",
    [string]$Copyright = "Vision AI Team",
    [ValidatePattern('^\d+\.\d+(\.\d+\.\d+)?$')]
    [string]$Version = "3.0.0.0",
    [string]$IconFile = ""
)

$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
$outPath = Join-Path $root $OutDir

if (-not (Test-Path $outPath)) {
    New-Item -ItemType Directory -Path $outPath | Out-Null
}

$sourceScript = if ($Target -eq "gui") {
    Join-Path $root "pipeline_gui_v2.ps1"
} else {
    Join-Path $root "pipeline_dev_v2.ps1"
}

if (-not (Test-Path $sourceScript)) {
    throw "Source script not found: $sourceScript"
}

$exeName = if ($Target -eq "gui") {
    "pipeline_gui_v2.exe"
} else {
    "pipeline_dev_v2.exe"
}

$exePath = Join-Path $outPath $exeName

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host "ps2exe module not found. Installing for current user..." -ForegroundColor Yellow
    Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber
}

Import-Module ps2exe -ErrorAction Stop

# EXE 실행 시 $PSScriptRoot 가 임시경로로 바뀌기 때문에,
# 코어 스크립트를 dot-source로 로드할 수 없다.
# 빌드 전에 진입점 + 코어를 하나의 임시 파일로 병합한 뒤 컴파일한다.
$coreScript = Join-Path $root "pipeline_core_v2.ps1"
if (-not (Test-Path $coreScript)) {
    throw "Core script not found: $coreScript"
}

$entryContent = Get-Content -Path $sourceScript -Raw
$coreContent  = Get-Content -Path $coreScript  -Raw

# param() 블록은 스크립트 최상단에만 있어야 동작한다.
# 진입점의 param 블록 추출 → 코어 → 나머지 진입점 순으로 병합한다.
$paramMatch = [regex]::Match($entryContent, '(?s)^\s*(param\s*\(.*?\))\s*')
$paramBlock = if ($paramMatch.Success) { $paramMatch.Groups[1].Value.Trim() } else { "" }

$entryStripped = $entryContent `
    -replace '(?s)^\s*param\s*\(.*?\)\s*', '' `
    -replace '(?m)^\s*\.\s+"?\$PSScriptRoot\\pipeline_core_v2\.ps1"?\s*$', ''

if ($paramBlock) {
    $mergedContent = $paramBlock + "`r`n`r`n" + $coreContent + "`r`n" + $entryStripped
} else {
    $mergedContent = $coreContent + "`r`n" + $entryStripped
}

$tempScript = Join-Path $env:TEMP ("pipeline_merged_" + [guid]::NewGuid().ToString("N") + ".ps1")
Set-Content -Path $tempScript -Value $mergedContent -Encoding UTF8

Write-Host "Merged script created: $tempScript" -ForegroundColor DarkGray

$commonArgs = @{
    inputFile = $tempScript
    outputFile = $exePath
    requireAdmin = $true
    title = $Title
    description = $Description
    product = $Product
    company = $Company
    copyright = $Copyright
    version = $Version
}

if ($Target -eq "gui") {
    $commonArgs["noConsole"] = $true
}

if (-not [string]::IsNullOrWhiteSpace($IconFile)) {
    $resolvedIcon = if ([System.IO.Path]::IsPathRooted($IconFile)) {
        $IconFile
    } else {
        Join-Path $root $IconFile
    }

    if (-not (Test-Path $resolvedIcon)) {
        throw "Icon file not found: $resolvedIcon"
    }

    $commonArgs["iconFile"] = $resolvedIcon
}

Invoke-PS2EXE @commonArgs

Remove-Item -Path $tempScript -Force -ErrorAction SilentlyContinue

Write-Host "Build completed: $exePath" -ForegroundColor Green
Write-Host "Run the EXE and approve UAC prompt to launch as administrator." -ForegroundColor Cyan
Write-Host "Metadata => Company: $Company | Product: $Product | Version: $Version" -ForegroundColor Cyan

# powershell -ExecutionPolicy Bypass -File .\build_exe_v2.ps1 -Target gui (or dev)