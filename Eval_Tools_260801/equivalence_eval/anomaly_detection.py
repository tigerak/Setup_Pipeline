"""
equivalence_eval/anomaly_detection.py
Anomaly Detection task: ONNX vs TensorRT 비교 로직
- 재구성 이미지(reconstruction) 또는 anomaly score map 픽셀 단위 절댓값 차이 비교
- |onnx - trt| > threshold 인 픽셀이 1개라도 있으면 Critical
"""
import numpy as np


def get_csv_header(threshold_pct: float) -> list:
    return [
        "FileName", "Total_Pixels", "Exceed_Pixels",
        "Exceed_Ratio(%)", "Mean_AbsDiff", "Max_AbsDiff",
        f"Critical(Any_Pixel_Diff>{threshold_pct}%)",
    ]


def compare_single(raw_onnx: np.ndarray, raw_trt: np.ndarray,
                   f_name: str, idx: int, total: int,
                   threshold: float, log,
                   threshold_pct: float = 5.0) -> list:
    """
    단일 이미지에 대한 Anomaly Detection 비교를 수행합니다.

    Args:
        threshold:     절댓값 diff 임계치 (소수, e.g. 0.05)
        threshold_pct: 로그/CSV 표시용 % 값 (e.g. 5.0)

    Returns:
        CSV 한 행 (list)
    """
    ano_onnx = raw_onnx.flatten()
    ano_trt  = raw_trt.flatten()[:ano_onnx.size]

    diff          = np.abs(ano_onnx - ano_trt)
    total_pixels  = int(diff.size)
    exceed_pixels = int(np.sum(diff > threshold))
    exceed_ratio  = exceed_pixels / total_pixels * 100.0
    mean_diff     = float(np.mean(diff))
    max_diff      = float(np.max(diff))
    is_critical   = "YES" if exceed_pixels > 0 else "NO"

    log_msg = (f"[{idx+1}/{total}] {f_name} | "
               f"Exceed(>{threshold_pct}%): {exceed_pixels}/{total_pixels} "
               f"({exceed_ratio:.2f}%) | MaxDiff:{max_diff:.4f}")
    if is_critical == "YES":
        log_msg = f"[CRITICAL] {log_msg}"
    log(log_msg)

    return [f_name, total_pixels, exceed_pixels,
            f"{exceed_ratio:.4f}", f"{mean_diff:.6f}", f"{max_diff:.6f}", is_critical]
