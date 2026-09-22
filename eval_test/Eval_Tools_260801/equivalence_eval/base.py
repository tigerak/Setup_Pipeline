"""
equivalence_eval/base.py
공통 전처리 유틸리티 및 ONNX 세션 로더
"""
import numpy as np
from PIL import Image
import onnxruntime as ort

# NumPy 호환성 패치
if not hasattr(np, 'bool'):
    np.bool = np.bool_


def preprocess_image(img_path, resize_w, resize_h, mean, std):
    """
    이미지를 전처리하여 (1, C, H, W) 형태의 numpy 배열을 반환합니다.

    Args:
        img_path: 이미지 파일 경로
        resize_w: 리사이즈 너비
        resize_h: 리사이즈 높이
        mean: RGB 채널 평균값 (numpy array, shape=(3,))
        std: RGB 채널 표준편차 (numpy array, shape=(3,))

    Returns:
        np.ndarray: (1, 3, H, W) 형태의 float32 배열
    """
    img = Image.open(img_path)
    if img.mode != 'RGB':
        img = img.convert('RGB')
    img = img.resize((resize_w, resize_h), Image.BILINEAR)
    img = np.array(img, dtype=np.float32) / 255.0
    img = (img - mean) / std
    img = img.transpose(2, 0, 1)  # HWC -> CHW
    return np.expand_dims(img, axis=0).astype(np.float32)


def parse_preprocess_params(resize_str, mean_str, std_str):
    """
    문자열 형태의 전처리 파라미터를 파싱합니다.

    Returns:
        (w, h, mean_array, std_array) 또는 파싱 실패 시 예외 발생
    """
    w, h = map(int, resize_str.split(','))
    mean = np.array([float(x) for x in mean_str.split(',')])
    std  = np.array([float(x) for x in std_str.split(',')])
    return w, h, mean, std


def load_onnx_session(onnx_path, log_callback=None):
    """
    ONNX 세션을 로드합니다. CUDA 우선, 실패 시 TensorRT FP16 fallback으로 재시도합니다.

    Args:
        onnx_path: ONNX 모델 경로
        log_callback: 로그 메시지를 전달할 콜백 함수 (str -> None)

    Returns:
        ort.InferenceSession
    """
    def log(msg):
        if log_callback:
            log_callback(msg)

    priority_providers = ['CUDAExecutionProvider', 'CPUExecutionProvider']
    backup_providers = [
        ('TensorrtExecutionProvider', {
            'trt_fp16_enable': True,
            'trt_engine_cache_enable': True,
        }),
        'CUDAExecutionProvider',
        'CPUExecutionProvider',
    ]

    try:
        session = ort.InferenceSession(onnx_path, providers=priority_providers)
        log("[SUCCESS] ONNX 로드 성공 (Standard FP32 Mode)")
        return session
    except Exception:
        log("[WARNING] 표준 ONNX 로드 실패 (FP16 Cast 충돌 의심). TensorRT 모드로 우회합니다...")
        session = ort.InferenceSession(onnx_path, providers=backup_providers)
        log("[SUCCESS] ONNX 로드 성공 (TensorRT FP16 Fallback Mode)")
        return session
