"""
equivalence_eval/__init__.py
ONNX vs TensorRT 등가성 검증 패키지 진입점

사용법:
    from equivalence_eval import run_equivalence_check
"""
import os
import csv

from .base import preprocess_image, parse_preprocess_params, load_onnx_session
from . import classification as cls_mod
from . import segmentation  as seg_mod
from . import anomaly_detection as ano_mod

try:
    from engine_build import TRTWrapper
except ImportError:
    pass


def run_equivalence_check(img_dir, onnx_path, trt_path, task,
                          resize_str, mean_str, std_str,
                          log_callback=None, progress_callback=None,
                          pixel_diff_threshold=5.0):
    """
    ONNX 모델과 TensorRT 엔진 간의 등가성 검증(Equivalence Checking)을 수행합니다.

    Args:
        img_dir:               이미지 폴더 경로
        onnx_path:             ONNX 모델 경로
        trt_path:              TensorRT 엔진 경로
        task:                  "Classification" | "Detection" | "Segmentation" | "Anomaly Detection"
        resize_str:            "W, H" 형태 문자열
        mean_str:              "R, G, B" 형태 문자열
        std_str:               "R, G, B" 형태 문자열
        log_callback:          로그 콜백 (str -> None)
            prefix 규칙:
            "[SUCCESS]" | "[WARNING]" | "[ERROR]" | "[CRITICAL]" | 일반 메시지
        progress_callback:     진행률 콜백 (current: int, total: int -> None)
        pixel_diff_threshold:  diff 임계치 (%, 기본 5.0)

    Returns:
        dict: {"success": bool, "csv_path": str | None, "error": str | None}
    """
    def log(msg):
        if log_callback:
            log_callback(msg)

    def progress(cur, tot):
        if progress_callback:
            progress_callback(cur, tot)

    threshold = pixel_diff_threshold / 100.0

    # 1. 파라미터 파싱
    try:
        w, h, mean, std = parse_preprocess_params(resize_str, mean_str, std_str)
    except Exception as e:
        return {"success": False, "csv_path": None, "error": f"전처리 파라미터 파싱 실패: {e}"}

    # 2. 이미지 파일 목록
    img_files = sorted([
        f for f in os.listdir(img_dir)
        if f.lower().endswith(('.png', '.jpg', '.jpeg', '.bmp'))
    ])
    if not img_files:
        return {"success": False, "csv_path": None, "error": "선택하신 폴더에 이미지 파일이 없습니다."}

    # 3. 모델 로드
    original_cwd = os.getcwd()
    onnx_dir = os.path.dirname(onnx_path)
    if onnx_dir:
        os.chdir(onnx_dir)

    try:
        ort_session = load_onnx_session(onnx_path, log_callback)
        input_name      = ort_session.get_inputs()[0].name
        onnx_input_type = ort_session.get_inputs()[0].type

        trt_model      = TRTWrapper(trt_path)
        trt_input_dtype = trt_model.inputs[0]['dtype']
        log("[SUCCESS] TensorRT Engine 로드 성공")
    except Exception as e:
        os.chdir(original_cwd)
        return {"success": False, "csv_path": None, "error": f"Model Load Error: {e}"}
    finally:
        os.chdir(original_cwd)

    # 4. Task별 CSV 헤더 선택
    if task == "Classification":
        csv_header = cls_mod.get_csv_header(pixel_diff_threshold)
    elif task == "Segmentation":
        csv_header = seg_mod.get_csv_header()
    elif task == "Anomaly Detection":
        csv_header = ano_mod.get_csv_header(pixel_diff_threshold)
    elif task == "Detection":
        csv_header = [
            "FileName", "MSE", "Max_Diff", "Spike_Location",
            f"Critical(MaxDiff>{pixel_diff_threshold}%)",
        ]
    else:
        csv_header = ["FileName", "MSE", "Max_Diff", "Critical"]

    # 5. 추론 및 비교 루프
    import numpy as np
    results_csv = []
    total = len(img_files)
    progress(0, total)

    for i, f_name in enumerate(img_files):
        img_path = os.path.join(img_dir, f_name)
        input_tensor = preprocess_image(img_path, w, h, mean, std)

        onnx_input = input_tensor.astype(np.float16) if 'float16' in onnx_input_type else input_tensor
        trt_input  = input_tensor.astype(np.float16) if trt_input_dtype == np.float16 else input_tensor

        raw_onnx = ort_session.run(None, {input_name: onnx_input})[0].astype(np.float32)
        raw_trt  = trt_model.infer(trt_input)[0].astype(np.float32)

        row = None
        if task == "Classification":
            row = cls_mod.compare_single(raw_onnx, raw_trt, f_name, i, total, threshold, log)
        elif task == "Segmentation":
            row = seg_mod.compare_single(raw_onnx, raw_trt, f_name, i, total, threshold, log)
        elif task == "Anomaly Detection":
            row = ano_mod.compare_single(raw_onnx, raw_trt, f_name, i, total,
                                         threshold, log, pixel_diff_threshold)
        elif task == "Detection":
            # Detection: 벡터 절댓값 diff
            out_onnx = raw_onnx.flatten()
            out_trt  = raw_trt.flatten()[:out_onnx.size]
            diff     = np.abs(out_onnx - out_trt)
            mse      = float(np.mean(diff ** 2))
            max_diff = float(np.max(diff))
            max_idx  = np.unravel_index(int(np.argmax(diff)), raw_onnx.shape)
            is_crit  = "YES" if max_diff > threshold else "NO"
            log_msg  = f"[{i+1}/{total}] {f_name} | MSE:{mse:.6f} | MaxDiff:{max_diff:.4f} | Loc:{max_idx}"
            if is_crit == "YES":
                log_msg = f"[CRITICAL] {log_msg}"
            log(log_msg)
            row = [f_name, f"{mse:.8f}", f"{max_diff:.6f}", str(max_idx), is_crit]

        if row is not None:
            results_csv.append(row)
        progress(i + 1, total)

    # 6. CSV 저장
    csv_path = os.path.join(onnx_dir, f"validation_results_{task.replace(' ', '_')}.csv")
    with open(csv_path, 'w', newline='', encoding='utf-8') as f:
        writer = csv.writer(f)
        writer.writerow(csv_header)
        writer.writerows(results_csv)

    return {"success": True, "csv_path": csv_path, "error": None}
