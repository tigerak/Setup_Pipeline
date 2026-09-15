import os
import csv
import shutil
import numpy as np
from PIL import Image
from datetime import datetime

# NumPy 호환성 패치
if not hasattr(np, 'bool'):
    np.bool = np.bool_

try:
    from engine_build import TRTWrapper
except ImportError:
    pass


def preprocess_image(img_path, resize_w, resize_h, mean, std):
    """
    이미지를 전처리하여 (1, C, H, W) 형태의 numpy 배열을 반환합니다.
    PIL을 사용하여 한글 경로 호환성을 보장합니다.

    Args:
        img_path: 이미지 파일 경로
        resize_w: 리사이즈 너비
        resize_h: 리사이즈 높이
        mean: RGB 채널 평균값 (numpy array, shape=(3,))
        std: RGB 채널 표준편차 (numpy array, shape=(3,))

    Returns:
        np.ndarray: (1, 3, H, W) 형태의 float32 배열
    """
    img = Image.open(img_path).convert('RGB')
    img = img.resize((resize_w, resize_h), Image.BILINEAR)
    img = np.array(img).astype(np.float32) / 255.0
    img = (img - mean) / std
    img = img.transpose(2, 0, 1)  # HWC -> CHW
    return np.expand_dims(img, axis=0).astype(np.float32)


def softmax(logits):
    """Numerically stable softmax."""
    exp = np.exp(logits - np.max(logits))
    return exp / np.sum(exp)


def run_engine_simulation(engine_path, img_dir, save_dir,
                          resize_str, mean_str, std_str,
                          class_names,
                          log_callback=None, progress_callback=None):
    """
    TensorRT 엔진(.trt/.engine)만으로 이미지 분류 추론을 수행합니다.

    추론 결과를 CSV로 저장하고, 이미지를 예측 클래스별 폴더로 복사합니다.

    Args:
        engine_path: TensorRT 엔진 파일 경로 (.trt 또는 .engine)
        img_dir: 추론할 이미지가 들어있는 폴더 경로
        save_dir: 결과를 저장할 루트 폴더 경로
        resize_str: "W, H" 형태의 리사이즈 문자열
        mean_str: "R, G, B" 형태의 평균값 문자열 (기본: "0.5, 0.5, 0.5")
        std_str: "R, G, B" 형태의 표준편차 문자열 (기본: "1.0, 1.0, 1.0")
        class_names: 클래스명 리스트 (예: ["OK", "NG_Scratch", "NG_Dent"])
        log_callback: 로그 메시지 콜백 (str -> None)
            prefix 규칙:
            - "[SUCCESS] ..." : 성공 (초록색 권장)
            - "[WARNING] ..." : 경고 (노란색 권장)
            - "[ERROR] ..."   : 에러 (빨간색 권장)
            - 그 외 일반 메시지
        progress_callback: 진행률 콜백 (current: int, total: int -> None)

    Returns:
        dict: {
            "success": bool,
            "csv_path": str | None,
            "output_dir": str | None,
            "summary": dict | None,   # {class_name: count, ...}
            "error": str | None
        }
    """
    def log(msg):
        if log_callback:
            log_callback(msg)

    def progress(current, total):
        if progress_callback:
            progress_callback(current, total)

    # --- 1. 파라미터 파싱 ---
    try:
        w, h = map(int, resize_str.split(','))
        mean = np.array([float(x) for x in mean_str.split(',')])
        std = np.array([float(x) for x in std_str.split(',')])
    except Exception as e:
        return {"success": False, "csv_path": None, "output_dir": None,
                "summary": None, "error": f"전처리 파라미터 파싱 실패: {e}"}

    if not class_names or len(class_names) == 0:
        return {"success": False, "csv_path": None, "output_dir": None,
                "summary": None, "error": "클래스명이 하나도 입력되지 않았습니다."}

    # --- 2. 이미지 파일 목록 ---
    img_files = sorted([
        f for f in os.listdir(img_dir)
        if f.lower().endswith(('.png', '.jpg', '.jpeg', '.bmp'))
    ])
    if not img_files:
        return {"success": False, "csv_path": None, "output_dir": None,
                "summary": None, "error": "선택하신 폴더에 이미지 파일이 없습니다."}

    # --- 3. 출력 디렉토리 생성 (save_dir/YYMMDD/) ---
    today_str = datetime.now().strftime("%y%m%d")
    output_dir = os.path.join(save_dir, today_str)
    os.makedirs(output_dir, exist_ok=True)

    # 클래스별 하위 폴더 생성 + NaN 폴더
    for cname in class_names:
        os.makedirs(os.path.join(output_dir, cname), exist_ok=True)
    os.makedirs(os.path.join(output_dir, "NaN"), exist_ok=True)
    log(f"[SUCCESS] 출력 디렉토리 생성 완료: {output_dir}")

    # --- 4. TRT 엔진 로드 ---
    try:
        trt_model = TRTWrapper(engine_path)
        trt_input_dtype = trt_model.inputs[0]['dtype']
        log("[SUCCESS] TensorRT Engine 로드 성공")
    except Exception as e:
        return {"success": False, "csv_path": None, "output_dir": output_dir,
                "summary": None, "error": f"Engine Load Error: {e}"}

    # --- 5. 추론 ---
    results_csv = []
    class_count = {cname: 0 for cname in class_names}
    nan_count = 0
    total = len(img_files)
    progress(0, total)

    for i, f_name in enumerate(img_files):
        img_path = os.path.join(img_dir, f_name)

        try:
            input_tensor = preprocess_image(img_path, w, h, mean, std)
        except Exception as e:
            log(f"[WARNING] 이미지 전처리 실패 ({f_name}): {e}")
            results_csv.append([f_name, "ERROR", "N/A"] + ["N/A"] * len(class_names))
            progress(i + 1, total)
            continue

        # dtype 변환
        if trt_input_dtype == np.float16:
            input_tensor = input_tensor.astype(np.float16)

        # 추론
        raw_output = trt_model.infer(input_tensor)[0].astype(np.float32).flatten()

        # NaN 검출
        if np.any(np.isnan(raw_output)) or np.any(np.isinf(raw_output)):
            nan_count += 1
            log(f"[WARNING] 추론 결과 NaN/Inf 감지 ({f_name}) - 모델 출력이 비정상입니다!")
            row = [f_name, "NaN", "NaN"] + ["NaN"] * len(class_names)
            results_csv.append(row)
            # NaN 폴더에 복사
            try:
                dst_path = os.path.join(output_dir, "NaN", f_name)
                shutil.copy2(img_path, dst_path)
            except Exception as e:
                log(f"[WARNING] 이미지 복사 실패 ({f_name} -> NaN): {e}")
            progress(i + 1, total)
            continue

        # softmax 적용
        probs = softmax(raw_output)
        pred_idx = int(np.argmax(probs))
        pred_conf = float(probs[pred_idx])

        # 클래스명 매핑
        if pred_idx < len(class_names):
            pred_class = class_names[pred_idx]
        else:
            pred_class = f"Unknown_{pred_idx}"
            log(f"[WARNING] 예측 인덱스({pred_idx})가 클래스명 범위({len(class_names)})를 초과합니다: {f_name}")

        # 각 클래스별 softmax 값 구성
        per_class_probs = {}
        for ci, cname in enumerate(class_names):
            if ci < len(probs):
                per_class_probs[cname] = float(probs[ci])
            else:
                per_class_probs[cname] = 0.0

        # CSV 행 구성: [FileName, PredictedClass, Confidence, Class0_Prob, Class1_Prob, ...]
        row = [f_name, pred_class, f"{pred_conf:.6f}"]
        for cname in class_names:
            row.append(f"{per_class_probs[cname]:.6f}")
        results_csv.append(row)

        # 이미지 복사
        try:
            dst_path = os.path.join(output_dir, pred_class, f_name)
            shutil.copy2(img_path, dst_path)
        except Exception as e:
            log(f"[WARNING] 이미지 복사 실패 ({f_name} -> {pred_class}): {e}")

        # 클래스별 카운트
        class_count[pred_class] = class_count.get(pred_class, 0) + 1

        # 로그
        log(f"[{i+1}/{total}] {f_name} -> {pred_class} ({pred_conf:.4f})")
        progress(i + 1, total)

    # --- 6. CSV 저장 ---
    csv_path = os.path.join(output_dir, "simulation_results.csv")
    with open(csv_path, 'w', newline='', encoding='utf-8') as f:
        writer = csv.writer(f)
        header = ["FileName", "PredictedClass", "Confidence"]
        for cname in class_names:
            header.append(f"Softmax_{cname}")
        writer.writerow(header)
        writer.writerows(results_csv)

    # --- 7. 요약 로그 ---
    log("")
    log("=" * 50)
    log("[SUCCESS] 추론 완료 요약")
    log(f"  총 이미지: {total}장")
    for cname in class_names:
        cnt = class_count.get(cname, 0)
        log(f"  {cname}: {cnt}장 ({cnt/total*100:.1f}%)")
    if nan_count > 0:
        log(f"  ⚠️ NaN/Inf: {nan_count}장 ({nan_count/total*100:.1f}%) - 모델 출력 이상!")
    log(f"  CSV 저장: {csv_path}")
    log(f"  이미지 저장: {output_dir}")
    log("=" * 50)

    return {
        "success": True,
        "csv_path": csv_path,
        "output_dir": output_dir,
        "summary": class_count,
        "error": None
    }
