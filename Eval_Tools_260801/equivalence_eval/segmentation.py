"""
equivalence_eval/segmentation.py
Segmentation task: ONNX vs TensorRT 비교 로직
- (1, C, H, W) multi-class logit → argmax 클래스 맵 → 픽셀 불일치 비교
- (1, H, W) single-channel mask → 직접 비교
"""
import numpy as np


def get_csv_header() -> list:
    return [
        "FileName", "Total_Pixels", "Mismatch_Pixels",
        "Mismatch_Ratio(%)", "Critical(Any_Mismatch)",
    ]


def compare_single(raw_onnx: np.ndarray, raw_trt: np.ndarray,
                   f_name: str, idx: int, total: int,
                   threshold: float, log) -> list:
    """
    단일 이미지에 대한 Segmentation 비교를 수행합니다.
    threshold는 Segmentation에서 미사용 (1픽셀이라도 불일치 시 Critical).

    Returns:
        CSV 한 행 (list)
    """
    seg_onnx = raw_onnx
    seg_trt  = raw_trt

    # shape 맞추기: TRT 출력이 ONNX와 다른 경우 reshape
    if seg_trt.shape != seg_onnx.shape:
        try:
            seg_trt = seg_trt.reshape(seg_onnx.shape)
        except ValueError:
            seg_trt = seg_trt.flatten()[:seg_onnx.size].reshape(seg_onnx.shape)

    if seg_onnx.ndim == 4:   # (1, C, H, W) multi-class logit
        map_onnx = np.argmax(seg_onnx[0], axis=0).astype(np.int32)
        map_trt  = np.argmax(seg_trt[0],  axis=0).astype(np.int32)
    else:                    # (1, H, W) single-channel
        map_onnx = seg_onnx[0].astype(np.int32)
        map_trt  = seg_trt[0].astype(np.int32)

    total_pixels    = int(map_onnx.size)
    mismatch_pixels = int(np.sum(map_onnx != map_trt))
    mismatch_ratio  = mismatch_pixels / total_pixels * 100.0
    is_critical     = "YES" if mismatch_pixels > 0 else "NO"

    log_msg = (f"[{idx+1}/{total}] {f_name} | "
               f"Mismatch: {mismatch_pixels}/{total_pixels} ({mismatch_ratio:.2f}%)")
    if is_critical == "YES":
        log_msg = f"[CRITICAL] {log_msg}"
    log(log_msg)

    return [f_name, total_pixels, mismatch_pixels,
            f"{mismatch_ratio:.4f}", is_critical]
