# ============================================================================
# local_config.ps1 - 사용자 로컬 설정 파일
# ============================================================================

$script:LocalConfig = [pscustomobject]@{
    # Conda 환경 버전 스탬프
    CondaEnvVer = "261013"
    # Evaltools 버전 스탬프
    EvaltoolsVer = "261014"
    
    # 로컬 캐시 루트: 실제 설치와 wheelhouse, requirements 파일은 로컬 경로를 사용한다.
    # 원격 공유는 원본 보관소로만 쓰고, 로컬에 없는 파일만 동기화한다.
    PackageSourceRoot = "D:\visionAI\Setup_Pipeline"
    # 원격 보관소: 로컬 캐시에 없는 파일만 동기화한다.
    RemotePackageSourceRoot = "D:\Setup_Pipeline"
    # RemotePackageSourceRoot = "\\12.49.149.7\setup_pipeline"
}
