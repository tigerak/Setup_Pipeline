# Requirements Validation Runner 운영 문서

이 문서는 `requirements` 폴더의 검증/동기화 워크플로를 배포용으로 설명하기 위한 문서다. 핵심 목적은 다음과 같다.

- `common`/`cu11`/`cu12` manifest를 안전하게 검증한다.
- `validate`와 `sync lock` 사이의 차이를 명확히 구분한다.
- 배치 파일이 어떤 입력을 받고, 어떤 PowerShell 인자를 넘기는지 문서화한다.
- 실제 내부에서 어떤 절차가 실행되는지 설명한다.

---

## 1. 파일 구성

- `run_requirements_validation.bat`  
  메뉴 기반 런처. 사용자가 선택한 옵션을 해석해서 PowerShell 스크립트를 호출한다.

- `run_requirements_validation.ps1`  
  실제 로직이 전부 들어 있는 실행기. Conda 환경 생성, dependency 설치, wheelhouse 관리, import 검증을 수행한다.

- `common.in`  
  공통 베이스 온라인 검증 manifest.

- `common.lock.txt`  
  공통 베이스 오프라인/approved lock manifest.

- `cu11.in`  
  CUDA 11 전체 스택 검증 manifest.

- `cu11.lock.txt`  
  CUDA 11 approved lock manifest.

- `cu12.in`  
  CUDA 12 전체 스택 검증 manifest.

- `cu12.lock.txt`  
  CUDA 12 approved lock manifest.

- `wheelhouse/`  
  temp와 approved wheelhouse를 저장하는 디렉터리.

중요: `*.lock.txt`는 최종 오프라인 설치 기준 파일이다. 그래서 lock 파일에는 `--find-links`와 `--no-index`가 포함된다. 다만 approved wheelhouse를 온라인에서 재구성할 때는 스크립트가 lock 파일에서 이 오프라인 전용 지시문만 제거한 임시 파일을 사용해야 한다. 그래야 온라인에서는 artifact를 수집하고, 오프라인에서는 같은 lock 파일로만 설치할 수 있다.

---

## 2. 실행 경로: 배치 파일이 실제로 무엇을 하는가

사용자는 보통 배치 파일을 실행하는데, 실제로는 다음 순서를 따른다.

1. 메뉴 선택
   - 1: CU11 validate only
   - 2: CU11 sync lock only
   - 3: CU12 validate only
   - 4: CU12 sync lock only
   - 5: ALL validate only
   - 6: ALL sync lock only
   - 7: Custom options

2. 옵션값 수집
   - `TRACK` 값
   - `RUN_MODE` 값
   - `ENV_PREFIX`
   - `PYTHON_VERSION`
   - 삭제/재생성 플래그
   - wheelhouse 관련 플래그

3. `PS1_ARGS` 문자열 생성
   - 예시:
     ```bat
     set "PS1_ARGS=-ExecutionPolicy Bypass -File "%PS1_PATH%" -Track %TRACK% -EnvPrefix %ENV_PREFIX% -PythonVersion %PYTHON_VERSION%"
     ```

4. 추가 플래그 append
   - `-SyncLock`
   - `-RemoveValidationEnv`
   - `-BuildTempWheelCache`
   - `-ClearTempWheelCache`
   - `-BuildApprovedWheelhouse`
   - `-VerifyOfflineInstall`
   - `-RemoveOfflineEnv`

5. 최종 실행
   ```bat
   powershell -NoProfile -ExecutionPolicy Bypass %PS1_ARGS%
   ```

6. 종료 후 메뉴 복귀
   - `goto MENU`
   - 사용자는 다시 선택 가능

중요한 점은, 배치 파일 자체는 실제 검증 로직을 수행하지 않는다는 것이다. 배치 파일은 “실행 명령을 조립하고 호출하는 런처” 역할만 한다.

---

## 3. 실제 검증 로직이 일어나는 장소

실제 작업은 [run_requirements_validation.ps1](run_requirements_validation.ps1) 안에서 수행된다.

스크립트의 시작 부분은 다음과 같은 `param` 블록으로 구성된다.

```powershell
[CmdletBinding()]
param(
    [ValidateSet("cu11", "cu12", "all")]
    [string[]]$Track = @("cu11"),

    [string]$EnvPrefix = "req",
    [string]$PythonVersion = "3.10",

    [switch]$SyncLock,
    [switch]$BuildTempWheelCache,
    [switch]$BuildApprovedWheelhouse,
    [switch]$VerifyOfflineInstall,
    [string]$WheelOutputRoot = "",
    [string]$LogRoot = "",
    [switch]$RemoveValidationEnv,
    [switch]$ClearTempWheelCache,
    [switch]$ClearApprovedWheelhouse,
    [switch]$RemoveOfflineEnv,
    [switch]$SkipCreateEnv,
    [switch]$SkipInstall,
    [switch]$SkipValidation
)
```

이 값들은 다음 단계로 이어진다.

- `Track`: 검증 대상 트랙
- `EnvPrefix`: 환경 이름 접두어, 예: `req-cu11`
- `PythonVersion`: 생성할 Conda 환경의 Python 버전, 기본 `3.10`
- `SyncLock`: lock 기반 sync 모드 활성화
- `BuildTempWheelCache`: `.in` 기반 temp wheelhouse 생성
- `BuildApprovedWheelhouse`: approved wheelhouse 생성
- `VerifyOfflineInstall`: approved 기반 오프라인 설치 검증
- `RemoveValidationEnv`: 기존 validation 환경 삭제 후 재생성
- `ClearTempWheelCache`: temp 캐시 삭제
- `ClearApprovedWheelhouse`: approved wheelhouse 삭제
- `RemoveOfflineEnv`: 오프라인 검증 환경 삭제

---

## 4. 1번과 2번의 실제 차이

### 1번: CU11 validate only

배치 파일에서 `SET_PRESET cu11 validate`가 실행되면 다음 값이 설정된다.

- `TRACK = cu11`
- `RUN_MODE = validate`
- `SYNC_LOCK = no`
- `BUILD_TEMP_CACHE = yes`
- `REMOVE_VALIDATION_ENV = yes` (기본 확인 질문)

최종 인자 구성은 대략 다음과 같다.

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\Setup_Pipeline\requirements\run_requirements_validation.ps1" -Track cu11 -EnvPrefix req -PythonVersion 3.10 -RemoveValidationEnv -BuildTempWheelCache -ClearTempWheelCache
```

이 모드는 실제로 다음을 한다.

- `req-cu11` 환경 생성 또는 재생성
- `common.in` + `cu11.in` 설치
- import 검증
- CUDA 관련 검증
- 로그 기록
- wheelhouse temp 캐시 갱신

### 2번: CU11 sync lock only

배치 파일에서 `SET_PRESET cu11 sync`가 실행되면 다음 값이 설정된다.

- `TRACK = cu11`
- `RUN_MODE = sync`
- `SYNC_LOCK = yes`
- `BUILD_APPROVED_WHEELHOUSE = yes`
- `VERIFY_OFFLINE = yes`
- `REMOVE_OFFLINE_ENV = yes`

최종 인자 구성은 대략 다음과 같다.

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\Setup_Pipeline\requirements\run_requirements_validation.ps1" -Track cu11 -EnvPrefix req -PythonVersion 3.10 -SyncLock -RemoveValidationEnv -BuildApprovedWheelhouse -VerifyOfflineInstall -RemoveOfflineEnv
```

이 모드는 실제로 다음을 한다.

- `common.in`과 `cu11.in`을 기준으로 온라인에서 approved wheelhouse를 먼저 재생성
- approved wheelhouse 안에 실제로 모인 artifact 목록을 기준으로 `common.lock.txt`와 `cu11.lock.txt`를 생성
- offline 검증용 env 생성
- 방금 생성한 lock 파일과 approved artifact만 사용해서 오프라인 설치 검증 수행

이 과정에서 sync 모드는 온라인 env에 패키지를 설치해서 검증하지 않는다. 온라인 단계의 목적은 artifact 수집뿐이고, 실제 설치 검증은 lock 기반 오프라인 단계에서만 수행한다.

즉 sync 모드의 기준은 `pip freeze`가 아니라 approved wheelhouse의 실제 artifact 집합이다. 온라인 단계는 `.in`이 담당하고, 오프라인 단계는 그 결과물로 생성된 `*.lock.txt`가 담당한다.

즉, 1번은 “검증 중심”, 2번은 “lock 반영 + approved 재생성 중심”이다.

---

## 5. 내부 동작 상세

PowerShell 스크립트는 다음 절차를 따른다.

### 5.1. 로그 초기화

- 로그 파일 이름 생성
- `requirements/logs`에 transcript 및 sidecar 로그 저장
- 실행 경로와 선택값 기록

### 5.2. Conda 환경 존재 여부 확인

스크립트는 `Test-CondaEnvironmentExists`를 사용해 이름이 이미 있는지 판단한다.

핵심 아이디어는 전체 `conda env list --json`을 파싱하지 않고, 특정 환경 이름을 직접 확인하는 것이다.

```powershell
$probeArguments = @(
    "run",
    "-n",
    $EnvironmentName,
    "python",
    "-c",
    "import sys; print(sys.executable)"
)
```

이 방식은 목적 환경만 확인하고, 불필요한 환경 목록 파싱을 피한다.

### 5.3. Conda 호출 래퍼

스크립트는 모든 `conda` 명령을 배열 기반으로 호출한다.

```powershell
& conda @Arguments
```

이 방식이 중요한 이유는 다음과 같다.

- `-n`, `--live-stream` 등의 옵션이 문자열 결합으로 깨지지 않는다.
- PowerShell의 파라미터 바인딩 오작동을 피한다.
- 오래된 세션/옛 함수가 남아 있을 때 생기는 문제를 줄인다.

### 5.4. 환경 생성 및 삭제

- `New-CondaEnvironment`:
  ```powershell
  Invoke-Conda -Arguments @("create", "-n", $EnvironmentName, ("python={0}" -f $RequestedPythonVersion), "-y")
  ```

- `Remove-CondaEnvironment`:
  ```powershell
  Invoke-Conda -Arguments @("env", "remove", "-n", $EnvironmentName, "-y")
  ```

### 5.5. 설치 과정

스크립트는 일반적으로 다음 흐름으로 진행한다.

1. Conda env 준비
2. `pip install --upgrade pip`
3. manifest install
4. 검증 스크립트 실행
5. 필요하면 wheelhouse 생성
6. 결과 로그 저장

### 5.6. 검증 단계

검증은 보통 아래 항목을 대상으로 한다.

- 공통 import
- FastAPI 앱 부트스트랩
- torch import
- CUDA availability 확인
- ONNX, ONNX Runtime, pycuda 계열 import
- provider 목록 확인

결과값은 로그 파일과 콘솔에 같이 출력된다.

---

## 6. wheelhouse 관리 방식

스크립트는 `temp`와 `approved`를 분리해서 관리한다.

- `temp`: 검증용 staging 캐시
- `approved`: 릴리즈/오프라인 배포용 최종 저장소

예시 구조:

```text
requirements/
  wheelhouse/
    temp/
      common/
      cu11/
      cu12/
    approved/
      common/
      cu11/
      cu12/
```

### validate only

- `.in` 기준으로 temp wheelhouse를 갱신한다.
- approved는 건드리지 않는다.

### sync lock only

- `.lock.txt` 기준으로 approved wheelhouse를 다시 만든다.
- temp는 건드리지 않는다.

---

## 7. 로그 규칙

실행 로그는 두 종류로 나뉜다.

1. `run_requirements_validation.ps1` transcript log  
   실제 설치, 다운로드, 검증 출력이 기록된다.

2. `run_requirements_validation.bat` launcher log  
   메뉴 선택값, 플래그, 최종 실행 명령이 기록된다.

로그 위치는 보통 다음 경로이다.

```text
requirements/logs/
```

---

## 8. 배포용 팁: 안정적인 실행권장 방법

운영 환경에서 안정적으로 쓰기 위해서는 PowerShell 프로필 로딩을 막고 새 프로세스에서 실행하는 것이 좋다.

권장 실행 방식:

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\Setup_Pipeline\requirements\run_requirements_validation.ps1" -Track cu11 -EnvPrefix req -PythonVersion 3.10 -RemoveValidationEnv
```

이렇게 하면 오래된 함수 정의, 사용자 프로필 alias, Conda init 관련 설정이 섞이지 않아 에러를 줄인다.

---

## 9. 빠른 운영 예시

### CUDA 11 즉시 검증

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\requirements\run_requirements_validation.ps1 -Track cu11 -EnvPrefix req -PythonVersion 3.10 -RemoveValidationEnv -BuildTempWheelCache
```

### CUDA 11 lock sync + approved wheelhouse 생성

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\requirements\run_requirements_validation.ps1 -Track cu11 -EnvPrefix req -PythonVersion 3.10 -SyncLock -BuildApprovedWheelhouse -VerifyOfflineInstall -RemoveOfflineEnv
```

### CUDA 12 validate only

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\requirements\run_requirements_validation.ps1 -Track cu12 -EnvPrefix req -PythonVersion 3.10 -RemoveValidationEnv -BuildTempWheelCache
```

---

## 10. 운영 원칙 요약

- `.in`은 검증용 manifest다.
- `.lock.txt`는 approved lock manifest다.
- `validate`는 `.in` 기준 검증 중심이다.
- `sync lock`은 `.lock.txt` 반영과 approved wheelhouse 생성 중심이다.
- 실제 실행은 배치 파일이 아니라 PowerShell 스크립트에서 수행된다.
- `-NoProfile` 실행을 권장한다.
- 로그와 wheelhouse 상태를 항상 확인한 뒤 next step을 결정한다.

이 문서는 배포 환경에서 운영자가 “무엇을 누르고, 어떤 단계가 실행되며, 어떤 결과가 남는지” 이해할 수 있도록 정리한 운영 문서다.
