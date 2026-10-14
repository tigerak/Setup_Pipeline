# 오프라인 Miniconda 기반 Python 3.10 가상환경 생성 가이드

이 문서는 현재 `setup_261013.bat` → `pipeline_entry.ps1` → `pipeline_core.ps1` 흐름에서 사용하는
오프라인 설치 전제를 정리한다.

핵심은 `visionAI_cu11_*.7z`, `visionAI_cu12_*.7z` 같은 완성형 conda 환경 압축본을 쓰는 대신,
오프라인 Miniconda 설치 후 `python=3.10` 빈 conda 환경을 만들고,
그 위에 `wheelhouse` 기반으로 패키지를 설치하는 방식이다.

별도로 `setup_261013.bat`는 관리자 권한 확인 후 PowerShell 진입 스크립트를 숨김 실행만 하며,
실제 설치 단계는 `pipeline_core.ps1` 안에서 순차적으로 수행된다.

## 핵심 결론

- 현재 설치 진입점은 `setup_261013.bat` 이다.
- `setup_261013.bat` 는 관리자 권한을 확인한 뒤 `pipeline_entry.ps1` 을 숨김으로 실행한다.
- `pipeline_entry.ps1` 는 로컬 설정과 공용 설정을 읽고, `pipeline_core.ps1` 을 호출해 실제 설치 UI와 단계를 수행한다.
- 현재 사용 중인 `Miniconda3-py310_24.9.2-0-Windows-x86_64.exe` 설치 파일은 Python 3.10 계열 Miniconda 설치본이다.
- 이 설치 파일로 Miniconda를 설치하면, 설치 직후 Miniconda 자체 실행에 필요한 conda 패키지들이 `C:\ProgramData\miniconda3\pkgs` 아래에 풀린다.
- 따라서 대상 PC가 완전 오프라인이어도, 필요한 conda 패키지가 `pkgs` 캐시에 이미 존재하면 `conda create --offline -n <env> python=3.10 -y` 로 Python 3.10 가상환경을 만들 수 있다.
- 이후 실제 애플리케이션 패키지는 `pip install --no-index --find-links ... -r ...` 방식으로 `wheelhouse` 에서 오프라인 설치하면 된다.

즉, 앞으로의 설치 구조는 다음처럼 가져갈 수 있다.

1. Miniconda 설치
2. Miniconda 로컬 `pkgs` 캐시를 사용해 `python=3.10` 빈 환경 생성
3. `requirements\wheelhouse\approved\common` 와 `requirements\wheelhouse\approved\cu11` 또는 `cu12` 를 사용해 오프라인 `pip install`

## 왜 가능한가

Conda는 환경 생성 시 항상 인터넷에서 패키지를 받아야 하는 것이 아니다.

- 온라인 생성: channel 에서 패키지를 조회하고 다운로드한다.
- 오프라인 생성: 로컬 package cache 와 로컬 metadata 로만 환경을 해결한다.

이번 검증에서 실제로 아래 명령을 실행해 오프라인 생성이 성공했다.

```powershell
conda create --offline -n req-offline-probe python=3.10 -y
```

성공한 이유는 현재 시스템의 `C:\ProgramData\miniconda3\pkgs` 아래에 다음과 같은 패키지들이 이미 있었기 때문이다.

- `python-3.10.21-...`
- `pip-26.2.1-...`
- `setuptools-83.0.0-...`
- `wheel-0.47.0-...`
- `openssl-3.5.8-...`
- `sqlite-3.53.4-...`
- `vc14_runtime-14.44.35208-...`
- 그 외 Python 3.10 기본 환경 구성에 필요한 런타임 패키지

즉, 오프라인 생성의 핵심은 "Miniconda 설치 파일이 Python 3.10 계열 설치본이다" 와 "설치 후 local pkgs cache 가 존재한다" 의 조합이다.

## 주의할 점

`Miniconda3-py310_24.9.2-0-Windows-x86_64.exe` 를 쓴다고 해서,
모든 오프라인 PC에서 무조건 `python=3.10` 환경 생성이 보장되는 것은 아니다.

다음 조건이 만족되어야 한다.

### 1. 대상 PC에 Miniconda가 설치되어 있어야 한다

- 기본 경로는 `C:\ProgramData\miniconda3`
- `conda.exe` 가 정상 실행 가능해야 한다.

### 2. `pkgs` 캐시에 필요한 conda 패키지가 있어야 한다

오프라인 생성 시 conda는 로컬 캐시에서 다음 계열 패키지를 찾는다.

- `python`
- `pip`
- `setuptools`
- `wheel`
- `openssl`
- `sqlite`
- `vc`, `vc14_runtime`, `vs2015_runtime`
- `ucrt`
- `zlib`, `xz`, `tk`, `tzdata` 등 기본 런타임

이 캐시가 비어 있거나 필요한 버전이 없으면 `--offline` 생성은 실패한다.

### 3. 완전 신규 오프라인 PC라면 installer 외에 pkgs 보존 전략이 필요할 수 있다

보통은 Miniconda 설치 과정 자체가 기본 패키지를 `pkgs` 에 남기므로,
동일 설치본을 사용한 표준 설치에서는 바로 `python=3.10` env 생성이 되는 경우가 많다.

다만 아래 상황은 별도 확인이 필요하다.

- 설치 후 `pkgs` 정리 스크립트를 따로 돌린 경우
- 설치본과 다른 Python 버전 env 를 만들려는 경우
- channel metadata 또는 package cache 가 손상된 경우

## 권장 설치 구조

기존 방식:

- `visionAI_cu11_{version}.7z`
- `visionAI_cu12_{version}.7z`

새 방식:

1. `Miniconda3-py310_24.9.2-0-Windows-x86_64.exe` 설치
2. `conda create --offline -n visionAI python=3.10 -y`
3. CUDA 버전에 맞는 오프라인 requirements 설치

현재 `setup_261013.bat` 기준의 실제 배포 흐름도 이 구조를 따른다.
즉, 상위 실행기는 설치를 시작하는 진입점일 뿐이고, 실제 환경 생성과 패키지 설치는 Miniconda + local pkgs cache + approved wheelhouse 조합으로 진행된다.

예시:

### CUDA 11 오프라인 설치

```powershell
conda create --offline -n visionAI python=3.10 -y
conda run --live-stream -n visionAI python -m pip install --progress-bar on --upgrade pip
conda run --live-stream -n visionAI python -m pip install --progress-bar on --no-index --find-links D:\Setup_Pipeline\requirements\wheelhouse\approved\common --find-links D:\Setup_Pipeline\requirements\wheelhouse\approved\cu11 -r D:\Setup_Pipeline\requirements\cu11.lock.txt
```

### CUDA 12 오프라인 설치

```powershell
conda create --offline -n visionAI python=3.10 -y
conda run --live-stream -n visionAI python -m pip install --progress-bar on --upgrade pip
conda run --live-stream -n visionAI python -m pip install --progress-bar on --no-index --find-links D:\Setup_Pipeline\requirements\wheelhouse\approved\common --find-links D:\Setup_Pipeline\requirements\wheelhouse\approved\cu12 -r D:\Setup_Pipeline\requirements\cu12.lock.txt
```

## 설치 로직에 반영할 내용

파이프라인 설치 스크립트에서 환경 압축본 패턴을 직접 복원하는 대신,
다음 단계로 바꾸는 것이 맞다.

1. Miniconda 존재 확인
2. `conda create --offline -n <env> python=3.10 -y` 실행
3. `requirements\wheelhouse\approved\common` 와 대상 트랙 wheelhouse 존재 확인
4. 대상 lock 파일로 `pip install --no-index --find-links ... -r ...` 실행
5. 필요 시 import 검증 실행

즉, 환경 배포 단위는 더 이상 "완성된 conda env 압축본" 이 아니라,
"Miniconda + local conda pkgs + approved wheelhouse + lock 파일" 조합이 된다.

## 운영상 장점

- 환경 압축본을 버전별로 따로 관리하지 않아도 된다.
- `.lock.txt` 와 `approved` wheelhouse 기준으로 설치 구성을 재현할 수 있다.
- `requirements\run_requirements_validation.ps1` 에서 검증한 오프라인 설치 경로와 설치 파이프라인이 일치한다.
- CUDA 11, CUDA 12 모두 같은 설치 프레임을 유지할 수 있다.

## 운영상 전제

- `approved\common`, `approved\cu11`, `approved\cu12` 는 사전에 sync 되어 있어야 한다.
- 대상 PC의 Miniconda `pkgs` 캐시에 Python 3.10 기본 env 생성에 필요한 conda 패키지가 있어야 한다.
- 오프라인 pip 설치는 `lock.txt` 기준으로만 수행해야 한다.

## 현재 검증 결과

현재 작업 환경에서는 아래가 확인되었다.

- `conda create --offline -n req-offline-probe python=3.10 -y` 성공
- 이후 probe 환경 삭제 성공
- 별도로 `requirements\run_requirements_validation.ps1` 경로를 통해 `cu12` approved wheelhouse 기반 오프라인 설치와 검증 성공

따라서 이 프로젝트는 "Miniconda 설치 후 로컬 pkgs 기반 Python 3.10 env 생성 + approved wheelhouse 기반 오프라인 pip 설치" 구조로 전환 가능하다.

## 참고 문서

- `setup_261013.bat` 실행 흐름: [SETUP_261013_README.md](SETUP_261013_README.md)
- Eval Tools 런처: [eval_test/EVAL_TOOL/README.md](eval_test/EVAL_TOOL/README.md)