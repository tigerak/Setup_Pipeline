# Requirements 운영 가이드

이 폴더는 `api`를 베이스 manifest로 두고, 실제 설치/검증은 `cu11` 또는 `cu12` 전체 스택 단위로 관리한다.

## 파일 역할

- `api.in`: 공통 API 베이스 온라인 검증용 manifest
- `api.lock.txt`: 공통 API 베이스 오프라인 설치용 manifest
- `cu11.in`: CUDA 11 전체 스택 온라인 검증용 manifest. 내부적으로 `api.in`을 포함한다.
- `cu11.lock.txt`: CUDA 11 전체 스택 오프라인 설치용 manifest. 내부적으로 `api.lock.txt`를 포함한다.
- `cu12.in`: CUDA 12 전체 스택 온라인 검증용 manifest. 내부적으로 `api.in`을 포함한다.
- `cu12.lock.txt`: CUDA 12 전체 스택 오프라인 설치용 manifest. 내부적으로 `api.lock.txt`를 포함한다.
- `OFFLINE_MINICONDA_ENV.md`: Miniconda 설치본과 로컬 `pkgs` 캐시를 사용해 오프라인으로 `python=3.10` env 를 만든 뒤, approved wheelhouse 로 패키지를 설치하는 운영 가이드

별도 `common` 계층은 두지 않는다. 이전에 `common`에 있던 단일 패키지는 각 CUDA 트랙 manifest 안에 직접 적는다.

## 기본 원칙

- 먼저 `.in` 파일만 수정한다.
- 실제 검증 대상은 `cu11` 또는 `cu12` 전체 스택이다.
- `cu11` 또는 `cu12`를 검증하면 그 안에 포함된 `api`도 같이 검증된다.
- 검증과 `.lock.txt` 반영은 분리해서 수행한다.
- 검증 성공 직후 자동 반영하지 않고, 결과 확인 후 별도 sync 단계에서 반영한다.
- 오프라인 설치에는 `.lock.txt`만 사용한다.

## 표준 절차

1. `api.in`, `cu11.in`, `cu12.in` 중 필요한 파일을 수정한다.
2. 대상 트랙의 깨끗한 테스트 환경을 만든다.
3. 온라인 환경에서 `.in` 기준으로 설치한다.
4. API import, FastAPI 부트스트랩, PyTorch CUDA, ONNX 계열 import를 검증한다.
5. 결과를 확인한다.
6. 승인할 때 `api.lock.txt`와 대상 트랙의 `.lock.txt`를 sync 한다.
7. 검증 단계에서는 `.in` 기준으로 `wheelhouse\temp`를 갱신한다.
8. 승인된 `.lock.txt` 기준으로 `wheelhouse\approved`를 새로 만든다.
9. 필요하면 `approved` 기준으로 오프라인 설치 검증을 수행한다.

## 파일별 운영 규칙

### `api.in` -> `api.lock.txt`

- `api`는 `cu11`, `cu12`가 항상 함께 포함하는 베이스 레이어다.
- 최소 검증 항목은 다음과 같다.
- 패키지 설치 성공
- `fastapi`, `uvicorn`, `pydantic`, `requests` import 성공
- FastAPI 앱 부트스트랩 성공
- `api` 변경은 `cu11` 또는 `cu12` 실제 검증이 끝난 뒤 sync 한다.

### `cu11.in` -> `cu11.lock.txt`

- `cu11`은 `api`와 CUDA 11 GPU 스택 전체를 함께 검증한다.
- 최소 검증 항목은 다음과 같다.
- 패키지 설치 성공
- API import 및 부트스트랩 성공
- `torch`, `torchvision` import 성공
- `torch.cuda.is_available()` 성공
- `onnxruntime-gpu`, `pycuda`, `onnx`, `onnxsim`, `onnx2torch` import 성공
- `onnxruntime.get_available_providers()` 확인

### `cu12.in` -> `cu12.lock.txt`

- `cu12`는 `api`와 CUDA 12 GPU 스택 전체를 함께 검증한다.
- 최소 검증 항목은 다음과 같다.
- 패키지 설치 성공
- API import 및 부트스트랩 성공
- `torch`, `torchvision` import 성공
- `torch.cuda.is_available()` 성공
- `onnxruntime-gpu`, `pycuda`, `onnx`, `onnxsim`, `onnx2torch` import 성공
- `onnxruntime.get_available_providers()` 확인

## TensorRT 처리 원칙

- TensorRT는 여기서 자동 검증하지 않는다.
- 현재 구조에서 TensorRT는 `pip install`만으로 끝나는 전제가 아니라, 별도 패키지 배치나 `pkgs` 기반 설치가 필요한 경우가 있다.
- 따라서 이 스크립트는 `torch`와 CUDA 계열 검증까지만 기본 범위로 본다.
- manifest 안의 `# tensorrt=...` 주석은 호환성 메모로만 취급한다.

## 실제 테스트 명령 예시

아래 예시는 Windows PowerShell 기준이다.

### CUDA 11 전체 스택 테스트 예시

```powershell
conda create -n req-cu11 python=3.10 -y
conda run --live-stream -n req-cu11 python -m pip install --progress-bar on --upgrade pip
conda run --live-stream -n req-cu11 python -m pip install --progress-bar on -r requirements\cu11.in
conda run --live-stream -n req-cu11 python -c "import fastapi, uvicorn, pydantic, requests; print(fastapi.__version__, uvicorn.__version__, pydantic.__version__, requests.__version__)"
conda run --live-stream -n req-cu11 python -c "from fastapi import FastAPI; app = FastAPI(); print('api ok')"
conda run --live-stream -n req-cu11 python -c "import torch, torchvision; print(torch.__version__, torchvision.__version__); print('cuda_available=', torch.cuda.is_available()); print('cuda_version=', torch.version.cuda); assert torch.cuda.is_available()"
conda run --live-stream -n req-cu11 python -c "import onnx, onnxsim, onnx2torch, pycuda, onnxruntime as ort; print(onnx.__version__, onnxsim.__version__, onnx2torch.__version__, ort.__version__); print(ort.get_available_providers())"
```

### CUDA 12 전체 스택 테스트 예시

```powershell
conda create -n req-cu12 python=3.10 -y
conda run --live-stream -n req-cu12 python -m pip install --progress-bar on --upgrade pip
conda run --live-stream -n req-cu12 python -m pip install --progress-bar on -r requirements\cu12.in
conda run --live-stream -n req-cu12 python -c "import fastapi, uvicorn, pydantic, requests; print(fastapi.__version__, uvicorn.__version__, pydantic.__version__, requests.__version__)"
conda run --live-stream -n req-cu12 python -c "from fastapi import FastAPI; app = FastAPI(); print('api ok')"
conda run --live-stream -n req-cu12 python -c "import torch, torchvision; print(torch.__version__, torchvision.__version__); print('cuda_available=', torch.cuda.is_available()); print('cuda_version=', torch.version.cuda); assert torch.cuda.is_available()"
conda run --live-stream -n req-cu12 python -c "import onnx, onnxsim, onnx2torch, pycuda, onnxruntime as ort; print(onnx.__version__, onnxsim.__version__, onnx2torch.__version__, ort.__version__); print(ort.get_available_providers())"
```

## wheelhouse 구조

`wheelhouse`는 다음 두 단계로 관리한다.

- `wheelhouse\temp\api`, `wheelhouse\approved\api`: `api` 전용 staging/approved 저장소
- `wheelhouse\temp\cu11`, `wheelhouse\temp\cu12`: 검증용 staging 캐시
- `wheelhouse\approved\cu11`, `wheelhouse\approved\cu12`: 최종 오프라인 설치용 저장소

동작 원칙은 다음과 같다.

- `temp`는 다운로드 시간을 줄이기 위한 staging 캐시다.
- `api`는 `api.in`/`api.lock.txt` 전용 wheelhouse다.
- `validate only` 단계는 `.in` 기준으로 `temp\<track>`를 갱신한다.
- `validate only` 단계에서 `api`도 별도로 `temp\api`에 갱신된다.
- `sync lock only` 단계는 `.lock.txt`를 반영한 뒤 `approved\<track>`만 다시 만든다.
- `sync lock only` 단계에서 `api`도 별도로 `approved\api`에 반영된다.
- 온라인 검증용 conda 환경 삭제 여부와 `temp` 삭제 여부는 별도로 선택한다.
- 기본값은 `온라인 검증 env 삭제 = Y`이다.
- 오프라인 검증용 conda 환경 삭제 여부와 `approved` 삭제 여부도 별도로 선택한다.
- 기본값은 `오프라인 검증 env 삭제 = Y`, `approved 삭제 = Y`이다.
- 환경 삭제를 선택하지 않으면 기존 conda 환경은 자동 재사용한다.
- `approved`는 `temp`에 모인 파일만 사용해서 lock 기준으로 정확히 다시 구성한다.

## 자동 실행 스크립트 사용법

이 폴더에는 다음 두 실행 파일이 있다.

- `run_requirements_validation.ps1`: 실제 검증, sync, wheelhouse, 오프라인 검증을 수행하는 스크립트
- `run_requirements_validation.bat`: 메뉴 기반 런처

### 배치 런처에서 선택하는 항목

- 대상 트랙 선택: `cu11`, `cu12`, `all`
- 실행 모드 선택: `validate only`, `sync lock only`
- 온라인 검증 env 삭제 여부
- `validate only`에서 `.in` 기반 `temp` 캐시 갱신 여부
- `temp` 캐시 삭제 여부
- `sync lock only`에서 `approved` 재구성 여부
- `approved` 저장소 삭제 여부
- `approved` 기준 오프라인 설치 검증 여부
- 오프라인 검증 env 삭제 여부

### 메뉴 동작 방식

- `validate only`: 대상 `.in`으로 설치와 검증만 수행한다.
- `validate only`에서 wheelhouse를 켜면 `api`와 대상 트랙의 `.in` 기준으로 각각 `temp`를 갱신한다. `approved`는 건드리지 않는다.
- `sync lock only`: 설치와 검증 없이 `api.lock.txt`와 대상 트랙 `.lock.txt`를 반영한다.
- `sync lock only`에서 wheelhouse를 켜면 `api`와 대상 트랙의 `.lock.txt` 기준으로 각각 `approved`를 다시 만든다. `temp`는 건드리지 않는다.
- `cu11` 또는 `cu12` 검증 시 API 검증은 항상 같이 수행된다.
- CUDA 검증은 항상 수행된다.
- TensorRT 검증은 수행하지 않는다.
- 온라인 검증 env 삭제와 `temp` 삭제는 서로 독립이다.
- `Verify offline installation`을 선택하면 `approved\api`와 대상 트랙 `approved`를 함께 사용해서 별도 오프라인 환경에 다시 설치 후 같은 검증을 반복한다.
- 내부적으로 `conda run --live-stream`과 `pip --progress-bar on`을 사용하므로, 다운로드와 설치 진행이 콘솔에 실시간으로 표시된다.
- Y/N 질문은 자동으로 선택되지 않는다. 엔터만 누르면 표시된 기본값이 적용된다.

### PowerShell 직접 실행 예시

```powershell
 powershell -ExecutionPolicy Bypass -File .\requirements\run_requirements_validation.ps1 -Track cu11 -RemoveValidationEnv
```

```powershell
 powershell -ExecutionPolicy Bypass -File .\requirements\run_requirements_validation.ps1 -Track cu12 -SyncLock -BuildApprovedWheelhouse -ClearApprovedWheelhouse -VerifyOfflineInstall -RemoveOfflineEnv -SkipCreateEnv -SkipInstall -SkipValidation
```

```powershell
powershell -ExecutionPolicy Bypass -File .\requirements\run_requirements_validation.ps1 -Track all -SyncLock -SkipCreateEnv -SkipInstall -SkipValidation
```

## 가상환경 동작 방식

- 실험용 가상환경은 `req-cu11`, `req-cu12`처럼 생성된다.
- 오프라인 검증용 환경은 `req-cu11-offline`, `req-cu12-offline`처럼 별도로 만든다.
- 기본적으로 환경은 자동 삭제하지 않는다.
- `-RemoveValidationEnv`를 주면 온라인 검증용 기존 환경을 지우고 다시 만든다.
- `-RemoveOfflineEnv`를 주면 오프라인 검증용 기존 환경을 지우고 다시 만든다.
- `sync lock only`에서는 환경을 만들지 않는다.

## 오프라인 설치 검증 방식

오프라인 설치 검증은 다음 순서로 진행한다.

1. `<env>-offline` 환경 생성
2. `wheelhouse\approved\api`와 `wheelhouse\approved\<track>`를 함께 사용해서 `--no-index --find-links ... -r <track>.lock.txt` 설치
3. API 검증과 GPU 검증 재실행

즉, `api` approved와 트랙 approved를 함께 사용해 실제 오프라인 재설치가 가능한지 확인하는 절차다.

## 로그 저장 규칙

- `run_requirements_validation.ps1`는 `requirements\logs\` 아래에 transcript 로그를 남긴다.
- `run_requirements_validation.bat`는 별도의 launcher 로그를 남긴다.
- launcher 로그에는 선택 옵션과 최종 명령이 기록된다.
- transcript 로그에는 실제 설치, 다운로드, 검증 출력이 기록된다.

## 운영 판단 기준

- GPU 트랙은 import 성공만으로 끝내지 않는다.
- `torch.cuda.is_available()`까지 통과해야 승인 대상으로 본다.
- `.in`이 바뀌었는데 sync 하지 않았다면 대응 `.lock.txt`는 stale 상태다.
- 릴리스 전에는 `api.lock.txt`와 대상 CUDA lock이 최신 검증 결과와 맞는지 확인한다.