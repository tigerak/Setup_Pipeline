param(
    [string]$OutDir = "dist",

    [string]$Title = "Vision AI Env Installer",
    [string]$Description = "Vision AI Env Setup Pipeline launcher",
    [string]$Product = "Vision AI Env Setup Pipeline",
    [string]$Company = "LG Ensol",
    [string]$Copyright = "Vision AI Team",
    [ValidatePattern('^\d+\.\d+(\.\d+\.\d+)?$')]
    [string]$Version = "3.1.1.0",
    [string]$IconFile = ""
)

$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
$outPath = Join-Path $root $OutDir

if (-not (Test-Path $outPath)) {
    New-Item -ItemType Directory -Path $outPath | Out-Null
}

$sourceScript = Join-Path $root "pipeline_gui_v3.ps1"
$configScript = Join-Path $root "pipeline_config_v3.ps1"

if (-not (Test-Path $sourceScript)) {
    throw "Source script not found: $sourceScript"
}

if (-not (Test-Path $configScript)) {
    throw "Config script not found: $configScript"
}

$exeName = "pipeline_gui_v3_$($Version -replace '\.', '_').exe"

$exePath = Join-Path $outPath $exeName

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host "ps2exe module not found. Installing for current user..." -ForegroundColor Yellow
    Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber
}

Import-Module ps2exe -ErrorAction Stop

# EXE 실행 시 $PSScriptRoot 가 임시경로로 바뀌기 때문에,
# UI와 코어 스크립트를 하나의 임시 파일로 병합한 뒤 컴파일한다.
$coreScript = Join-Path $root "pipeline_core_v3.ps1"
$uiScript = Join-Path $root "pipeline_ui_v3.ps1"
if (-not (Test-Path $coreScript)) {
    throw "Core script not found: $coreScript"
}
if (-not (Test-Path $uiScript)) {
    throw "UI script not found: $uiScript"
}

$entryContent = Get-Content -Path $sourceScript -Raw
$configContent = Get-Content -Path $configScript -Raw
$coreContent  = Get-Content -Path $coreScript  -Raw
$uiContent    = Get-Content -Path $uiScript    -Raw

$entryStripped = $entryContent `
    -replace '(?s)^\s*param\s*\(.*?\)\s*', '' `
    -replace '(?m)^\s*\.\s+"?\$PSScriptRoot\\pipeline_ui_v3\.ps1"?\s*$', '' `
    -replace '(?m)^\s*\.\s+"?\$PSScriptRoot\\pipeline_core_v3\.ps1"?\s*$', ''

$mergedContent = $configContent + "`r`n" + $uiContent + "`r`n" + $coreContent + "`r`n" + $entryStripped

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

$commonArgs["noConsole"] = $true

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

# powershell -ExecutionPolicy Bypass -File .\build_exe_v3.ps1