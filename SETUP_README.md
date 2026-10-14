# setup_261013.bat 실행 흐름

이 문서는 `setup_261013.bat` 를 시작점으로 했을 때 실제로 어떤 순서로 설치가 진행되는지 정리한 문서다.

## 1. 시작점

사용자가 `setup_261013.bat` 를 실행하면 먼저 관리자 권한을 확인한다.

- 관리자 권한이 아니면 즉시 종료한다.
- 관리자 권한이면 현재 폴더를 기준으로 `src\pipeline_entry.ps1` 를 숨김 PowerShell로 실행한다.

즉, `setup_261013.bat` 자체는 설치 로직을 직접 수행하지 않고,
PowerShell 설치 파이프라인을 띄우는 런처 역할만 한다.

## 2. pipeline_entry.ps1 역할

`pipeline_entry.ps1` 는 다음 순서로 동작한다.

1. `local_config.ps1` 를 우선 읽는다.
2. `src\pipeline_config.ps1` 를 읽어 공용 기본값을 로드한다.
3. 로컬 설정이 있으면 `CondaEnvVer`, `EvaltoolsVer`, `PackageSourceRoot`, `RemotePackageSourceRoot` 같은 값을 덮어쓴다.
4. `pipeline_ui.ps1` 와 `pipeline_core.ps1` 를 로드한다.
5. UI 를 초기화한 뒤 `Invoke-PipelineSetup` 을 호출한다.

## 3. pipeline_core.ps1 실제 단계

실제 설치와 검증은 `pipeline_core.ps1` 에서 수행된다.

현재 흐름은 요약하면 다음과 같다.

1. 사전 점검
   - 관리자 권한 확인
   - 7-Zip 설치 파일 확보
   - NVIDIA 드라이버, CUDA 관련 사전 상태 확인

2. Miniconda 단계
   - `Miniconda3-py310_24.9.2-0-Windows-x86_64.exe` 로 Miniconda 설치
   - 설치 전후로 기존 `C:\ProgramData\miniconda3` 정리

3. TensorRT 단계
   - 표준 TensorRT 경로 중 적절한 버전을 선택
   - `PATH` 와 `TRT_PATH` 를 맞춘 뒤 설치/검증에 사용

4. CUDA / cuDNN 단계
   - CUDA 버전에 맞는 cuDNN, zlib 등 의존 파일 반영

5. Python env 단계
   - `conda create --offline -n visionAI python=3.10 -y`
   - `requirements\wheelhouse\approved\common` 과 `cu11` 또는 `cu12` 를 사용해 오프라인 pip 설치
   - lock 파일 기준으로만 설치 검증

6. Eval Tools 단계
   - `Eval_Tools_{version}.zip` 을 배포 경로로 반영
   - `eval_tools.bat` 기준 실행 흐름을 유지
   - 바로가기 생성 스크립트가 있는 경우 이를 통해 shortcut 을 만들 수 있다

## 4. 실행 경로 요약

```text
setup_261013.bat
  -> pipeline_entry.ps1
    -> pipeline_ui.ps1
    -> pipeline_core.ps1
      -> Miniconda 설치
      -> TensorRT / CUDA / cuDNN 준비
      -> conda offline env 생성
      -> approved wheelhouse 기반 pip 설치
      -> Eval Tools 배포
```

## 5. 로컬 설정에서 중요한 값

`local_config.ps1` 에서 주로 확인해야 하는 값은 다음이다.

- `PackageSourceRoot`
- `RemotePackageSourceRoot`
- `CondaEnvVer`
- `EvaltoolsVer`

특히 `PackageSourceRoot` 는 실제 설치가 참조하는 로컬 패키지 캐시 루트이고,
`RemotePackageSourceRoot` 는 로컬에 없는 파일을 sync 해오는 원격 보관소다.

## 6. 운영상 주의점

- `setup_261013.bat` 는 관리자 권한이 필요하다.
- `python.exe`, `pythonw.exe`, `conda.exe`, `trtexec.exe` 같은 프로세스가 남아 있으면 Miniconda/TensorRT 삭제나 재설치가 실패할 수 있다.
- `pyexpat.pyd`, `nvinfer_10.dll` 같은 파일은 다른 프로세스가 로드 중이면 삭제가 거부될 수 있다.
- 오프라인 설치는 `wheelhouse` 와 `lock.txt` 가 서로 맞아야 한다.

## 7. 이 문서를 읽는 기준

이 문서는 "새 설치 구조"를 설명한다.
기존처럼 완성된 conda env 압축본을 복원하는 흐름이 아니라,
Miniconda + local pkgs cache + approved wheelhouse 조합으로 재현 가능한 설치를 목표로 한다.