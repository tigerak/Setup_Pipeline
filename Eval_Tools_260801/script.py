import sys
import os
import re
os.environ["KMP_DUPLICATE_LIB_OK"] = "TRUE"


def find_trt_lib_dir(base_dir=r"D:\visionAI"):
    """
    기본 DIR에서 TensorRT 폴더를 찾아 가장 버전이 높은 경로의 lib 폴더를 찾습니다.

    Args:
        base_dir (str): TensorRT 설치를 검색할 기본 DIR.

    Returns:
        str | None: TensorRT lib 폴더 경로. 만약 없으면 None 반환.
    """
    best_version = None
    best_lib_dir = None

    if not os.path.isdir(base_dir):
        return None

    for entry_name in os.listdir(base_dir):
        match = re.match(r"^TensorRT-(\d+\.\d+\.\d+\.\d+)$", entry_name)
        if not match:
            continue

        candidate_dir = os.path.join(base_dir, entry_name)
        candidate_lib_dir = os.path.join(candidate_dir, "lib")
        if not os.path.isdir(candidate_lib_dir):
            continue

        version_tuple = tuple(int(part) for part in match.group(1).split("."))
        if best_version is None or version_tuple > best_version:
            best_version = version_tuple
            best_lib_dir = candidate_lib_dir

    return best_lib_dir


TRT_LIB_DIR = find_trt_lib_dir()

if TRT_LIB_DIR and os.path.exists(TRT_LIB_DIR):
    
    os.environ["PATH"] = TRT_LIB_DIR + os.pathsep + os.environ["PATH"]
    
    os.add_dll_directory(TRT_LIB_DIR)
    print(f"[Success] TensorRT path setup Done: {TRT_LIB_DIR}")
else:
    print(f"[Error] Not found TensorRT path under D:\\visionAI", file=sys.stderr)