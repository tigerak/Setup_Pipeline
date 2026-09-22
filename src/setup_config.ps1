# ============================================================================
# setup_config.ps1 - 대화형 사용자 설정 및 GUI 시작
# ============================================================================
# 사용자에게 3개 설정값(버전 2개 + 패키지 소스)을 물어본 후
# local_config.ps1에 저장하고 GUI를 자동으로 시작합니다.

param(
    [string]$PipelineEntry = ""
)

Set-StrictMode -Version Latest

$SrcDir = Split-Path -Parent $PSCommandPath
$LocalConfigPath = Join-Path $SrcDir "local_config.ps1"
$PipelineEntryPath = if ([string]::IsNullOrWhiteSpace($PipelineEntry)) {
    Join-Path $SrcDir "pipeline_entry.ps1"
} else {
    $PipelineEntry
}

# ============================================================================
# 기본 설정값 (템플릿)
# ============================================================================

$defaultConfig = @{
    DefaultCondaEnvVer = "260909"
    DefaultEvaltoolsVer = "260801"
    PackageSourceRoot = "D:\Setup_Pipeline"
}

# ============================================================================
# local_config.ps1 로드 또는 생성
# ============================================================================

if (-not (Test-Path $LocalConfigPath)) {
    Write-Host "[INFO] Creating default config..." -ForegroundColor Cyan
    $currentConfig = $defaultConfig
    $isNew = $true
} else {
    try {
        . $LocalConfigPath
        $currentConfig = @{
            DefaultCondaEnvVer = $script:LocalConfig.DefaultCondaEnvVer
            DefaultEvaltoolsVer = $script:LocalConfig.DefaultEvaltoolsVer
            PackageSourceRoot = $script:LocalConfig.PackageSourceRoot
        }
        $isNew = $false
    } catch {
        Write-Host "[WARNING] Failed to load config, using defaults" -ForegroundColor Yellow
        $currentConfig = $defaultConfig
        $isNew = $true
    }
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "Pipeline Setup - Local Configuration" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# 사용자 입력 수집 (3개 항목만)
# ============================================================================

$configItems = @(
    @{ Key = "DefaultCondaEnvVer"; Display = "Conda Environment Version" },
    @{ Key = "DefaultEvaltoolsVer"; Display = "Eval Tools Version" },
    @{ Key = "PackageSourceRoot"; Display = "Package Source Root" }
)

$modified = $false

foreach ($item in $configItems) {
    $key = $item.Key
    $currentValue = $currentConfig[$key]
    
    Write-Host "$($item.Display):" -ForegroundColor Yellow
    Write-Host "  Current: $currentValue" -ForegroundColor Gray
    Write-Host "  Enter new value (or press Enter to keep):"
    
    $userInput = Read-Host "  "
    
    if (-not [string]::IsNullOrWhiteSpace($userInput)) {
        $currentConfig[$key] = $userInput
        Write-Host "  [OK] Updated to: $userInput" -ForegroundColor Green
        $modified = $true
    } else {
        Write-Host "  [KEEP] Using: $currentValue" -ForegroundColor Gray
    }
    Write-Host ""
}

# ============================================================================
# 수정된 설정을 local_config.ps1에 저장
# ============================================================================

if ($modified -or $isNew) {
    Write-Host "Saving configuration..." -ForegroundColor Cyan
    
    $content = @"
# ============================================================================
# local_config.ps1 - 사용자 정의 설정
# ============================================================================

`$script:LocalConfig = [pscustomobject]@{
    DefaultCondaEnvVer = "$($currentConfig['DefaultCondaEnvVer'])"
    DefaultEvaltoolsVer = "$($currentConfig['DefaultEvaltoolsVer'])"
    PackageSourceRoot = "$($currentConfig['PackageSourceRoot'])"
}
"@
    
    $content | Out-File -FilePath $LocalConfigPath -Encoding UTF8 -Force
    Write-Host "[OK] Configuration saved" -ForegroundColor Green
} else {
    Write-Host "[INFO] No changes made" -ForegroundColor Gray
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "Starting Pipeline Setup GUI..." -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# GUI 시작 (같은 프로세스에서 실행)
# ============================================================================

if (-not (Test-Path $PipelineEntryPath)) {
    Write-Host "[ERROR] Pipeline entry script not found: $PipelineEntryPath" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

# pipeline_entry.ps1 직접 실행 (같은 PowerShell 프로세스)
& $PipelineEntryPath

Write-Host ""
Write-Host "Setup complete. Press Enter to exit." -ForegroundColor Cyan
Read-Host ""
