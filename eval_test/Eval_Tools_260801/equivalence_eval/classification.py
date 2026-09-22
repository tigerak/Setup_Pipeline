"""
equivalence_eval/classification.py
Classification task: ONNX vs TensorRT 비교 로직
"""
import numpy as np


def get_csv_header(threshold_pct: float) -> list:
    return [
        "FileName", "ONNX_Class", "ONNX_Conf",
        "TRT_Class", "TRT_Conf",
        "MSE", "Max_Diff", "Spike_Location",
        f"Critical(MaxDiff>{threshold_pct}%)",
    ]


def compare_single(raw_onnx: np.ndarray, raw_trt: np.ndarray,
                   f_name: str, idx: int, total: int,
                   threshold: float, log) -> list:
    """
    단일 이미지에 대한 Classification 비교를 수행합니다.

    Args:
        raw_onnx: ONNX 원시 출력 (float32)
        raw_trt:  TRT  원시 출력 (float32)
        f_name:   이미지 파일명
        idx:      현재 인덱스 (0-based)
        total:    전체 이미지 수
        threshold: 절댓값 diff 임계치 (소수, e.g. 0.05)
        log:      로그 콜백 함수

    Returns:
        CSV 한 행 (list)
    """
    out_onnx = raw_onnx.flatten()
    out_trt  = raw_trt.flatten()[:out_onnx.size]

    # Softmax
    onnx_exp = np.exp(out_onnx - np.max(out_onnx))
    out_onnx = onnx_exp / np.sum(onnx_exp)
    trt_exp  = np.exp(out_trt - np.max(out_trt))
    out_trt  = trt_exp / np.sum(trt_exp)

    onnx_class = int(np.argmax(out_onnx))
    onnx_conf  = float(np.max(out_onnx))
    trt_class  = int(np.argmax(out_trt))
    trt_conf   = float(np.max(out_trt))

    diff     = np.abs(out_onnx - out_trt)
    mse      = float(np.mean(diff ** 2))
    max_diff = float(np.max(diff))
    max_idx  = int(np.argmax(diff))
    is_critical = "YES" if max_diff > threshold else "NO"

    log_msg = (f"[{idx+1}/{total}] {f_name} | "
               f"ONNX:{onnx_class}({onnx_conf:.3f}) TRT:{trt_class}({trt_conf:.3f}) | "
               f"MaxDiff:{max_diff:.4f}")
    if is_critical == "YES":
        log_msg = f"[CRITICAL] {log_msg}"
    log(log_msg)

    return [f_name, onnx_class, f"{onnx_conf:.6f}",
            trt_class, f"{trt_conf:.6f}",
            f"{mse:.8f}", f"{max_diff:.6f}", f"ClassIdx:{max_idx}", is_critical]
