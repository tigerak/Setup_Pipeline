"""
SMW Simulation: Batch Inference for Seam Weld Inspection
- 이미지를 N개(기본 56개)의 패치로 분할하여 배치 추론
- 각 패치의 예측 결과를 후처리하여 최종 라벨 결정
- threshold_dict를 이용한 클래스별 임계값 기반 판정
"""

import os
import csv
import shutil
import time
import numpy as np
from PIL import Image
from datetime import datetime
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches

# NumPy 호환성 패치
if not hasattr(np, 'bool'):
    np.bool = np.bool_

try:
    from engine_build import TRTWrapper
except ImportError:
    pass


def preprocess_image_to_patches(img_path, resize_w, resize_h, num_patches, mean, std):
    """
    이미지를 N개의 패치로 분할하여 (N, C, H, W) 형태의 numpy 배열을 반환합니다.
    
    SMW 검사의 경우:
    - 원본 이미지를 (resize_h, resize_w * num_patches) 크기로 리사이즈
    - 이후 num_patches 개의 패치로 분할
    
    Args:
        img_path: 이미지 파일 경로
        resize_w: 각 패치의 너비 (예: 224)
        resize_h: 각 패치의 높이 (예: 224)
        num_patches: 패치 개수 (기본: 56)
        mean: RGB 채널 평균값 (numpy array, shape=(3,))
        std: RGB 채널 표준편차 (numpy array, shape=(3,))

    Returns:
        np.ndarray: (num_patches, 3, H, W) 형태의 float32 배열
    """
    img = Image.open(img_path).convert('RGB')
    
    # 전체 이미지를 (H, W*num_patches) 크기로 리사이즈
    total_width = resize_w * num_patches
    img = img.resize((total_width, resize_h), Image.BILINEAR)
    
    # numpy 배열로 변환 및 정규화
    img_arr = np.array(img).astype(np.float32) / 255.0
    img_arr = (img_arr - mean) / std
    img_arr = img_arr.transpose(2, 0, 1)  # HWC -> CHW
    
    # 패치로 분할: (3, H, W*num_patches) -> (num_patches, 3, H, W)
    patches = []
    for i in range(num_patches):
        x_start = i * resize_w
        x_end = x_start + resize_w
        patch = img_arr[:, :, x_start:x_end]
        patches.append(patch)
    
    return np.array(patches, dtype=np.float32)


def softmax(logits, axis=-1):
    """Numerically stable softmax."""
    exp = np.exp(logits - np.max(logits, axis=axis, keepdims=True))
    return exp / np.sum(exp, axis=axis, keepdims=True)


def smw_post_process(patch_predictions, threshold_dict, ok_class_idx=None):
    """
    SMW 패치 예측 결과를 후처리하여 최종 라벨을 결정합니다.
    
    로직 (smw_eval.py의 SMW_get_result 기반):
    1. 각 클래스별 패치 비율 계산
    2. 특정 클래스(예: 미용접, 핀홀)는 1개만 있어도 불량으로 판정
    3. 그 외 클래스는 threshold 기반 판정
    
    Args:
        patch_predictions: 각 패치의 예측 클래스 인덱스 배열 (shape: num_patches,)
        threshold_dict: 클래스별 임계값 딕셔너리 {class_idx: threshold, ...}
        ok_class_idx: 정상(OK) 클래스의 인덱스 (기본: 가장 마지막 클래스)
    
    Returns:
        tuple: (최종 라벨 인덱스, 해당 클래스 비율)
    """
    pred = np.array(patch_predictions)
    num_classes = len(threshold_dict)
    
    # ok_class_idx가 None이면 마지막 클래스로 설정
    if ok_class_idx is None:
        ok_class_idx = num_classes - 1
    
    # 각 클래스별 비율 계산
    result_arr = np.zeros(num_classes)
    total = len(pred)
    unique, counts = np.unique(pred, return_counts=True)
    
    for cls_idx, cnt in zip(unique, counts):
        if cls_idx < num_classes:
            result_arr[cls_idx] = round(cnt / total, 3)
    
    # 내림차순 정렬된 인덱스
    sorted_indices = np.argsort(result_arr)[::-1]
    
    # 기본 최종 라벨: 정상(OK)
    final_label = ok_class_idx
    
    # 특수 조건: 임계값이 0인 클래스(즉시 불량 판정 클래스) 중 하나라도 있으면 해당 클래스로 판정
    immediate_ng_classes = [i for i, th in threshold_dict.items() if th == 0.0 and i != ok_class_idx]
    for cls_idx in immediate_ng_classes:
        if result_arr[cls_idx] > 0:
            # 여러 개 있으면 비율이 높은 것 선택
            final_label = cls_idx
            for other_cls in immediate_ng_classes:
                if result_arr[other_cls] > result_arr[final_label]:
                    final_label = other_cls
            return (final_label, result_arr[final_label])
    
    # 일반 조건: 가장 많은 클래스가 OK가 아니면 해당 클래스가 불량
    if sorted_indices[0] != ok_class_idx:
        final_label = sorted_indices[0]
    elif sorted_indices[0] == ok_class_idx:
        # OK가 가장 많지만, 2번째로 많은 클래스가 threshold 초과하면 불량
        second_class = sorted_indices[1]
        if result_arr[second_class] > threshold_dict.get(second_class, 0.0):
            final_label = second_class
    
    return (final_label, result_arr[final_label])


def save_pred_image(img_path, output_dir, final_label_name, patch_predictions, class_names):
    """
    원본 이미지를 최종 판정 폴더에 복사합니다.
    
    Args:
        img_path: 원본 이미지 경로
        output_dir: 출력 루트 디렉토리
        final_label_name: 최종 판정 클래스명
        patch_predictions: 패치별 예측 결과 (로그용)
        class_names: 클래스명 리스트
    """
    dst_folder = os.path.join(output_dir, final_label_name)
    os.makedirs(dst_folder, exist_ok=True)
    
    filename = os.path.basename(img_path)
    dst_path = os.path.join(dst_folder, filename)
    shutil.copy2(img_path, dst_path)
    
    return dst_path


def save_pred_image_with_overlay(img_path, output_dir, final_label_name, patch_predictions, class_names, patch_width=224):
    """
    패치별 예측 결과를 오버레이하여 이미지를 저장합니다.
    
    Args:
        img_path: 원본 이미지 경로
        output_dir: 출력 루트 디렉토리
        final_label_name: 최종 판정 클래스명
        patch_predictions: 패치별 예측 결과 배열
        class_names: 클래스명 리스트
        patch_width: 패치 너비 (기본: 224)
    
    Returns:
        str: 저장된 이미지 경로
    """
    dst_folder = os.path.join(output_dir, final_label_name)
    os.makedirs(dst_folder, exist_ok=True)
    
    filename = os.path.basename(img_path)
    # 확장자를 png로 변경 (matplotlib 저장용)
    base_name = os.path.splitext(filename)[0]
    dst_path = os.path.join(dst_folder, f"{base_name}.png")
    
    # PIL로 이미지 로드
    img = Image.open(img_path).convert('RGB')
    orig_width, orig_height = img.size
    
    # 패치 개수에 맞게 리사이즈
    num_patches = len(patch_predictions)
    target_width = patch_width * num_patches
    img_resized = img.resize((target_width, orig_height), Image.BILINEAR)
    img_arr = np.array(img_resized)
    
    height, width = img_arr.shape[:2]
    
    # 색상 맵 생성
    # colors = plt.cm.get_cmap('tab10', len(class_names) + 1)
    colors = plt.colormaps['tab10'].resampled(len(class_names)+1)
    
    # 시각화
    fig, axes = plt.subplots(2, 1, figsize=(40, 2))
    
    # (1) 원본 이미지
    axes[0].imshow(img_arr)
    axes[0].set_title(f"Label: {final_label_name} // {filename}", fontsize=12)
    axes[0].axis('off')
    
    # (2) 예측 오버레이
    axes[1].imshow(img_arr)
    
    for i, pred_idx in enumerate(patch_predictions):
        x_start = i * patch_width
        rect = mpatches.Rectangle(
            (x_start, 0), patch_width, height,
            linewidth=0,
            edgecolor=None,
            facecolor=colors(pred_idx),
            alpha=0.4
        )
        axes[1].add_patch(rect)
        
        # 라벨 텍스트 추가
        if pred_idx < len(class_names):
            label_text = class_names[pred_idx]
        else:
            label_text = f"Unk_{pred_idx}"
        axes[1].text(x_start + patch_width // 2, height // 2, label_text, 
                     color='black', fontsize=8, ha='center', va='center',
                     fontweight='bold')
    
    axes[1].set_xlim([0, width])
    axes[1].set_ylim([height, 0])
    axes[1].axis('off')
    
    plt.tight_layout()
    plt.savefig(dst_path, format='png', dpi=150, bbox_inches='tight', pad_inches=0)
    plt.close(fig)
    
    return dst_path


def run_smw_simulation(engine_path, img_dir, save_dir,
                       resize_str, mean_str, std_str,
                       num_patches, class_names, threshold_dict,
                       ok_class_idx=None,
                       save_overlay=False,
                       log_callback=None, progress_callback=None):
    """
    SMW TensorRT 엔진을 이용한 배치 추론 시뮬레이션을 수행합니다.

    Args:
        engine_path: TensorRT 엔진 파일 경로 (.trt 또는 .engine)
        img_dir: 추론할 이미지가 들어있는 폴더 경로
        save_dir: 결과를 저장할 루트 폴더 경로
        resize_str: "W, H" 형태의 리사이즈 문자열 (각 패치 크기)
        mean_str: "R, G, B" 형태의 평균값 문자열 (기본: "0.5, 0.5, 0.5")
        std_str: "R, G, B" 형태의 표준편차 문자열 (기본: "1.0, 1.0, 1.0")
        num_patches: 패치 개수 (기본: 56)
        class_names: 클래스명 리스트 (예: ["NO", "OVR", "WK", "PHL", "SPTT", "OK"])
        threshold_dict: 클래스별 임계값 딕셔너리 {class_idx: threshold, ...}
        ok_class_idx: 정상(OK) 클래스 인덱스 (기본: 마지막)
        save_overlay: True일 경우 패치별 예측 결과 오버레이 이미지 저장 (기본: False)
        log_callback: 로그 메시지 콜백 (str -> None)
        progress_callback: 진행률 콜백 (current: int, total: int -> None)

    Returns:
        dict: {
            "success": bool,
            "csv_path": str | None,
            "output_dir": str | None,
            "summary": dict | None,
            "performance": dict | None,
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
                "summary": None, "performance": None, "error": f"전처리 파라미터 파싱 실패: {e}"}

    if not class_names or len(class_names) == 0:
        return {"success": False, "csv_path": None, "output_dir": None,
                "summary": None, "performance": None, "error": "클래스명이 하나도 입력되지 않았습니다."}

    # OK 클래스 인덱스 기본값
    if ok_class_idx is None:
        ok_class_idx = len(class_names) - 1

    # --- 2. 이미지 파일 목록 ---
    img_files = sorted([
        f for f in os.listdir(img_dir)
        if f.lower().endswith(('.png', '.jpg', '.jpeg', '.bmp'))
    ])
    if not img_files:
        return {"success": False, "csv_path": None, "output_dir": None,
                "summary": None, "performance": None, "error": "선택하신 폴더에 이미지 파일이 없습니다."}

    # --- 3. 출력 디렉토리 생성 ---
    today_str = datetime.now().strftime("%y%m%d_%H%M%S")
    output_dir = os.path.join(save_dir, f"SMW_{today_str}")
    os.makedirs(output_dir, exist_ok=True)

    # 클래스별 하위 폴더 생성
    for cname in class_names:
        os.makedirs(os.path.join(output_dir, cname), exist_ok=True)
    os.makedirs(os.path.join(output_dir, "NaN"), exist_ok=True)
    log(f"[SUCCESS] 출력 디렉토리 생성 완료: {output_dir}")

    # --- 4. TRT 엔진 로드 ---
    try:
        trt_model = TRTWrapper(engine_path)
        trt_input_dtype = trt_model.inputs[0]['dtype']
        log(f"[SUCCESS] TensorRT Engine 로드 성공")
        log(f"   Input Shape: {trt_model.inputs[0]['shape']}")
        log(f"   Input Dtype: {trt_input_dtype}")
    except Exception as e:
        return {"success": False, "csv_path": None, "output_dir": output_dir,
                "summary": None, "performance": None, "error": f"Engine Load Error: {e}"}

    # --- 5. 추론 ---
    results_csv = []
    class_count = {cname: 0 for cname in class_names}
    nan_count = 0
    total = len(img_files)
    progress(0, total)

    # 성능 측정 변수
    total_preproc_time = 0.0
    total_infer_time = 0.0
    total_postproc_time = 0.0
    start_time = time.time()

    for i, f_name in enumerate(img_files):
        img_path = os.path.join(img_dir, f_name)

        # 전처리 시간 측정
        t0 = time.time()
        try:
            input_tensor = preprocess_image_to_patches(img_path, w, h, num_patches, mean, std)
        except Exception as e:
            log(f"[WARNING] 이미지 전처리 실패 ({f_name}): {e}")
            # 에러 행 구성
            row = [f_name, "ERROR", "N/A"] + ["N/A"] * num_patches
            results_csv.append(row)
            progress(i + 1, total)
            continue
        t1 = time.time()
        total_preproc_time += (t1 - t0)

        # dtype 변환
        if trt_input_dtype == np.float16:
            input_tensor = input_tensor.astype(np.float16)

        # 추론 시간 측정
        t2 = time.time()
        try:
            raw_output = trt_model.infer(input_tensor)[0].astype(np.float32)
        except Exception as e:
            log(f"[WARNING] 추론 실패 ({f_name}): {e}")
            row = [f_name, "ERROR", "N/A"] + ["N/A"] * num_patches
            results_csv.append(row)
            progress(i + 1, total)
            continue
        t3 = time.time()
        total_infer_time += (t3 - t2)

        # 후처리 시간 측정
        t4 = time.time()

        # NaN 검출
        if np.any(np.isnan(raw_output)) or np.any(np.isinf(raw_output)):
            nan_count += 1
            log(f"[WARNING] 추론 결과 NaN/Inf 감지 ({f_name})")
            row = [f_name, "NaN", "0.0"] + ["NaN"] * num_patches
            results_csv.append(row)
            # NaN 폴더에 복사
            try:
                dst_path = os.path.join(output_dir, "NaN", f_name)
                shutil.copy2(img_path, dst_path)
            except Exception as e:
                log(f"[WARNING] 이미지 복사 실패 ({f_name} -> NaN): {e}")
            progress(i + 1, total)
            continue

        # 패치별 예측 (softmax -> argmax)
        # raw_output shape: (num_patches, num_classes) 또는 (num_patches, num_classes, 1, 1)
        if raw_output.ndim > 2:
            raw_output = raw_output.reshape(num_patches, -1)
        
        probs = softmax(raw_output, axis=-1)
        patch_predictions = np.argmax(probs, axis=-1)  # (num_patches,)

        # 후처리: 최종 라벨 결정
        final_label_idx, final_ratio = smw_post_process(
            patch_predictions, threshold_dict, ok_class_idx
        )

        t5 = time.time()
        total_postproc_time += (t5 - t4)

        # 클래스명 매핑
        if final_label_idx < len(class_names):
            final_class = class_names[final_label_idx]
        else:
            final_class = f"Unknown_{final_label_idx}"
            log(f"[WARNING] 최종 라벨 인덱스({final_label_idx})가 범위 초과: {f_name}")

        # CSV 행 구성: [FileName, FinalClass, FinalRatio, Patch0, Patch1, ..., Patch55]
        row = [f_name, final_class, f"{final_ratio:.4f}"]
        for patch_pred in patch_predictions:
            if patch_pred < len(class_names):
                row.append(class_names[patch_pred])
            else:
                row.append(f"Unk_{patch_pred}")
        results_csv.append(row)

        # 이미지 저장 (overlay 옵션에 따라 분기)
        try:
            if save_overlay:
                save_pred_image_with_overlay(img_path, output_dir, final_class, patch_predictions, class_names, patch_width=w)
            else:
                save_pred_image(img_path, output_dir, final_class, patch_predictions, class_names)
        except Exception as e:
            log(f"[WARNING] 이미지 저장 실패 ({f_name} -> {final_class}): {e}")

        # 클래스별 카운트
        class_count[final_class] = class_count.get(final_class, 0) + 1

        # 로그
        patch_summary = ", ".join([f"{class_names[p] if p < len(class_names) else p}" for p in patch_predictions[:5]]) + "..."
        log(f"[{i+1}/{total}] {f_name} -> {final_class} ({final_ratio:.3f}) | Patches: [{patch_summary}]")
        progress(i + 1, total)

    end_time = time.time()
    total_time = end_time - start_time

    # --- 6. CSV 저장 ---
    csv_path = os.path.join(output_dir, "smw_simulation_results.csv")
    with open(csv_path, 'w', newline='', encoding='utf-8') as f:
        writer = csv.writer(f)
        header = ["FileName", "FinalClass", "FinalRatio"]
        for pi in range(num_patches):
            header.append(f"Patch_{pi}")
        writer.writerow(header)
        writer.writerows(results_csv)

    # --- 7. 성능 통계 계산 ---
    valid_count = total - nan_count
    if valid_count > 0:
        avg_preproc = (total_preproc_time / valid_count) * 1000  # ms
        avg_infer = (total_infer_time / valid_count) * 1000  # ms
        avg_postproc = (total_postproc_time / valid_count) * 1000  # ms
        throughput = valid_count / total_time  # images/sec
    else:
        avg_preproc = avg_infer = avg_postproc = throughput = 0.0

    performance = {
        "total_time": total_time,
        "avg_preproc_ms": avg_preproc,
        "avg_infer_ms": avg_infer,
        "avg_postproc_ms": avg_postproc,
        "throughput_ips": throughput,
        "total_images": total,
        "valid_images": valid_count
    }

    # --- 8. 요약 로그 ---
    log("")
    log("=" * 60)
    log("[SUCCESS] SMW Simulation 완료 요약")
    log(f"  총 이미지: {total}장")
    for cname in class_names:
        cnt = class_count.get(cname, 0)
        pct = (cnt / total * 100) if total > 0 else 0
        log(f"  {cname}: {cnt}장 ({pct:.1f}%)")
    if nan_count > 0:
        log(f"  ⚠️ NaN/Inf: {nan_count}장 ({nan_count/total*100:.1f}%)")
    log("")
    log("📊 Performance Summary:")
    log(f"  총 소요 시간: {total_time:.2f}초")
    log(f"  평균 전처리: {avg_preproc:.2f}ms/image")
    log(f"  평균 추론: {avg_infer:.2f}ms/image (Batch: {num_patches} patches)")
    log(f"  평균 후처리: {avg_postproc:.2f}ms/image")
    log(f"  처리량(Throughput): {throughput:.2f} images/sec")
    log("")
    log(f"  CSV 저장: {csv_path}")
    log(f"  이미지 저장: {output_dir}")
    log("=" * 60)

    return {
        "success": True,
        "csv_path": csv_path,
        "output_dir": output_dir,
        "summary": class_count,
        "performance": performance,
        "error": None
    }
