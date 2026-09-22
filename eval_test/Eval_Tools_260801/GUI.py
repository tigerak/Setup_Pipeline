import sys
import os
import re
os.environ["KMP_DUPLICATE_LIB_OK"] = "TRUE"


def find_trt_lib_dir(base_dir=r"D:\\visionAI"):
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
        match = re.match(r"^TensorRT-(10\.\d+\.\d+\.\d+)$", entry_name)
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

import json
import multiprocessing as mp
import queue

import numpy as np
# NumPy 호환성 패치
if not hasattr(np, 'bool'):
    np.bool = np.bool_

from engine_build.TRT_util import *
from equivalence_eval import run_equivalence_check
from trt_eval.engine_simulation import run_engine_simulation
from trt_eval.smw_simulation import run_smw_simulation
from gradcam.gramdCam import run_onnx_gradcam, list_onnx_layers_reverse

# Inference 관련 라이브러리 (설치 필요: pip install onnxruntime tensorrt pycuda opencv-python)
try:
    import onnxruntime as ort
    
    import pycuda.driver as cuda
    import pycuda.autoinit
except ImportError:
    print("⚠️ Warning: Inference libraries (onnxruntime, tensorrt, pycuda) are not installed.")


from PyQt5.QtWidgets import (QApplication, QWidget, QVBoxLayout, QFormLayout, 
                             QLineEdit, QPushButton, QFileDialog, QComboBox, 
                             QTextEdit, QHBoxLayout, QMessageBox, QLabel, QCheckBox,
                             QSizePolicy, QTabWidget, QProgressBar, QGroupBox,
                             QScrollArea, QSpinBox, QFrame)
from PyQt5.QtCore import QProcess, Qt, QThread, pyqtSignal
from PyQt5.QtGui import QPixmap



# ==========================================
# 🔥 큐(Queue)를 모니터링하여 GUI에 로그를 뿌려주는 스레드
# ==========================================
class LogMonitorThread(QThread):
    log_signal = pyqtSignal(str)
    finished_signal = pyqtSignal(bool)

    def __init__(self, q, proc):
        super().__init__()
        self.q = q
        self.proc = proc

    def run(self):
        success = False
        while True:
            try:
                msg = self.q.get(timeout=0.1) # Non-blocking 대기
                if msg == "SUCCESS":
                    success = True
                    break
                elif msg == "FAIL":
                    success = False
                    break
                self.log_signal.emit(msg)
            except queue.Empty:
                if not self.proc.is_alive():
                    break 
        
        while not self.q.empty():
            msg = self.q.get()
            if msg == "SUCCESS": success = True
            elif msg == "FAIL": success = False
            else: self.log_signal.emit(msg)
        
        self.finished_signal.emit(success)

# --- 메인 GUI 클래스 ---
class TensorRTBuilderGUI(QWidget):
    def __init__(self):
        super().__init__()
        self.script_dir  = os.path.dirname(os.path.abspath(sys.argv[0])) or os.getcwd()
        self.config_dir  = os.path.join(self.script_dir, "config")
        os.makedirs(self.config_dir, exist_ok=True)
        
        # 프로세스의 현재 상태 관리를 위한 변수 추가 (IDLE, BUILD, TEST)
        self.current_action = "IDLE" 
        
        self.initUI()
        self.apply_dark_theme()
        
        self.process = QProcess(self)
        self.process.readyReadStandardOutput.connect(self.handle_stdout)
        self.process.readyReadStandardError.connect(self.handle_stderr)
        self.process.finished.connect(self.process_finished)

    def initUI(self):
        self.setWindowTitle('✨ TensorRT Model Optimization Studio ✨')
        self.resize(1600, 1200)

        main_layout = QVBoxLayout(self)
        self.tabs = QTabWidget()
        
        self.build_tab = QWidget()
        self.val_tab = QWidget()
        self.sim_tab = QWidget()
        self.gradcam_tab = QWidget()
        self.smw_sim_tab = QWidget()
        
        self.tabs.addTab(self.build_tab, "🛠️ Build Engine")
        self.tabs.addTab(self.val_tab, "🔍 Equivalence Checking")
        self.tabs.addTab(self.sim_tab, "🚀 Engine Simulation")
        self.tabs.addTab(self.gradcam_tab, "🧠 ONNX-gradCam")
        self.tabs.addTab(self.smw_sim_tab, "🔧 SMW Simulation")
        
        self.setup_build_tab()
        self.setup_val_tab()
        self.setup_sim_tab()
        self.setup_gradcam_tab()
        self.setup_smw_sim_tab()
        
        main_layout.addWidget(self.tabs)
        self.refresh_config_list()
        self.refresh_sim_config_list()
        self.refresh_val_config_list()
        self.refresh_gradcam_config_list()
        self.refresh_smw_config_list()

    def setup_build_tab(self):
        layout = QVBoxLayout(self.build_tab)
        form_layout = QFormLayout()
        form_layout.setLabelAlignment(Qt.AlignRight)
        form_layout.setSpacing(15)

        # Config Manager
        config_layout = QHBoxLayout()
        self.config_name_input = QLineEdit("AZTab_fp16_config")
        self.config_name_input.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
        self.config_name_input.setMinimumWidth(250)
        self.btn_save_config = QPushButton("💾 Save Config")
        self.btn_save_config.clicked.connect(self.save_config)
        self.config_combo = QComboBox()
        self.config_combo.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
        self.config_combo.setMinimumWidth(400)
        self.btn_load_config = QPushButton("📂 Load Config")
        self.btn_load_config.clicked.connect(self.load_config)

        config_layout.addWidget(QLabel("Save As:"))
        config_layout.addWidget(self.config_name_input)
        config_layout.addWidget(self.btn_save_config)
        config_layout.addSpacing(40)
        config_layout.addWidget(QLabel("Load Profile:"))
        config_layout.addWidget(self.config_combo)
        config_layout.addWidget(self.btn_load_config)
        form_layout.addRow("📁 Config Manager:", config_layout)

        # File Paths
        trt_layout = QHBoxLayout()
        self.trt_path_input = QLineEdit("C:\\TensorRT-10.12.0.36\\bin\\trtexec.exe")
        self.btn_trt = QPushButton("📂 Browse")
        self.btn_trt.clicked.connect(self.select_trt)
        trt_layout.addWidget(self.trt_path_input); trt_layout.addWidget(self.btn_trt)
        form_layout.addRow("⚙️ TensorRT trtexec Path:", trt_layout)

        onnx_layout = QHBoxLayout()
        self.onnx_path_input = QLineEdit()
        self.btn_onnx = QPushButton("📂 Browse")
        self.btn_onnx.clicked.connect(self.select_onnx)
        onnx_layout.addWidget(self.onnx_path_input); onnx_layout.addWidget(self.btn_onnx)
        form_layout.addRow("📦 ONNX File Path:", onnx_layout)

        engine_layout = QHBoxLayout()
        self.engine_path_input = QLineEdit()
        self.btn_engine = QPushButton("💾 Browse")
        self.btn_engine.clicked.connect(self.select_engine)
        engine_layout.addWidget(self.engine_path_input); engine_layout.addWidget(self.btn_engine)
        form_layout.addRow("🎯 Target Engine/TRT Path:", engine_layout)

        # Shapes
        self.dynamic_batch_cb = QCheckBox("Enable Dynamic Batch")
        self.dynamic_batch_cb.setChecked(True)
        self.dynamic_batch_cb.stateChanged.connect(self.toggle_dynamic_batch)
        form_layout.addRow("🔄 Dynamic Batch:", self.dynamic_batch_cb)

        self.min_shape_input = QLineEdit("1x3x224x224")
        self.opt_shape_input = QLineEdit("100x3x224x224")
        self.max_shape_input = QLineEdit("100x3x224x224")
        form_layout.addRow("📉 Min Shape:", self.min_shape_input)
        form_layout.addRow("📊 Opt Shape:", self.opt_shape_input)
        form_layout.addRow("📈 Max Shape:", self.max_shape_input)

        self.layer_name_input = QLineEdit("images")
        form_layout.addRow("🏷️ Input Layer Name:", self.layer_name_input)

        # GPU Architecture
        arch_layout = QHBoxLayout()
        self.gpu_arch_combo = QComboBox()
        self.gpu_arch_combo.addItems(["Ampere", "Ada Lovelace", "Blackwell"])
        self.gpu_arch_combo.currentTextChanged.connect(self.on_gpu_arch_changed)
        arch_layout.addWidget(self.gpu_arch_combo)
        arch_layout.addStretch()
        form_layout.addRow("🖥️ GPU Architecture:", arch_layout)

        # Precision & Custom Script Checkbox
        precision_layout = QHBoxLayout()
        self.precision_combo = QComboBox()
        self.precision_combo.addItems(["FP16", "FP32"])
        
        self.custom_script_cb = QCheckBox("Use Custom Script (Fallback FP32)")
        self.custom_script_cb.setChecked(False)
        self.custom_script_cb.setToolTip("체크 시 trtexec 대신 파이썬 API를 사용하여 빌드하며, 아래 지정된 레이어를 FP32로 강제 유지합니다.")
        
        precision_layout.addWidget(self.precision_combo)
        precision_layout.addSpacing(20)
        precision_layout.addWidget(self.custom_script_cb)
        precision_layout.addStretch()
        form_layout.addRow("🎛️ Precision:", precision_layout)

        # FP32 강제 유지 키워드 입력창
        self.fp32_keywords_input = QLineEdit("Softmax, ReduceMean, Pow, Sqrt")
        form_layout.addRow("🔑 FP32 Keywords:", self.fp32_keywords_input)
        
        # 자동 성능 테스트 옵션
        self.auto_test_cb = QCheckBox("엔진 빌드 성공 후 자동으로 성능 벤치마크 진행 (--loadEngine)")
        self.auto_test_cb.setChecked(True)
        self.auto_test_cb.setStyleSheet("color: #a6e3a1; font-weight: bold;")
        form_layout.addRow("⏱️ Auto Perf Test:", self.auto_test_cb)
        
        # UI 연동
        self.precision_combo.currentTextChanged.connect(self.toggle_custom_ui)
        self.custom_script_cb.stateChanged.connect(self.toggle_custom_ui)
        self.gpu_arch_combo.currentTextChanged.connect(self.toggle_custom_ui)
        self.toggle_custom_ui()

        layout.addLayout(form_layout)

        # Buttons & Logs
        button_layout = QHBoxLayout()
        self.btn_run = QPushButton("🚀 Build TensorRT Engine")
        self.btn_run.setObjectName("RunButton")
        self.btn_run.clicked.connect(self.run_trtexec)
        self.btn_stop = QPushButton("🛑 Stop Process")
        self.btn_stop.setObjectName("StopButton")
        self.btn_stop.setEnabled(False)
        self.btn_stop.clicked.connect(self.stop_process)
        button_layout.addWidget(self.btn_run); button_layout.addWidget(self.btn_stop)
        layout.addLayout(button_layout)

        log_label = QLabel("📝 Build Logs:")
        log_label.setStyleSheet("font-weight: bold; margin-top: 10px;")
        layout.addWidget(log_label)

        self.log_output = QTextEdit()
        self.log_output.setReadOnly(True)
        self.log_output.setObjectName("LogConsole")
        layout.addWidget(self.log_output)

    def setup_val_tab(self):
        layout = QVBoxLayout(self.val_tab)
        form = QFormLayout()
        form.setLabelAlignment(Qt.AlignRight)
        form.setSpacing(15)

        img_dir_layout = QHBoxLayout()
        self.img_folder_input = QLineEdit()
        self.btn_img_folder = QPushButton("📂 Select Folder (Pick any image)")
        self.btn_img_folder.clicked.connect(self.select_img_folder)
        img_dir_layout.addWidget(self.img_folder_input)
        img_dir_layout.addWidget(self.btn_img_folder)
        form.addRow("🖼️ Image Folder:", img_dir_layout)


        val_onnx_layout = QHBoxLayout()
        self.val_onnx_input = QLineEdit()
        self.btn_val_onnx = QPushButton("📂 Browse")
        self.btn_val_onnx.clicked.connect(self.select_val_onnx)

        self.btn_simplify = QPushButton("✨ Simplify")
        self.btn_simplify.setObjectName("SimplifyButton") # 테마 적용을 위해(선택사항)
        self.btn_simplify.clicked.connect(self.run_onnxsim)

        val_onnx_layout.addWidget(self.val_onnx_input)
        val_onnx_layout.addWidget(self.btn_val_onnx)
        val_onnx_layout.addWidget(self.btn_simplify)
        form.addRow("📦 ONNX Path:", val_onnx_layout)

        val_engine_layout = QHBoxLayout()
        self.val_engine_input = QLineEdit()
        self.btn_val_engine = QPushButton("📂 Browse")
        self.btn_val_engine.clicked.connect(self.select_val_engine)
        val_engine_layout.addWidget(self.val_engine_input)
        val_engine_layout.addWidget(self.btn_val_engine)
        form.addRow("🎯 Engine Path:", val_engine_layout)

        self.val_resize_input = QLineEdit("800, 800")
        self.val_mean_input = QLineEdit("0.5, 0.5, 0.5")
        self.val_std_input = QLineEdit("1.0, 1.0, 1.0")
        form.addRow("📏 Resize (W, H):", self.val_resize_input)
        form.addRow("🌓 Mean (RGB):", self.val_mean_input)
        form.addRow("🏁 Std (RGB):", self.val_std_input)

        self.val_task_combo = QComboBox()
        self.val_task_combo.addItems(["Classification", "Detection", "Segmentation", "Anomaly Detection"])
        form.addRow("🎯 Task Type:", self.val_task_combo)

        # Pixel Diff Threshold
        threshold_layout = QHBoxLayout()
        from PyQt5.QtWidgets import QDoubleSpinBox
        self.val_threshold_spinbox = QDoubleSpinBox()
        self.val_threshold_spinbox.setRange(0.1, 100.0)
        self.val_threshold_spinbox.setSingleStep(0.5)
        self.val_threshold_spinbox.setValue(5.0)
        self.val_threshold_spinbox.setSuffix(" %")
        self.val_threshold_spinbox.setFixedWidth(120)
        threshold_layout.addWidget(self.val_threshold_spinbox)
        threshold_layout.addWidget(QLabel("(Classification/Detection: MaxDiff 기준 | Anomaly: 픽셀별 절댓값 차이 기준)"))
        threshold_layout.addStretch()
        form.addRow("📊 Pixel Diff Threshold:", threshold_layout)

        # Config Load / Save / Refresh
        val_config_layout = QHBoxLayout()
        self.val_config_combo = QComboBox()
        self.val_config_combo.setMinimumWidth(300)
        btn_val_load_config = QPushButton("📂 Load")
        btn_val_load_config.setFixedWidth(100)
        btn_val_load_config.clicked.connect(self.load_val_config)
        btn_val_save_config = QPushButton("💾 Save")
        btn_val_save_config.setFixedWidth(100)
        btn_val_save_config.clicked.connect(self.save_val_config)
        btn_val_refresh_config = QPushButton("🔄 Refresh")
        btn_val_refresh_config.setFixedWidth(100)
        btn_val_refresh_config.clicked.connect(self.refresh_val_config_list)
        val_config_layout.addWidget(self.val_config_combo)
        val_config_layout.addWidget(btn_val_load_config)
        val_config_layout.addWidget(btn_val_save_config)
        val_config_layout.addWidget(btn_val_refresh_config)
        form.addRow("📁 Config:", val_config_layout)

        layout.addLayout(form)

        self.btn_val_run = QPushButton("🔍 Run Inference & Compare")
        self.btn_val_run.setObjectName("RunButton")
        self.btn_val_run.clicked.connect(self.run_validation)
        layout.addWidget(self.btn_val_run)

        self.val_progress = QProgressBar()
        layout.addWidget(self.val_progress)

        self.val_log_output = QTextEdit()
        self.val_log_output.setReadOnly(True)
        self.val_log_output.setObjectName("LogConsole")
        layout.addWidget(self.val_log_output)

    def setup_sim_tab(self):
        layout = QVBoxLayout(self.sim_tab)
        layout.setSpacing(15)

        # =======================================
        # 📦 1. Model & Paths Group
        # =======================================
        path_group = QGroupBox("📦 Model & Paths")
        path_group.setStyleSheet("QGroupBox { font-weight: bold; border: 1px solid #45475a; border-radius: 6px; margin-top: 10px; } QGroupBox::title { subcontrol-origin: margin; left: 10px; padding: 0 5px 0 5px; }")
        path_layout = QVBoxLayout()
        path_layout.setContentsMargins(15, 20, 15, 15)

        # Engine 경로
        engine_hbox = QHBoxLayout()
        engine_lbl = QLabel("🎯 Engine Path:")
        engine_lbl.setFixedWidth(110)
        self.sim_engine_input = QLineEdit()
        self.sim_engine_input.setPlaceholderText("TensorRT Engine (.trt / .engine) 경로...")
        btn_sim_engine = QPushButton("📂 Browse")
        btn_sim_engine.setFixedWidth(100)
        btn_sim_engine.clicked.connect(self.select_sim_engine)
        engine_hbox.addWidget(engine_lbl)
        engine_hbox.addWidget(self.sim_engine_input)
        engine_hbox.addWidget(btn_sim_engine)
        path_layout.addLayout(engine_hbox)

        # 이미지 폴더
        img_hbox = QHBoxLayout()
        img_lbl = QLabel("🖼️ Image Folder:")
        img_lbl.setFixedWidth(110)
        self.sim_img_folder_input = QLineEdit()
        self.sim_img_folder_input.setPlaceholderText("추론할 이미지가 들어있는 폴더...")
        btn_sim_img = QPushButton("📂 Select Folder")
        btn_sim_img.setFixedWidth(120)
        btn_sim_img.clicked.connect(self.select_sim_img_folder)
        img_hbox.addWidget(img_lbl)
        img_hbox.addWidget(self.sim_img_folder_input)
        img_hbox.addWidget(btn_sim_img)
        path_layout.addLayout(img_hbox)

        # 저장 폴더
        save_hbox = QHBoxLayout()
        save_lbl = QLabel("💾 Save Folder:")
        save_lbl.setFixedWidth(110)
        self.sim_save_folder_input = QLineEdit()
        self.sim_save_folder_input.setPlaceholderText("결과 저장 폴더 (하위에 날짜 폴더 자동 생성)...")
        btn_sim_save = QPushButton("📂 Select Folder")
        btn_sim_save.setFixedWidth(120)
        btn_sim_save.clicked.connect(self.select_sim_save_folder)
        save_hbox.addWidget(save_lbl)
        save_hbox.addWidget(self.sim_save_folder_input)
        save_hbox.addWidget(btn_sim_save)
        path_layout.addLayout(save_hbox)

        path_group.setLayout(path_layout)
        layout.addWidget(path_group)

        # =======================================
        # ⚙️ 2. Preprocessing Config Group
        # =======================================
        preproc_group = QGroupBox("⚙️ Preprocessing Config")
        preproc_group.setStyleSheet("QGroupBox { font-weight: bold; border: 1px solid #45475a; border-radius: 6px; margin-top: 10px; } QGroupBox::title { subcontrol-origin: margin; left: 10px; padding: 0 5px 0 5px; }")
        preproc_layout = QVBoxLayout()
        preproc_layout.setContentsMargins(15, 20, 15, 15)

        # Resize & Mean & Std (한 줄)
        row_hbox = QHBoxLayout()
        resize_lbl = QLabel("📏 Resize (W,H):")
        resize_lbl.setFixedWidth(110)
        self.sim_resize_input = QLineEdit("224, 224")
        self.sim_resize_input.setFixedWidth(120)

        mean_lbl = QLabel("🌓 Mean (RGB):")
        mean_lbl.setFixedWidth(100)
        self.sim_mean_input = QLineEdit("0.5, 0.5, 0.5")
        self.sim_mean_input.setFixedWidth(150)

        std_lbl = QLabel("🏁 Std (RGB):")
        std_lbl.setFixedWidth(90)
        self.sim_std_input = QLineEdit("1.0, 1.0, 1.0")
        self.sim_std_input.setFixedWidth(150)

        row_hbox.addWidget(resize_lbl)
        row_hbox.addWidget(self.sim_resize_input)
        row_hbox.addSpacing(20)
        row_hbox.addWidget(mean_lbl)
        row_hbox.addWidget(self.sim_mean_input)
        row_hbox.addSpacing(20)
        row_hbox.addWidget(std_lbl)
        row_hbox.addWidget(self.sim_std_input)
        row_hbox.addStretch()
        preproc_layout.addLayout(row_hbox)

        # Config 불러오기/저장 버튼
        config_hbox = QHBoxLayout()
        self.sim_config_combo = QComboBox()
        self.sim_config_combo.setMinimumWidth(300)
        btn_sim_load_config = QPushButton("📂 Load")
        btn_sim_load_config.setFixedWidth(100)
        btn_sim_load_config.clicked.connect(self.load_sim_config)
        btn_sim_save_config = QPushButton("💾 Save")
        btn_sim_save_config.setFixedWidth(100)
        btn_sim_save_config.clicked.connect(self.save_sim_config)
        btn_sim_refresh_config = QPushButton("🔄 Refresh")
        btn_sim_refresh_config.setFixedWidth(100)
        btn_sim_refresh_config.clicked.connect(self.refresh_sim_config_list)
        config_hbox.addWidget(QLabel("📁 Config:  "))
        config_hbox.addWidget(self.sim_config_combo)
        config_hbox.addWidget(btn_sim_load_config)
        config_hbox.addWidget(btn_sim_save_config)
        config_hbox.addWidget(btn_sim_refresh_config)
        config_hbox.addStretch()
        preproc_layout.addLayout(config_hbox)

        preproc_group.setLayout(preproc_layout)
        layout.addWidget(preproc_group)

        # =======================================
        # 🏷️ 3. Class Names Group
        # =======================================
        class_group = QGroupBox("🏷️ Class Configuration")
        class_group.setStyleSheet("QGroupBox { font-weight: bold; border: 1px solid #45475a; border-radius: 6px; margin-top: 10px; } QGroupBox::title { subcontrol-origin: margin; left: 10px; padding: 0 5px 0 5px; }")
        class_outer_layout = QVBoxLayout()
        class_outer_layout.setContentsMargins(15, 20, 15, 15)

        # 클래스 개수 입력
        num_hbox = QHBoxLayout()
        num_lbl = QLabel("🔢 Number of Classes:")
        num_lbl.setFixedWidth(140)
        self.sim_class_num_spin = QSpinBox()
        self.sim_class_num_spin.setRange(1, 50)
        self.sim_class_num_spin.setValue(3)
        self.sim_class_num_spin.setFixedWidth(80)
        self.sim_class_num_spin.valueChanged.connect(self.update_class_name_inputs)
        btn_apply_class = QPushButton("✅ Apply")
        btn_apply_class.setFixedWidth(120)
        btn_apply_class.clicked.connect(self.update_class_name_inputs)
        num_hbox.addWidget(num_lbl)
        num_hbox.addWidget(self.sim_class_num_spin)
        num_hbox.addWidget(btn_apply_class)
        num_hbox.addStretch()
        class_outer_layout.addLayout(num_hbox)

        # 클래스명 입력 영역 (스크롤 가능)
        self.sim_class_name_container = QWidget()
        self.sim_class_name_layout = QVBoxLayout(self.sim_class_name_container)
        self.sim_class_name_layout.setContentsMargins(0, 5, 0, 5)
        self.sim_class_name_layout.setSpacing(5)

        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setWidget(self.sim_class_name_container)
        scroll.setMaximumHeight(150)
        scroll.setStyleSheet("QScrollArea { border: 1px solid #45475a; border-radius: 4px; }")
        class_outer_layout.addWidget(scroll)

        class_group.setLayout(class_outer_layout)
        layout.addWidget(class_group)

        # 초기 클래스명 입력칸 생성
        self.sim_class_name_inputs = []
        self.update_class_name_inputs()

        # =======================================
        # 🚀 4. Run & Logs
        # =======================================
        self.btn_sim_run = QPushButton("🚀 Run Engine Simulation")
        self.btn_sim_run.setObjectName("RunButton")
        self.btn_sim_run.clicked.connect(self.run_simulation)
        layout.addWidget(self.btn_sim_run)

        self.sim_progress = QProgressBar()
        layout.addWidget(self.sim_progress)

        self.sim_log_output = QTextEdit()
        self.sim_log_output.setReadOnly(True)
        self.sim_log_output.setObjectName("LogConsole")
        layout.addWidget(self.sim_log_output)

    def setup_gradcam_tab(self):
        root_layout = QVBoxLayout(self.gradcam_tab)
        root_layout.setContentsMargins(0, 0, 0, 0)

        # 전체 탭 스크롤
        tab_scroll = QScrollArea()
        tab_scroll.setWidgetResizable(True)
        tab_scroll.setStyleSheet("QScrollArea { border: none; }")

        tab_content = QWidget()
        layout = QVBoxLayout(tab_content)
        layout.setSpacing(15)
        layout.setContentsMargins(12, 12, 12, 12)

        # =======================================
        # 📦 1. Model & Paths Group
        # =======================================
        path_group = QGroupBox("📦 Model & Paths")
        path_group.setStyleSheet("QGroupBox { font-weight: bold; border: 1px solid #45475a; border-radius: 6px; margin-top: 10px; } QGroupBox::title { subcontrol-origin: margin; left: 10px; padding: 0 5px 0 5px; }")
        path_layout = QVBoxLayout()
        path_layout.setContentsMargins(15, 20, 15, 15)

        # ONNX 경로
        onnx_hbox = QHBoxLayout()
        onnx_lbl = QLabel("📦 ONNX Path:")
        onnx_lbl.setFixedWidth(110)
        self.gradcam_onnx_input = QLineEdit()
        self.gradcam_onnx_input.setPlaceholderText("Grad-CAM 대상 ONNX 파일 경로...")
        btn_gradcam_onnx = QPushButton("📂 Browse")
        btn_gradcam_onnx.setFixedWidth(100)
        btn_gradcam_onnx.clicked.connect(self.select_gradcam_onnx)
        onnx_hbox.addWidget(onnx_lbl)
        onnx_hbox.addWidget(self.gradcam_onnx_input)
        onnx_hbox.addWidget(btn_gradcam_onnx)
        path_layout.addLayout(onnx_hbox)

        # 이미지 폴더
        img_hbox = QHBoxLayout()
        img_lbl = QLabel("🖼️ Image Folder:")
        img_lbl.setFixedWidth(110)
        self.gradcam_img_folder_input = QLineEdit()
        self.gradcam_img_folder_input.setPlaceholderText("Grad-CAM 처리할 이미지 폴더...")
        btn_gradcam_img = QPushButton("📂 Select Folder")
        btn_gradcam_img.setFixedWidth(120)
        btn_gradcam_img.clicked.connect(self.select_gradcam_img_folder)
        img_hbox.addWidget(img_lbl)
        img_hbox.addWidget(self.gradcam_img_folder_input)
        img_hbox.addWidget(btn_gradcam_img)
        path_layout.addLayout(img_hbox)

        # 저장 폴더
        save_hbox = QHBoxLayout()
        save_lbl = QLabel("💾 Save Folder:")
        save_lbl.setFixedWidth(110)
        self.gradcam_save_folder_input = QLineEdit()
        self.gradcam_save_folder_input.setPlaceholderText("Grad-CAM 결과 PNG 저장 폴더...")
        btn_gradcam_save = QPushButton("📂 Select Folder")
        btn_gradcam_save.setFixedWidth(120)
        btn_gradcam_save.clicked.connect(self.select_gradcam_save_folder)
        save_hbox.addWidget(save_lbl)
        save_hbox.addWidget(self.gradcam_save_folder_input)
        save_hbox.addWidget(btn_gradcam_save)
        path_layout.addLayout(save_hbox)

        path_group.setLayout(path_layout)
        layout.addWidget(path_group)

        # =======================================
        # ⚙️ 2. Preprocessing Config Group
        # =======================================
        preproc_group = QGroupBox("⚙️ Preprocessing Config")
        preproc_group.setStyleSheet("QGroupBox { font-weight: bold; border: 1px solid #45475a; border-radius: 6px; margin-top: 10px; } QGroupBox::title { subcontrol-origin: margin; left: 10px; padding: 0 5px 0 5px; }")
        preproc_layout = QVBoxLayout()
        preproc_layout.setContentsMargins(15, 20, 15, 15)

        row_hbox = QHBoxLayout()
        resize_lbl = QLabel("📏 Resize (W,H):")
        resize_lbl.setFixedWidth(110)
        self.gradcam_resize_input = QLineEdit("224, 224")
        self.gradcam_resize_input.setFixedWidth(120)

        mean_lbl = QLabel("🌓 Mean (RGB):")
        mean_lbl.setFixedWidth(100)
        self.gradcam_mean_input = QLineEdit("0.5, 0.5, 0.5")
        self.gradcam_mean_input.setFixedWidth(150)

        std_lbl = QLabel("🏁 Std (RGB):")
        std_lbl.setFixedWidth(90)
        self.gradcam_std_input = QLineEdit("1.0, 1.0, 1.0")
        self.gradcam_std_input.setFixedWidth(150)

        row_hbox.addWidget(resize_lbl)
        row_hbox.addWidget(self.gradcam_resize_input)
        row_hbox.addSpacing(20)
        row_hbox.addWidget(mean_lbl)
        row_hbox.addWidget(self.gradcam_mean_input)
        row_hbox.addSpacing(20)
        row_hbox.addWidget(std_lbl)
        row_hbox.addWidget(self.gradcam_std_input)
        row_hbox.addStretch()
        preproc_layout.addLayout(row_hbox)

        meta_row = QHBoxLayout()
        meta_row.addWidget(QLabel("📐 Fixed Input Shape (N,C,H,W):"))
        self.gradcam_input_shape_input = QLineEdit()
        self.gradcam_input_shape_input.setPlaceholderText("비워두면 자동 사용 / 예: 1,3,224,224")
        self.gradcam_input_shape_input.setFixedWidth(220)
        meta_row.addWidget(self.gradcam_input_shape_input)
        meta_row.addStretch()
        preproc_layout.addLayout(meta_row)

        # Config 불러오기/저장 버튼 (Meta 입력 아래)
        config_hbox = QHBoxLayout()
        self.gradcam_config_combo = QComboBox()
        self.gradcam_config_combo.setMinimumWidth(300)
        btn_gradcam_load_config = QPushButton("📂 Load")
        btn_gradcam_load_config.setFixedWidth(100)
        btn_gradcam_load_config.clicked.connect(self.load_gradcam_config)
        btn_gradcam_save_config = QPushButton("💾 Save")
        btn_gradcam_save_config.setFixedWidth(100)
        btn_gradcam_save_config.clicked.connect(self.save_gradcam_config)
        btn_gradcam_refresh_config = QPushButton("🔄 Refresh")
        btn_gradcam_refresh_config.setFixedWidth(100)
        btn_gradcam_refresh_config.clicked.connect(self.refresh_gradcam_config_list)
        config_hbox.addWidget(QLabel("📁 Config:  "))
        config_hbox.addWidget(self.gradcam_config_combo)
        config_hbox.addWidget(btn_gradcam_load_config)
        config_hbox.addWidget(btn_gradcam_save_config)
        config_hbox.addWidget(btn_gradcam_refresh_config)
        config_hbox.addStretch()
        preproc_layout.addLayout(config_hbox)

        preproc_group.setLayout(preproc_layout)
        layout.addWidget(preproc_group)

        # =======================================
        # 🏷️ 3. Class & Layer Group
        # =======================================
        class_layer_group = QGroupBox("🏷️ Target Class & Layer")
        class_layer_group.setStyleSheet("QGroupBox { font-weight: bold; border: 1px solid #45475a; border-radius: 6px; margin-top: 10px; } QGroupBox::title { subcontrol-origin: margin; left: 10px; padding: 0 5px 0 5px; }")
        class_layer_layout = QVBoxLayout()
        class_layer_layout.setContentsMargins(15, 20, 15, 15)

        # Target class
        class_hbox = QHBoxLayout()
        class_lbl = QLabel("🎯 Target Class:")
        class_lbl.setFixedWidth(110)
        self.gradcam_target_class_spin = QSpinBox()
        self.gradcam_target_class_spin.setRange(0, 9999)
        self.gradcam_target_class_spin.setValue(0)
        self.gradcam_target_class_spin.setFixedWidth(100)
        class_hbox.addWidget(class_lbl)
        class_hbox.addWidget(self.gradcam_target_class_spin)
        class_hbox.addStretch()
        class_layer_layout.addLayout(class_hbox)

        layer_widget = QWidget()
        left_layer_layout = QVBoxLayout(layer_widget)
        left_layer_layout.setContentsMargins(0, 0, 0, 0)
        left_layer_layout.setSpacing(8)

        # Layer 로드/선택
        layer_btn_hbox = QHBoxLayout()
        left_layer_layout.addWidget(QLabel("🧩 Layer Selection:"))
        btn_load_layers = QPushButton("🔄 Load Layers (Reverse)")
        btn_load_layers.setFixedWidth(220)
        btn_load_layers.clicked.connect(self.load_gradcam_layers)
        layer_btn_hbox.addWidget(btn_load_layers)
        layer_btn_hbox.addStretch()
        left_layer_layout.addLayout(layer_btn_hbox)

        layer_select_hbox = QHBoxLayout()
        layer_select_hbox.addWidget(QLabel("🧩 Target Layer:"))
        self.gradcam_layer_combo = QComboBox()
        self.gradcam_layer_combo.setMinimumWidth(600)
        layer_select_hbox.addWidget(self.gradcam_layer_combo)
        left_layer_layout.addLayout(layer_select_hbox)

        self.gradcam_layer_output = QTextEdit()
        self.gradcam_layer_output.setReadOnly(True)
        self.gradcam_layer_output.setMinimumHeight(180)
        self.gradcam_layer_output.setMaximumHeight(280)
        self.gradcam_layer_output.setObjectName("LogConsole")
        left_layer_layout.addWidget(self.gradcam_layer_output)
        class_layer_layout.addWidget(layer_widget)

        class_layer_group.setLayout(class_layer_layout)
        layout.addWidget(class_layer_group)

        # =======================================
        # 🚀 4. Run
        # =======================================
        self.btn_gradcam_run = QPushButton("🧠 Run ONNX-gradCam")
        self.btn_gradcam_run.setObjectName("RunButton")
        self.btn_gradcam_run.clicked.connect(self.run_gradcam)
        layout.addWidget(self.btn_gradcam_run)

        self.gradcam_progress = QProgressBar()
        layout.addWidget(self.gradcam_progress)

        # =======================================
        # 🖼️ 5. CAM Viewer (Scroll)
        # =======================================
        viewer_group = QGroupBox("🖼️ CAM Viewer")
        viewer_group.setStyleSheet("QGroupBox { font-weight: bold; border: 1px solid #45475a; border-radius: 6px; margin-top: 10px; } QGroupBox::title { subcontrol-origin: margin; left: 10px; padding: 0 5px 0 5px; }")
        viewer_layout = QVBoxLayout()
        viewer_layout.setContentsMargins(15, 20, 15, 15)

        viewer_ctrl_hbox = QHBoxLayout()
        self.btn_gradcam_prev = QPushButton("⬅️ Prev")
        self.btn_gradcam_prev.setFixedWidth(100)
        self.btn_gradcam_prev.clicked.connect(self.show_prev_gradcam_image)
        self.btn_gradcam_next = QPushButton("Next ➡️")
        self.btn_gradcam_next.setFixedWidth(100)
        self.btn_gradcam_next.clicked.connect(self.show_next_gradcam_image)
        self.gradcam_view_combo = QComboBox()
        self.gradcam_view_combo.currentIndexChanged.connect(self.on_gradcam_view_combo_changed)

        viewer_ctrl_hbox.addWidget(self.btn_gradcam_prev)
        viewer_ctrl_hbox.addWidget(self.btn_gradcam_next)
        viewer_ctrl_hbox.addWidget(self.gradcam_view_combo)
        viewer_ctrl_hbox.addStretch()
        viewer_layout.addLayout(viewer_ctrl_hbox)

        # CAM Viewer를 환경 해상도에 맞는 고정 크기로 유지
        self.gradcam_view_width, self.gradcam_view_height = self.get_gradcam_viewer_size()

        self.gradcam_image_label = QLabel("Grad-CAM 결과가 여기에 표시됩니다.")
        self.gradcam_image_label.setAlignment(Qt.AlignCenter)
        self.gradcam_image_label.setFixedSize(self.gradcam_view_width, self.gradcam_view_height)

        self.gradcam_viewer_scroll = QScrollArea()
        self.gradcam_viewer_scroll.setWidgetResizable(False)
        self.gradcam_viewer_scroll.setWidget(self.gradcam_image_label)
        self.gradcam_viewer_scroll.setFixedHeight(self.gradcam_view_height + 30)
        self.gradcam_viewer_scroll.setStyleSheet("QScrollArea { border: 1px solid #45475a; border-radius: 4px; }")
        viewer_layout.addWidget(self.gradcam_viewer_scroll)

        viewer_group.setLayout(viewer_layout)
        layout.addWidget(viewer_group)

        # =======================================
        # 🧾 6. Command Log (Bottom)
        # =======================================
        self.gradcam_log_output = QTextEdit()
        self.gradcam_log_output.setReadOnly(True)
        self.gradcam_log_output.setObjectName("LogConsole")
        self.gradcam_log_output.setMinimumHeight(180)
        layout.addWidget(self.gradcam_log_output)

        layout.addStretch()

        tab_scroll.setWidget(tab_content)
        root_layout.addWidget(tab_scroll)

        self.gradcam_view_files = []
        self.gradcam_view_index = -1
        self._update_gradcam_viewer_buttons()

    def get_gradcam_viewer_size(self):
        """현재 창 크기에 맞춰 Grad-CAM 뷰어 고정 크기를 계산합니다."""
        current_width = max(self.width(), 1400)
        current_height = max(self.height(), 900)

        width = min(1600, max(1000, int(current_width * 0.86)))
        height = min(900, max(480, int(current_height * 0.52)))
        return width, height

    def update_gradcam_viewer_size(self):
        if not hasattr(self, 'gradcam_image_label'):
            return

        new_width, new_height = self.get_gradcam_viewer_size()
        if (new_width, new_height) == (self.gradcam_view_width, self.gradcam_view_height):
            return

        self.gradcam_view_width = new_width
        self.gradcam_view_height = new_height
        self.gradcam_image_label.setFixedSize(self.gradcam_view_width, self.gradcam_view_height)

        if hasattr(self, 'gradcam_viewer_scroll'):
            self.gradcam_viewer_scroll.setFixedHeight(self.gradcam_view_height + 30)

        if 0 <= getattr(self, 'gradcam_view_index', -1) < len(getattr(self, 'gradcam_view_files', [])):
            self._show_gradcam_image_by_index(self.gradcam_view_index)

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self.update_gradcam_viewer_size()

    def setup_smw_sim_tab(self):
        """SMW Simulation 탭 설정 - 배치 추론용"""
        layout = QVBoxLayout(self.smw_sim_tab)
        layout.setSpacing(15)

        # =======================================
        # 📦 1. Model & Paths Group
        # =======================================
        path_group = QGroupBox("📦 Model & Paths")
        path_group.setStyleSheet("QGroupBox { font-weight: bold; border: 1px solid #45475a; border-radius: 6px; margin-top: 10px; } QGroupBox::title { subcontrol-origin: margin; left: 10px; padding: 0 5px 0 5px; }")
        path_layout = QVBoxLayout()
        path_layout.setContentsMargins(15, 20, 15, 15)

        # Engine 경로
        engine_hbox = QHBoxLayout()
        engine_lbl = QLabel("🎯 Engine Path:")
        engine_lbl.setFixedWidth(110)
        self.smw_engine_input = QLineEdit()
        self.smw_engine_input.setPlaceholderText("TensorRT Engine (.trt / .engine) 경로...")
        btn_smw_engine = QPushButton("📂 Browse")
        btn_smw_engine.setFixedWidth(100)
        btn_smw_engine.clicked.connect(self.select_smw_engine)
        engine_hbox.addWidget(engine_lbl)
        engine_hbox.addWidget(self.smw_engine_input)
        engine_hbox.addWidget(btn_smw_engine)
        path_layout.addLayout(engine_hbox)

        # 이미지 폴더
        img_hbox = QHBoxLayout()
        img_lbl = QLabel("🖼️ Image Folder:")
        img_lbl.setFixedWidth(110)
        self.smw_img_folder_input = QLineEdit()
        self.smw_img_folder_input.setPlaceholderText("추론할 이미지가 들어있는 폴더...")
        btn_smw_img = QPushButton("📂 Select Folder")
        btn_smw_img.setFixedWidth(120)
        btn_smw_img.clicked.connect(self.select_smw_img_folder)
        img_hbox.addWidget(img_lbl)
        img_hbox.addWidget(self.smw_img_folder_input)
        img_hbox.addWidget(btn_smw_img)
        path_layout.addLayout(img_hbox)

        # 저장 폴더
        save_hbox = QHBoxLayout()
        save_lbl = QLabel("💾 Save Folder:")
        save_lbl.setFixedWidth(110)
        self.smw_save_folder_input = QLineEdit()
        self.smw_save_folder_input.setPlaceholderText("결과 저장 폴더 (하위에 날짜 폴더 자동 생성)...")
        btn_smw_save = QPushButton("📂 Select Folder")
        btn_smw_save.setFixedWidth(120)
        btn_smw_save.clicked.connect(self.select_smw_save_folder)
        save_hbox.addWidget(save_lbl)
        save_hbox.addWidget(self.smw_save_folder_input)
        save_hbox.addWidget(btn_smw_save)
        path_layout.addLayout(save_hbox)

        path_group.setLayout(path_layout)
        layout.addWidget(path_group)

        # =======================================
        # ⚙️ 2. Preprocessing Config Group
        # =======================================
        preproc_group = QGroupBox("⚙️ Preprocessing Config")
        preproc_group.setStyleSheet("QGroupBox { font-weight: bold; border: 1px solid #45475a; border-radius: 6px; margin-top: 10px; } QGroupBox::title { subcontrol-origin: margin; left: 10px; padding: 0 5px 0 5px; }")
        preproc_layout = QVBoxLayout()
        preproc_layout.setContentsMargins(15, 20, 15, 15)

        # Resize & Mean & Std & Patch 개수 (한 줄)
        row_hbox = QHBoxLayout()
        resize_lbl = QLabel("📏 Resize (W,H):")
        resize_lbl.setFixedWidth(110)
        self.smw_resize_input = QLineEdit("224, 224")
        self.smw_resize_input.setFixedWidth(100)

        mean_lbl = QLabel("🌓 Mean:")
        mean_lbl.setFixedWidth(50)
        self.smw_mean_input = QLineEdit("0.5, 0.5, 0.5")
        self.smw_mean_input.setFixedWidth(130)

        std_lbl = QLabel("🏁 Std:")
        std_lbl.setFixedWidth(40)
        self.smw_std_input = QLineEdit("1.0, 1.0, 1.0")
        self.smw_std_input.setFixedWidth(130)

        patch_lbl = QLabel("🔢 Patches:")
        patch_lbl.setFixedWidth(70)
        self.smw_patch_spin = QSpinBox()
        self.smw_patch_spin.setRange(1, 200)
        self.smw_patch_spin.setValue(56)
        self.smw_patch_spin.setFixedWidth(70)

        row_hbox.addWidget(resize_lbl)
        row_hbox.addWidget(self.smw_resize_input)
        row_hbox.addSpacing(10)
        row_hbox.addWidget(mean_lbl)
        row_hbox.addWidget(self.smw_mean_input)
        row_hbox.addSpacing(10)
        row_hbox.addWidget(std_lbl)
        row_hbox.addWidget(self.smw_std_input)
        row_hbox.addSpacing(10)
        row_hbox.addWidget(patch_lbl)
        row_hbox.addWidget(self.smw_patch_spin)
        row_hbox.addStretch()
        preproc_layout.addLayout(row_hbox)

        # Config 불러오기/저장 버튼
        config_hbox = QHBoxLayout()
        self.smw_config_combo = QComboBox()
        self.smw_config_combo.setMinimumWidth(300)
        btn_smw_load_config = QPushButton("📂 Load")
        btn_smw_load_config.setFixedWidth(100)
        btn_smw_load_config.clicked.connect(self.load_smw_config)
        btn_smw_save_config = QPushButton("💾 Save")
        btn_smw_save_config.setFixedWidth(100)
        btn_smw_save_config.clicked.connect(self.save_smw_config)
        btn_smw_refresh_config = QPushButton("🔄 Refresh")
        btn_smw_refresh_config.setFixedWidth(100)
        btn_smw_refresh_config.clicked.connect(self.refresh_smw_config_list)
        config_hbox.addWidget(QLabel("📁 Config:  "))
        config_hbox.addWidget(self.smw_config_combo)
        config_hbox.addWidget(btn_smw_load_config)
        config_hbox.addWidget(btn_smw_save_config)
        config_hbox.addWidget(btn_smw_refresh_config)
        config_hbox.addStretch()
        preproc_layout.addLayout(config_hbox)

        preproc_group.setLayout(preproc_layout)
        layout.addWidget(preproc_group)

        # =======================================
        # 🏷️ 3. Class & Threshold Configuration
        # =======================================
        class_group = QGroupBox("🏷️ Class & Threshold Configuration")
        class_group.setStyleSheet("QGroupBox { font-weight: bold; border: 1px solid #45475a; border-radius: 6px; margin-top: 10px; } QGroupBox::title { subcontrol-origin: margin; left: 10px; padding: 0 5px 0 5px; }")
        class_outer_layout = QVBoxLayout()
        class_outer_layout.setContentsMargins(15, 20, 15, 15)

        # 클래스 개수 입력 및 OK 클래스 선택
        num_hbox = QHBoxLayout()
        num_lbl = QLabel("🔢 Number of Classes:")
        num_lbl.setFixedWidth(140)
        self.smw_class_num_spin = QSpinBox()
        self.smw_class_num_spin.setRange(2, 20)
        self.smw_class_num_spin.setValue(7)
        self.smw_class_num_spin.setFixedWidth(70)
        self.smw_class_num_spin.valueChanged.connect(self.update_smw_class_inputs)
        
        ok_lbl = QLabel("  ✅ OK Class Index:")
        ok_lbl.setFixedWidth(120)
        self.smw_ok_class_spin = QSpinBox()
        self.smw_ok_class_spin.setRange(0, 19)
        self.smw_ok_class_spin.setValue(5)
        self.smw_ok_class_spin.setFixedWidth(70)
        self.smw_ok_class_spin.setToolTip("정상(OK) 클래스의 인덱스 (0부터 시작)")
        
        btn_apply_class = QPushButton("✅ Apply")
        btn_apply_class.setFixedWidth(100)
        btn_apply_class.clicked.connect(self.update_smw_class_inputs)
        
        num_hbox.addWidget(num_lbl)
        num_hbox.addWidget(self.smw_class_num_spin)
        num_hbox.addWidget(ok_lbl)
        num_hbox.addWidget(self.smw_ok_class_spin)
        num_hbox.addWidget(btn_apply_class)
        num_hbox.addStretch()
        class_outer_layout.addLayout(num_hbox)

        # 클래스명 + Threshold 입력 영역 (스크롤 가능)
        self.smw_class_name_container = QWidget()
        self.smw_class_name_layout = QVBoxLayout(self.smw_class_name_container)
        self.smw_class_name_layout.setContentsMargins(0, 5, 0, 5)
        self.smw_class_name_layout.setSpacing(5)

        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setWidget(self.smw_class_name_container)
        scroll.setMaximumHeight(200)
        scroll.setStyleSheet("QScrollArea { border: 1px solid #45475a; border-radius: 4px; }")
        class_outer_layout.addWidget(scroll)

        class_group.setLayout(class_outer_layout)
        layout.addWidget(class_group)

        # 초기 클래스명/Threshold 입력칸 생성
        self.smw_class_name_inputs = []
        self.smw_threshold_inputs = []
        self.update_smw_class_inputs()

        # =======================================
        # 🚀 4. Run & Logs
        # =======================================
        # Save Overlay 체크박스
        overlay_hbox = QHBoxLayout()
        self.smw_save_overlay_checkbox = QCheckBox("🎨 Save Overlay (패치별 예측 결과 오버레이 이미지 저장)")
        self.smw_save_overlay_checkbox.setChecked(False)
        self.smw_save_overlay_checkbox.setToolTip("체크 시 패치별 예측 결과를 색상 오버레이로 시각화하여 저장합니다.\n체크 해제 시 원본 이미지가 복사됩니다.")
        overlay_hbox.addWidget(self.smw_save_overlay_checkbox)
        overlay_hbox.addStretch()
        layout.addLayout(overlay_hbox)

        self.btn_smw_run = QPushButton("🔧 Run SMW Simulation (Batch Inference)")
        self.btn_smw_run.setObjectName("RunButton")
        self.btn_smw_run.clicked.connect(self.run_smw_simulation)
        layout.addWidget(self.btn_smw_run)

        self.smw_progress = QProgressBar()
        layout.addWidget(self.smw_progress)

        self.smw_log_output = QTextEdit()
        self.smw_log_output.setReadOnly(True)
        self.smw_log_output.setObjectName("LogConsole")
        layout.addWidget(self.smw_log_output)

    def apply_dark_theme(self):
        self.setStyleSheet("""
            QWidget { background-color: #1e1e2e; color: #cdd6f4; font-family: 'Segoe UI', Arial, sans-serif; font-size: 14px; }
            QLineEdit, QComboBox { background-color: #313244; border: 1px solid #45475a; border-radius: 6px; padding: 8px; color: #cdd6f4; }
            QLineEdit:focus, QComboBox:focus { border: 1px solid #89b4fa; }
            QLineEdit:disabled { background-color: #181825; color: #585b70; border: 1px solid #313244; }
            QCheckBox { spacing: 8px; }
            QCheckBox::indicator { width: 18px; height: 18px; }
            QPushButton { background-color: #45475a; color: #cdd6f4; border: none; border-radius: 6px; padding: 8px 15px; font-weight: bold; }
            QPushButton:hover { background-color: #585b70; }
            #RunButton { background-color: #a6e3a1; color: #11111b; font-size: 16px; padding: 15px; margin-top: 15px; }
            #RunButton:hover { background-color: #94e2d5; }
            #RunButton:disabled { background-color: #45475a; color: #6c7086; }
            #StopButton { background-color: #f38ba8; color: #11111b; font-size: 16px; padding: 15px; margin-top: 15px; }
            #StopButton:hover { background-color: #eba0ac; }
            #StopButton:disabled { background-color: #45475a; color: #6c7086; }
            #LogConsole { background-color: #11111b; color: #a6e3a1; border: 1px solid #313244; border-radius: 6px; font-family: Consolas, 'Courier New', monospace; padding: 10px; }
            QTabWidget::pane { border: 1px solid #45475a; background-color: #1e1e2e; }
            QTabBar::tab { background: #313244; padding: 12px 30px; border-radius: 6px; margin-right: 2px; }
            QTabBar::tab:selected { background: #45475a; color: #89b4fa; border-bottom: 2px solid #89b4fa; font-weight: bold; }
            QProgressBar { border: 1px solid #45475a; border-radius: 5px; text-align: center; color: white; }
            QProgressBar::chunk { background-color: #89b4fa; }
        """)

    def on_gpu_arch_changed(self, arch):
        current_precision = self.precision_combo.currentText()
        self.precision_combo.blockSignals(True)
        self.precision_combo.clear()
        if arch == "Blackwell":
            self.precision_combo.addItems(["FP16", "FP32", "BF16"])
        else:
            self.precision_combo.addItems(["FP16", "FP32"])
        # 기존 선택값 유지 (가능한 경우)
        idx = self.precision_combo.findText(current_precision)
        self.precision_combo.setCurrentIndex(idx if idx >= 0 else 0)
        self.precision_combo.blockSignals(False)
        self.toggle_custom_ui()

    def toggle_custom_ui(self):
        precision = self.precision_combo.currentText()
        can_use_custom = precision in ("FP16", "BF16")
        self.custom_script_cb.setEnabled(can_use_custom)
        if not can_use_custom:
            self.custom_script_cb.setChecked(False)
        self.fp32_keywords_input.setEnabled(self.custom_script_cb.isChecked())

    def toggle_dynamic_batch(self, state):
        is_enabled = (state == Qt.Checked)
        for w in [self.min_shape_input, self.opt_shape_input, self.max_shape_input]: w.setEnabled(is_enabled)

    # --- Validation 탭 로직 ---
    def select_img_folder(self):
        file_path, _ = QFileDialog.getOpenFileName(self, "폴더 안의 이미지를 아무거나 하나 선택하세요", "", "Images (*.png *.jpg *.jpeg *.bmp)")
        if file_path:
            folder = os.path.dirname(file_path)
            self.img_folder_input.setText(folder)
            if not self.val_onnx_input.text() and self.onnx_path_input.text():
                self.val_onnx_input.setText(self.onnx_path_input.text())
            if not self.val_engine_input.text() and self.engine_path_input.text():
                self.val_engine_input.setText(self.engine_path_input.text())

    def select_val_onnx(self):
        path, _ = QFileDialog.getOpenFileName(self, "Select ONNX File", "", "ONNX Files (*.onnx);;All Files (*)")
        if path: self.val_onnx_input.setText(path)

    def select_val_engine(self):
        path, _ = QFileDialog.getOpenFileName(self, "Select Engine/TRT File", "", "TensorRT Engine (*.engine *.trt);;All Files (*)")
        if path: self.val_engine_input.setText(path)

    # ==========================================
    # 🔥 Validation Config Load / Save
    # ==========================================
    def refresh_val_config_list(self):
        self.val_config_combo.clear()
        if os.path.exists(self.config_dir):
            for file in os.listdir(self.config_dir):
                if file.endswith(".json"):
                    self.val_config_combo.addItem(file)

    def load_val_config(self):
        """Config를 읽어와서 Equivalence Checking 탭의 경로/Resize/Mean/Std 등을 세팅합니다."""
        filename = self.val_config_combo.currentText()
        if not filename:
            return
        filepath = os.path.join(self.config_dir, filename)
        try:
            with open(filepath, 'r', encoding='utf-8') as f:
                config_data = json.load(f)

            # ONNX 경로
            onnx_p = config_data.get("onnx_path", "")
            if onnx_p:
                self.val_onnx_input.setText(onnx_p)
            # Engine 경로
            engine_p = config_data.get("engine_path", "")
            if engine_p:
                self.val_engine_input.setText(engine_p)

            # Resize: val_resize 우선, 없으면 opt_shape에서 추출
            val_resize = config_data.get("val_resize", "")
            if val_resize:
                self.val_resize_input.setText(val_resize)
            else:
                opt_shape = config_data.get("opt_shape", "")
                if opt_shape:
                    parts = opt_shape.lower().split('x')
                    if len(parts) == 4:
                        h, w = parts[2], parts[3]
                        self.val_resize_input.setText(f"{w}, {h}")

            # Mean / Std (없으면 기본값)
            self.val_mean_input.setText(config_data.get("val_mean", "0.5, 0.5, 0.5"))
            self.val_std_input.setText(config_data.get("val_std", "1.0, 1.0, 1.0"))

            # Task Type
            task = config_data.get("val_task", "")
            if task:
                idx = self.val_task_combo.findText(task)
                if idx >= 0:
                    self.val_task_combo.setCurrentIndex(idx)

            # Threshold
            self.val_threshold_spinbox.setValue(config_data.get("val_pixel_threshold", 5.0))

            # Image Folder
            img_dir = config_data.get("val_img_dir", "")
            if img_dir:
                self.img_folder_input.setText(img_dir)

            self.val_log_output.append(f"<span style='color: #a6e3a1;'>✅ Config 로드 완료: {filename}</span>")
        except Exception as e:
            self.val_log_output.append(f"<span style='color: #f38ba8;'>❌ Config 로드 실패: {e}</span>")

    def save_val_config(self):
        """현재 선택된 Config 파일에 Equivalence Checking 설정을 덧붙여 덮어씁니다."""
        filename = self.val_config_combo.currentText()
        if not filename:
            return QMessageBox.warning(self, "Error ❌", "Load/Refresh로 Config를 먼저 선택해주세요.")
        filepath = os.path.join(self.config_dir, filename)

        # 기존 Config 읽기
        config_data = {}
        if os.path.exists(filepath):
            try:
                with open(filepath, 'r', encoding='utf-8') as f:
                    config_data = json.load(f)
            except:
                pass

        # Validation 관련 필드 덮어쓰기
        config_data["val_img_dir"] = self.img_folder_input.text()
        config_data["val_resize"] = self.val_resize_input.text()
        config_data["val_mean"] = self.val_mean_input.text()
        config_data["val_std"] = self.val_std_input.text()
        config_data["val_task"] = self.val_task_combo.currentText()
        config_data["val_pixel_threshold"] = self.val_threshold_spinbox.value()

        try:
            with open(filepath, 'w', encoding='utf-8') as f:
                json.dump(config_data, f, indent=4, ensure_ascii=False)
            self.val_log_output.append(f"<span style='color: #a6e3a1;'>✅ Config 저장 완료 (덮어쓰기): {filename}</span>")
        except Exception as e:
            self.val_log_output.append(f"<span style='color: #f38ba8;'>❌ Config 저장 실패: {e}</span>")

    # ==========================================
    # 🔥 Validation 로직: validation_util.py에 위임
    # ==========================================
    def val_log_callback(self, msg):
        """validation_util에서 전달받은 로그 메시지를 HTML 스타일로 변환하여 출력합니다."""
        if msg.startswith("[SUCCESS]"):
            text = msg.replace("[SUCCESS] ", "")
            styled = f"<span style='color: #a6e3a1;'>✅ {text}</span>"
        elif msg.startswith("[WARNING]"):
            text = msg.replace("[WARNING] ", "")
            styled = f"<span style='color: #f9e2af;'>⚠️ {text}</span>"
        elif msg.startswith("[ERROR]"):
            text = msg.replace("[ERROR] ", "")
            styled = f"<span style='color: #f38ba8;'>❌ {text}</span>"
        elif msg.startswith("[CRITICAL]"):
            text = msg.replace("[CRITICAL] ", "")
            styled = f"<span style='color: #f38ba8; font-weight: bold;'>🚨 CRITICAL SPIKE: {text}</span>"
        else:
            styled = msg
        self.val_log_output.append(styled)
        self.val_log_output.verticalScrollBar().setValue(self.val_log_output.verticalScrollBar().maximum())
        QApplication.processEvents()

    def val_progress_callback(self, current, total):
        """validation_util에서 전달받은 진행률을 프로그레스바에 반영합니다."""
        self.val_progress.setMaximum(total)
        self.val_progress.setValue(current)
        QApplication.processEvents()

    def run_validation(self):
        img_dir = self.img_folder_input.text()
        onnx_p = self.val_onnx_input.text()
        trt_p = self.val_engine_input.text()
        task = self.val_task_combo.currentText()

        if not all([os.path.exists(p) for p in [img_dir, onnx_p, trt_p]]):
            QMessageBox.warning(self, "Error ❌", "이미지 폴더 및 모델 경로를 올바르게 지정해주세요.")
            return

        self.val_log_output.clear()
        self.val_log_output.append(f"🚀 Starting Validation ({task})...")
        self.btn_val_run.setEnabled(False)

        result = run_equivalence_check(
            img_dir=img_dir,
            onnx_path=onnx_p,
            trt_path=trt_p,
            task=task,
            resize_str=self.val_resize_input.text(),
            mean_str=self.val_mean_input.text(),
            std_str=self.val_std_input.text(),
            log_callback=self.val_log_callback,
            progress_callback=self.val_progress_callback,
            pixel_diff_threshold=self.val_threshold_spinbox.value()
        )

        if result["success"]:
            csv_path = result["csv_path"]
            self.val_log_output.append(
                f"\n✅ Validation Completed! Results saved to:\n"
                f"<span style='color: #89b4fa;'>{csv_path}</span>"
            )
        else:
            error_msg = result.get("error", "Unknown error")
            self.val_log_output.append(
                f"<span style='color: #f38ba8;'>❌ Validation Failed: {error_msg}</span>"
            )

        self.val_log_output.verticalScrollBar().setValue(self.val_log_output.verticalScrollBar().maximum())
        self.btn_val_run.setEnabled(True)

    # ==========================================
    # 🔥 Engine Simulation 탭 로직
    # ==========================================
    def select_sim_engine(self):
        path, _ = QFileDialog.getOpenFileName(self, "Select Engine/TRT File", "", "TensorRT Engine (*.engine *.trt);;All Files (*)")
        if path:
            self.sim_engine_input.setText(path)

    def select_sim_img_folder(self):
        file_path, _ = QFileDialog.getOpenFileName(self, "폴더 안의 이미지를 아무거나 하나 선택하세요", "", "Images (*.png *.jpg *.jpeg *.bmp)")
        if file_path:
            self.sim_img_folder_input.setText(os.path.dirname(file_path))

    def select_sim_save_folder(self):
        folder = QFileDialog.getExistingDirectory(self, "결과 저장 폴더 선택")
        if folder:
            self.sim_save_folder_input.setText(folder)

    def refresh_sim_config_list(self):
        self.sim_config_combo.clear()
        if os.path.exists(self.config_dir):
            for file in os.listdir(self.config_dir):
                if file.endswith(".json"):
                    self.sim_config_combo.addItem(file)

    def save_sim_config(self):
        """현재 선택된 Config 파일에 Simulation 설정(resize, mean, std, class)을 덧붙여 덮어씁니다."""
        filename = self.sim_config_combo.currentText()
        if not filename:
            return QMessageBox.warning(self, "Error ❌", "Load/Refresh로 Config를 먼저 선택해주세요.")
        filepath = os.path.join(self.config_dir, filename)

        # 기존 Config 읽기 (없으면 빈 dict)
        config_data = {}
        if os.path.exists(filepath):
            try:
                with open(filepath, 'r', encoding='utf-8') as f:
                    config_data = json.load(f)
            except:
                pass

        # Simulation 관련 필드 덮어쓰기 (merge)
        config_data["sim_resize"] = self.sim_resize_input.text()
        config_data["sim_mean"] = self.sim_mean_input.text()
        config_data["sim_std"] = self.sim_std_input.text()
        config_data["sim_class_num"] = self.sim_class_num_spin.value()
        config_data["sim_class_names"] = [le.text().strip() for le in self.sim_class_name_inputs]

        try:
            with open(filepath, 'w', encoding='utf-8') as f:
                json.dump(config_data, f, indent=4, ensure_ascii=False)
            self.sim_log_output.append(f"<span style='color: #a6e3a1;'>✅ Config 저장 완료 (덮어쓰기): {filename}</span>")
        except Exception as e:
            self.sim_log_output.append(f"<span style='color: #f38ba8;'>❌ Config 저장 실패: {e}</span>")

    def load_sim_config(self):
        """Config를 읽어와서 Engine 경로, Resize, Mean, Std, Class 정보를 자동 세팅합니다."""
        filename = self.sim_config_combo.currentText()
        if not filename:
            return
        filepath = os.path.join(self.config_dir, filename)
        try:
            with open(filepath, 'r', encoding='utf-8') as f:
                config_data = json.load(f)

            # 1. 엔진 경로 세팅
            engine_p = config_data.get("engine_path", "")
            if engine_p:
                self.sim_engine_input.setText(engine_p)

            # 2. Resize 세팅 (sim_resize 우선, 없으면 opt_shape에서 추출)
            sim_resize = config_data.get("sim_resize", "")
            if sim_resize:
                self.sim_resize_input.setText(sim_resize)
            else:
                opt_shape = config_data.get("opt_shape", "")
                if opt_shape:
                    parts = opt_shape.lower().split('x')
                    if len(parts) == 4:
                        h, w = parts[2], parts[3]
                        self.sim_resize_input.setText(f"{w}, {h}")

            # 3. Mean / Std 세팅 (없으면 기본값)
            self.sim_mean_input.setText(config_data.get("sim_mean", "0.5, 0.5, 0.5"))
            self.sim_std_input.setText(config_data.get("sim_std", "1.0, 1.0, 1.0"))

            # 4. Class 정보 세팅
            class_num = config_data.get("sim_class_num", 0)
            class_names = config_data.get("sim_class_names", [])
            if class_num > 0 and class_names:
                self.sim_class_num_spin.setValue(class_num)
                # update_class_name_inputs가 자동 호출되지만 값이 비어있으므로 수동 세팅
                self.update_class_name_inputs()
                for i, le in enumerate(self.sim_class_name_inputs):
                    if i < len(class_names):
                        le.setText(class_names[i])

            self.sim_log_output.append(f"<span style='color: #a6e3a1;'>✅ Config 로드 완료: {filename}</span>")
        except Exception as e:
            self.sim_log_output.append(f"<span style='color: #f38ba8;'>❌ Config 로드 실패: {e}</span>")

    def update_class_name_inputs(self):
        """클래스 개수에 맞게 클래스명 입력칸을 동적으로 생성합니다."""
        num_classes = self.sim_class_num_spin.value()

        # 기존 입력값 백업
        old_values = [le.text() for le in self.sim_class_name_inputs]

        # 기존 위젯 모두 제거
        for le in self.sim_class_name_inputs:
            le.setParent(None)
            le.deleteLater()
        # 레이아웃 내 남은 아이템 정리
        while self.sim_class_name_layout.count():
            item = self.sim_class_name_layout.takeAt(0)
            w = item.widget()
            if w:
                w.setParent(None)
                w.deleteLater()

        self.sim_class_name_inputs = []
        default_names = ["OK", "NG"]

        for i in range(num_classes):
            hbox_widget = QWidget()
            hbox = QHBoxLayout(hbox_widget)
            hbox.setContentsMargins(0, 0, 0, 0)
            lbl = QLabel(f"Class {i}:")
            lbl.setFixedWidth(60)
            le = QLineEdit()
            # 이전 값 복원, 없으면 기본값
            if i < len(old_values) and old_values[i]:
                le.setText(old_values[i])
            elif i < len(default_names):
                le.setText(default_names[i])
            else:
                le.setPlaceholderText(f"클래스 {i} 이름 입력...")
            hbox.addWidget(lbl)
            hbox.addWidget(le)
            self.sim_class_name_inputs.append(le)
            self.sim_class_name_layout.addWidget(hbox_widget)

    def sim_log_callback(self, msg):
        """engine_simulation에서 전달받은 로그 메시지를 HTML 스타일로 변환하여 출력합니다."""
        if msg.startswith("[SUCCESS]"):
            text = msg.replace("[SUCCESS] ", "")
            styled = f"<span style='color: #a6e3a1;'>✅ {text}</span>"
        elif msg.startswith("[WARNING]"):
            text = msg.replace("[WARNING] ", "")
            styled = f"<span style='color: #f9e2af;'>⚠️ {text}</span>"
        elif msg.startswith("[ERROR]"):
            text = msg.replace("[ERROR] ", "")
            styled = f"<span style='color: #f38ba8;'>❌ {text}</span>"
        else:
            styled = msg
        self.sim_log_output.append(styled)
        self.sim_log_output.verticalScrollBar().setValue(self.sim_log_output.verticalScrollBar().maximum())
        QApplication.processEvents()

    def sim_progress_callback(self, current, total):
        """engine_simulation에서 전달받은 진행률을 프로그레스바에 반영합니다."""
        self.sim_progress.setMaximum(total)
        self.sim_progress.setValue(current)
        QApplication.processEvents()

    def run_simulation(self):
        engine_p = self.sim_engine_input.text().strip()
        img_dir = self.sim_img_folder_input.text().strip()
        save_dir = self.sim_save_folder_input.text().strip()

        if not engine_p or not os.path.exists(engine_p):
            return QMessageBox.warning(self, "Error ❌", "Engine/TRT 파일 경로를 확인해주세요.")
        if not img_dir or not os.path.isdir(img_dir):
            return QMessageBox.warning(self, "Error ❌", "이미지 폴더 경로를 확인해주세요.")
        if not save_dir:
            return QMessageBox.warning(self, "Error ❌", "결과 저장 폴더를 지정해주세요.")

        # 클래스명 수집
        class_names = []
        for le in self.sim_class_name_inputs:
            name = le.text().strip()
            if not name:
                return QMessageBox.warning(self, "Error ❌", "모든 클래스명을 입력해주세요.")
            class_names.append(name)

        self.sim_log_output.clear()
        self.sim_log_output.append(f"🚀 Engine Simulation 시작...")
        self.sim_log_output.append(f"   Engine: {os.path.basename(engine_p)}")
        self.sim_log_output.append(f"   Classes: {class_names}")
        self.sim_log_output.append(f"   Image Folder: {img_dir}")
        self.sim_log_output.append("")
        self.btn_sim_run.setEnabled(False)

        result = run_engine_simulation(
            engine_path=engine_p,
            img_dir=img_dir,
            save_dir=save_dir,
            resize_str=self.sim_resize_input.text(),
            mean_str=self.sim_mean_input.text(),
            std_str=self.sim_std_input.text(),
            class_names=class_names,
            log_callback=self.sim_log_callback,
            progress_callback=self.sim_progress_callback
        )

        if result["success"]:
            csv_path = result["csv_path"]
            output_dir = result["output_dir"]
            self.sim_log_output.append(
                f"\n✅ Simulation Completed!\n"
                f"CSV: <span style='color: #89b4fa;'>{csv_path}</span>\n"
                f"Images: <span style='color: #89b4fa;'>{output_dir}</span>"
            )
        else:
            error_msg = result.get("error", "Unknown error")
            self.sim_log_output.append(
                f"<span style='color: #f38ba8;'>❌ Simulation Failed: {error_msg}</span>"
            )

        self.sim_log_output.verticalScrollBar().setValue(self.sim_log_output.verticalScrollBar().maximum())
        self.btn_sim_run.setEnabled(True)

    # ==========================================
    # 🧠 ONNX-gradCam 탭 로직
    # ==========================================
    def select_gradcam_onnx(self):
        path, _ = QFileDialog.getOpenFileName(self, "Select ONNX File", "", "ONNX Files (*.onnx);;All Files (*)")
        if path:
            self.gradcam_onnx_input.setText(path)

    def select_gradcam_img_folder(self):
        file_path, _ = QFileDialog.getOpenFileName(self, "폴더 안의 이미지를 아무거나 하나 선택하세요", "", "Images (*.png *.jpg *.jpeg *.bmp)")
        if file_path:
            self.gradcam_img_folder_input.setText(os.path.dirname(file_path))

    def select_gradcam_save_folder(self):
        folder = QFileDialog.getExistingDirectory(self, "결과 저장 폴더 선택")
        if folder:
            self.gradcam_save_folder_input.setText(folder)

    def refresh_gradcam_config_list(self):
        self.gradcam_config_combo.clear()
        if os.path.exists(self.config_dir):
            for file in os.listdir(self.config_dir):
                if file.endswith(".json"):
                    self.gradcam_config_combo.addItem(file)

    def save_gradcam_config(self):
        """현재 선택된 Config 파일에 ONNX-gradCam 설정을 덧붙여 덮어씁니다."""
        filename = self.gradcam_config_combo.currentText()
        if not filename:
            return QMessageBox.warning(self, "Error ❌", "Load/Refresh로 Config를 먼저 선택해주세요.")
        filepath = os.path.join(self.config_dir, filename)

        config_data = {}
        if os.path.exists(filepath):
            try:
                with open(filepath, 'r', encoding='utf-8') as f:
                    config_data = json.load(f)
            except:
                pass

        selected_layer = self.gradcam_layer_combo.currentData()
        if not selected_layer:
            selected_layer = self.gradcam_layer_combo.currentText().strip()
        selected_layer_display = self.gradcam_layer_combo.currentText().strip()
        selected_layer_source = "unknown"
        if selected_layer_display.endswith("]") and "[" in selected_layer_display:
            selected_layer_source = selected_layer_display.split("[")[-1].rstrip("]").strip()

        config_data["gradcam_onnx_path"] = self.gradcam_onnx_input.text().strip()
        config_data["gradcam_img_dir"] = self.gradcam_img_folder_input.text().strip()
        config_data["gradcam_save_dir"] = self.gradcam_save_folder_input.text().strip()
        config_data["gradcam_resize"] = self.gradcam_resize_input.text().strip()
        config_data["gradcam_mean"] = self.gradcam_mean_input.text().strip()
        config_data["gradcam_std"] = self.gradcam_std_input.text().strip()
        config_data["gradcam_target_class"] = self.gradcam_target_class_spin.value()
        config_data["gradcam_target_layer"] = selected_layer
        config_data["gradcam_target_layer_display"] = selected_layer_display
        config_data["gradcam_target_layer_source"] = selected_layer_source
        config_data["gradcam_input_shape"] = self.gradcam_input_shape_input.text().strip()

        try:
            with open(filepath, 'w', encoding='utf-8') as f:
                json.dump(config_data, f, indent=4, ensure_ascii=False)
            self.gradcam_log_output.append(f"<span style='color: #a6e3a1;'>✅ Config 저장 완료 (덮어쓰기): {filename}</span>")
        except Exception as e:
            self.gradcam_log_output.append(f"<span style='color: #f38ba8;'>❌ Config 저장 실패: {e}</span>")

    def load_gradcam_config(self):
        """Config를 읽어와서 ONNX-gradCam 설정을 자동 세팅합니다."""
        filename = self.gradcam_config_combo.currentText()
        if not filename:
            return
        filepath = os.path.join(self.config_dir, filename)
        try:
            with open(filepath, 'r', encoding='utf-8') as f:
                config_data = json.load(f)

            onnx_p = config_data.get("gradcam_onnx_path", "")
            if not onnx_p:
                onnx_p = config_data.get("onnx_path", "")
            if onnx_p:
                self.gradcam_onnx_input.setText(onnx_p)

            img_dir = config_data.get("gradcam_img_dir", "")
            if img_dir:
                self.gradcam_img_folder_input.setText(img_dir)

            save_dir = config_data.get("gradcam_save_dir", "")
            if save_dir:
                self.gradcam_save_folder_input.setText(save_dir)

            gradcam_resize = config_data.get("gradcam_resize", "")
            if gradcam_resize:
                self.gradcam_resize_input.setText(gradcam_resize)
            else:
                opt_shape = config_data.get("opt_shape", "")
                if opt_shape:
                    parts = opt_shape.lower().split('x')
                    if len(parts) == 4:
                        h, w = parts[2], parts[3]
                        self.gradcam_resize_input.setText(f"{w}, {h}")

            self.gradcam_mean_input.setText(config_data.get("gradcam_mean", "0.5, 0.5, 0.5"))
            self.gradcam_std_input.setText(config_data.get("gradcam_std", "1.0, 1.0, 1.0"))
            self.gradcam_target_class_spin.setValue(int(config_data.get("gradcam_target_class", 0)))

            gradcam_input_shape = config_data.get("gradcam_input_shape", "")
            if gradcam_input_shape:
                self.gradcam_input_shape_input.setText(gradcam_input_shape)
            else:
                opt_shape = config_data.get("opt_shape", "")
                if opt_shape:
                    parts = opt_shape.lower().split('x')
                    if len(parts) == 4:
                        n, c, h, w = parts
                        self.gradcam_input_shape_input.setText(f"{n},{c},{h},{w}")
                else:
                    self.gradcam_input_shape_input.clear()

            target_layer_name = config_data.get("gradcam_target_layer", "")
            target_layer_display = config_data.get("gradcam_target_layer_display", "")
            if self.gradcam_onnx_input.text().strip() and os.path.exists(self.gradcam_onnx_input.text().strip()):
                self.load_gradcam_layers(silent=True)
                if target_layer_name:
                    matched = self.select_gradcam_layer_name(target_layer_name)
                    if not matched and target_layer_display:
                        for i in range(self.gradcam_layer_combo.count()):
                            display_txt = self.gradcam_layer_combo.itemText(i)
                            if target_layer_display == display_txt or target_layer_name in display_txt:
                                self.gradcam_layer_combo.setCurrentIndex(i)
                                matched = True
                                break
                    if not matched and self.gradcam_layer_combo.count() > 0:
                        self.gradcam_layer_combo.setCurrentIndex(0)
                        self.gradcam_log_output.append(
                            "<span style='color: #f9e2af;'>⚠️ 저장된 Target Layer와 정확히 일치하지 않아 첫 번째 레이어를 선택했습니다.</span>"
                        )

            self.gradcam_log_output.append(f"<span style='color: #a6e3a1;'>✅ Config 로드 완료: {filename}</span>")
        except Exception as e:
            self.gradcam_log_output.append(f"<span style='color: #f38ba8;'>❌ Config 로드 실패: {e}</span>")

    def load_gradcam_layers(self, silent=False):
        onnx_p = self.gradcam_onnx_input.text().strip()
        if not onnx_p or not os.path.exists(onnx_p):
            if not silent:
                QMessageBox.warning(self, "Error ❌", "유효한 ONNX 파일을 먼저 선택해주세요.")
            return

        self.gradcam_layer_combo.clear()
        self.gradcam_layer_output.clear()

        try:
            layers = list_onnx_layers_reverse(onnx_p)
            if not layers:
                raise RuntimeError("레이어 정보를 찾지 못했습니다.")

            lines = []
            for idx, layer in enumerate(layers):
                layer_name = layer["name"]
                layer_type = layer["type"]
                layer_source = layer.get("source", "unknown")
                display = f"{idx:04d} | {layer_name} ({layer_type}) [{layer_source}]"
                self.gradcam_layer_combo.addItem(display, layer_name)
                lines.append(display)

            self.gradcam_layer_output.setPlainText("\n".join(lines))
            if not silent:
                self.gradcam_log_output.append(f"<span style='color: #a6e3a1;'>✅ Layer 로드 완료: {len(layers)}개</span>")
        except Exception as e:
            if not silent:
                self.gradcam_log_output.append(f"<span style='color: #f38ba8;'>❌ Layer 로드 실패: {e}</span>")

    def select_gradcam_layer_name(self, target_layer_name):
        for i in range(self.gradcam_layer_combo.count()):
            if self.gradcam_layer_combo.itemData(i) == target_layer_name:
                self.gradcam_layer_combo.setCurrentIndex(i)
                return True
        return False

    def gradcam_log_callback(self, msg):
        if msg.startswith("[SUCCESS]"):
            text = msg.replace("[SUCCESS] ", "")
            styled = f"<span style='color: #a6e3a1;'>✅ {text}</span>"
        elif msg.startswith("[WARNING]"):
            text = msg.replace("[WARNING] ", "")
            styled = f"<span style='color: #f9e2af;'>⚠️ {text}</span>"
        elif msg.startswith("[ERROR]"):
            text = msg.replace("[ERROR] ", "")
            styled = f"<span style='color: #f38ba8;'>❌ {text}</span>"
        else:
            styled = msg
        self.gradcam_log_output.append(styled)
        self.gradcam_log_output.verticalScrollBar().setValue(self.gradcam_log_output.verticalScrollBar().maximum())
        QApplication.processEvents()

    def gradcam_progress_callback(self, current, total):
        self.gradcam_progress.setMaximum(total)
        self.gradcam_progress.setValue(current)
        QApplication.processEvents()

    def run_gradcam(self):
        onnx_p = self.gradcam_onnx_input.text().strip()
        img_dir = self.gradcam_img_folder_input.text().strip()
        save_dir = self.gradcam_save_folder_input.text().strip()
        target_layer_name = self.gradcam_layer_combo.currentData()
        if not target_layer_name:
            target_layer_name = self.gradcam_layer_combo.currentText().strip()

        if not onnx_p or not os.path.exists(onnx_p):
            return QMessageBox.warning(self, "Error ❌", "ONNX 파일 경로를 확인해주세요.")
        if not img_dir or not os.path.isdir(img_dir):
            return QMessageBox.warning(self, "Error ❌", "이미지 폴더 경로를 확인해주세요.")
        if not save_dir:
            return QMessageBox.warning(self, "Error ❌", "결과 저장 폴더를 지정해주세요.")
        if not target_layer_name:
            return QMessageBox.warning(self, "Error ❌", "Target Layer를 선택해주세요. (Load Layers 실행 필요)")

        self.gradcam_log_output.clear()
        self.gradcam_log_output.append("🧠 ONNX-gradCam 시작...")
        self.gradcam_log_output.append(f"   ONNX: {os.path.basename(onnx_p)}")
        self.gradcam_log_output.append(f"   Target Class: {self.gradcam_target_class_spin.value()}")
        self.gradcam_log_output.append(f"   Target Layer: {target_layer_name}")
        self.gradcam_log_output.append(f"   Fixed Input Shape: {self.gradcam_input_shape_input.text().strip() or 'Auto'}")
        self.gradcam_log_output.append("")
        self.btn_gradcam_run.setEnabled(False)

        model_meta = {
            "fixed_input_shape": self.gradcam_input_shape_input.text().strip(),
        }

        result = run_onnx_gradcam(
            onnx_path=onnx_p,
            img_dir=img_dir,
            save_dir=save_dir,
            resize_str=self.gradcam_resize_input.text(),
            mean_str=self.gradcam_mean_input.text(),
            std_str=self.gradcam_std_input.text(),
            target_class=self.gradcam_target_class_spin.value(),
            target_layer_name=target_layer_name,
            model_meta=model_meta,
            log_callback=self.gradcam_log_callback,
            progress_callback=self.gradcam_progress_callback,
        )

        if result["success"]:
            output_dir = result["output_dir"]
            saved_images = result.get("saved_images", [])
            self.gradcam_log_output.append(
                f"\n✅ ONNX-gradCam Completed!\n"
                f"Images: <span style='color: #89b4fa;'>{output_dir}</span>"
            )
            self.update_gradcam_viewer(saved_images)
        else:
            error_msg = result.get("error", "Unknown error")
            self.gradcam_log_output.append(
                f"<span style='color: #f38ba8;'>❌ ONNX-gradCam Failed: {error_msg}</span>"
            )

        self.gradcam_log_output.verticalScrollBar().setValue(self.gradcam_log_output.verticalScrollBar().maximum())
        self.btn_gradcam_run.setEnabled(True)

    def update_gradcam_viewer(self, image_paths):
        self.gradcam_view_files = image_paths[:] if image_paths else []
        self.gradcam_view_combo.blockSignals(True)
        self.gradcam_view_combo.clear()
        for p in self.gradcam_view_files:
            self.gradcam_view_combo.addItem(os.path.basename(p), p)
        self.gradcam_view_combo.blockSignals(False)

        if self.gradcam_view_files:
            self.gradcam_view_index = 0
            self._show_gradcam_image_by_index(0)
        else:
            self.gradcam_view_index = -1
            self.gradcam_image_label.clear()
            self.gradcam_image_label.setText("표시할 CAM 이미지가 없습니다.")
        self._update_gradcam_viewer_buttons()

    def _show_gradcam_image_by_index(self, idx):
        if idx < 0 or idx >= len(self.gradcam_view_files):
            return
        img_path = self.gradcam_view_files[idx]
        pixmap = QPixmap(img_path)
        if pixmap.isNull():
            self.gradcam_image_label.setText(f"이미지 로드 실패: {img_path}")
            return
        scaled = pixmap.scaled(
            self.gradcam_view_width,
            self.gradcam_view_height,
            Qt.KeepAspectRatio,
            Qt.SmoothTransformation
        )
        self.gradcam_image_label.setPixmap(scaled)
        self.gradcam_view_index = idx
        self.gradcam_view_combo.blockSignals(True)
        self.gradcam_view_combo.setCurrentIndex(idx)
        self.gradcam_view_combo.blockSignals(False)
        self._update_gradcam_viewer_buttons()

    def _update_gradcam_viewer_buttons(self):
        has_images = len(self.gradcam_view_files) > 0
        self.btn_gradcam_prev.setEnabled(has_images and self.gradcam_view_index > 0)
        self.btn_gradcam_next.setEnabled(has_images and self.gradcam_view_index < len(self.gradcam_view_files) - 1)

    def show_prev_gradcam_image(self):
        if self.gradcam_view_index > 0:
            self._show_gradcam_image_by_index(self.gradcam_view_index - 1)

    def show_next_gradcam_image(self):
        if self.gradcam_view_index < len(self.gradcam_view_files) - 1:
            self._show_gradcam_image_by_index(self.gradcam_view_index + 1)

    def on_gradcam_view_combo_changed(self, idx):
        if 0 <= idx < len(self.gradcam_view_files):
            self._show_gradcam_image_by_index(idx)

    # ==========================================
    # 🔧 SMW Simulation 탭 로직
    # ==========================================
    def select_smw_engine(self):
        path, _ = QFileDialog.getOpenFileName(self, "Select Engine/TRT File", "", "TensorRT Engine (*.engine *.trt);;All Files (*)")
        if path:
            self.smw_engine_input.setText(path)

    def select_smw_img_folder(self):
        file_path, _ = QFileDialog.getOpenFileName(self, "폴더 안의 이미지를 아무거나 하나 선택하세요", "", "Images (*.png *.jpg *.jpeg *.bmp)")
        if file_path:
            self.smw_img_folder_input.setText(os.path.dirname(file_path))

    def select_smw_save_folder(self):
        folder = QFileDialog.getExistingDirectory(self, "결과 저장 폴더 선택")
        if folder:
            self.smw_save_folder_input.setText(folder)

    def refresh_smw_config_list(self):
        self.smw_config_combo.clear()
        if os.path.exists(self.config_dir):
            for file in os.listdir(self.config_dir):
                if file.endswith(".json"):
                    self.smw_config_combo.addItem(file)

    def save_smw_config(self):
        """현재 선택된 Config 파일에 SMW Simulation 설정을 덧붙여 덮어씁니다."""
        filename = self.smw_config_combo.currentText()
        if not filename:
            return QMessageBox.warning(self, "Error ❌", "Load/Refresh로 Config를 먼저 선택해주세요.")
        filepath = os.path.join(self.config_dir, filename)

        # 기존 Config 읽기 (없으면 빈 dict)
        config_data = {}
        if os.path.exists(filepath):
            try:
                with open(filepath, 'r', encoding='utf-8') as f:
                    config_data = json.load(f)
            except:
                pass

        # SMW Simulation 관련 필드 덮어쓰기 (merge)
        config_data["smw_resize"] = self.smw_resize_input.text()
        config_data["smw_mean"] = self.smw_mean_input.text()
        config_data["smw_std"] = self.smw_std_input.text()
        config_data["smw_num_patches"] = self.smw_patch_spin.value()
        config_data["smw_class_num"] = self.smw_class_num_spin.value()
        config_data["smw_ok_class_idx"] = self.smw_ok_class_spin.value()
        config_data["smw_class_names"] = [le.text().strip() for le in self.smw_class_name_inputs]
        
        # Threshold dict 저장 (class_index: threshold 형태의 dict)
        threshold_dict = {}
        for i, th_input in enumerate(self.smw_threshold_inputs):
            try:
                threshold_dict[i] = float(th_input.text().strip())
            except ValueError:
                threshold_dict[i] = 0.0
        config_data["smw_threshold_dict"] = threshold_dict

        try:
            with open(filepath, 'w', encoding='utf-8') as f:
                json.dump(config_data, f, indent=4, ensure_ascii=False)
            self.smw_log_output.append(f"<span style='color: #a6e3a1;'>✅ Config 저장 완료 (덮어쓰기): {filename}</span>")
        except Exception as e:
            self.smw_log_output.append(f"<span style='color: #f38ba8;'>❌ Config 저장 실패: {e}</span>")

    def load_smw_config(self):
        """Config를 읽어와서 SMW Simulation 설정을 자동 세팅합니다."""
        filename = self.smw_config_combo.currentText()
        if not filename:
            return
        filepath = os.path.join(self.config_dir, filename)
        try:
            with open(filepath, 'r', encoding='utf-8') as f:
                config_data = json.load(f)

            # 1. 엔진 경로 세팅
            engine_p = config_data.get("engine_path", "")
            if engine_p:
                self.smw_engine_input.setText(engine_p)

            # 2. Resize 세팅 (smw_resize 우선, 없으면 opt_shape에서 추출)
            smw_resize = config_data.get("smw_resize", "")
            if smw_resize:
                self.smw_resize_input.setText(smw_resize)
            else:
                opt_shape = config_data.get("opt_shape", "")
                if opt_shape:
                    parts = opt_shape.lower().split('x')
                    if len(parts) == 4:
                        h, w = parts[2], parts[3]
                        self.smw_resize_input.setText(f"{w}, {h}")

            # 3. Mean / Std 세팅 (없으면 기본값)
            self.smw_mean_input.setText(config_data.get("smw_mean", "0.5, 0.5, 0.5"))
            self.smw_std_input.setText(config_data.get("smw_std", "1.0, 1.0, 1.0"))

            # 4. Patch 개수 세팅
            num_patches = config_data.get("smw_num_patches", 56)
            self.smw_patch_spin.setValue(num_patches)

            # 5. OK Class Index 세팅
            ok_idx = config_data.get("smw_ok_class_idx", 5)
            self.smw_ok_class_spin.setValue(ok_idx)

            # 6. Class 정보 세팅
            class_num = config_data.get("smw_class_num", 0)
            class_names = config_data.get("smw_class_names", [])
            threshold_dict = config_data.get("smw_threshold_dict", {})
            
            if class_num > 0 and class_names:
                self.smw_class_num_spin.setValue(class_num)
                self.update_smw_class_inputs()
                
                # 클래스명 세팅
                for i, le in enumerate(self.smw_class_name_inputs):
                    if i < len(class_names):
                        le.setText(class_names[i])
                
                # Threshold 세팅
                for i, th_le in enumerate(self.smw_threshold_inputs):
                    th_val = threshold_dict.get(str(i), threshold_dict.get(i, 0.0))
                    th_le.setText(str(th_val))

            self.smw_log_output.append(f"<span style='color: #a6e3a1;'>✅ Config 로드 완료: {filename}</span>")
        except Exception as e:
            self.smw_log_output.append(f"<span style='color: #f38ba8;'>❌ Config 로드 실패: {e}</span>")

    def update_smw_class_inputs(self):
        """SMW: 클래스 개수에 맞게 클래스명 및 Threshold 입력칸을 동적으로 생성합니다."""
        num_classes = self.smw_class_num_spin.value()

        # 기존 입력값 백업
        old_names = [le.text() for le in self.smw_class_name_inputs]
        old_thresholds = [th.text() for th in self.smw_threshold_inputs]

        # 기존 위젯 모두 제거
        for le in self.smw_class_name_inputs:
            le.setParent(None)
            le.deleteLater()
        for th in self.smw_threshold_inputs:
            th.setParent(None)
            th.deleteLater()
        # 레이아웃 내 남은 아이템 정리
        while self.smw_class_name_layout.count():
            item = self.smw_class_name_layout.takeAt(0)
            w = item.widget()
            if w:
                w.setParent(None)
                w.deleteLater()

        self.smw_class_name_inputs = []
        self.smw_threshold_inputs = []
        
        # SMW 기본 클래스명/Threshold (smw_eval.py 참조)
        default_names = ["NO", "OVR", "WK", "PHL", "SPTT", "OK", "OK_OVERLAP"]
        default_thresholds = [0.0, 0.2, 0.0, 0.0, 0.0, 0.0, 0.0]

        for i in range(num_classes):
            hbox_widget = QWidget()
            hbox = QHBoxLayout(hbox_widget)
            hbox.setContentsMargins(0, 0, 0, 0)
            
            # Class Label
            lbl = QLabel(f"Class {i}:")
            lbl.setFixedWidth(55)
            
            # Class Name Input
            name_le = QLineEdit()
            name_le.setFixedWidth(100)
            if i < len(old_names) and old_names[i]:
                name_le.setText(old_names[i])
            elif i < len(default_names):
                name_le.setText(default_names[i])
            else:
                name_le.setPlaceholderText(f"클래스명...")
                
            # Threshold Label
            th_lbl = QLabel("  Threshold:")
            th_lbl.setFixedWidth(75)
            
            # Threshold Input
            th_le = QLineEdit()
            th_le.setFixedWidth(60)
            if i < len(old_thresholds) and old_thresholds[i]:
                th_le.setText(old_thresholds[i])
            elif i < len(default_thresholds):
                th_le.setText(str(default_thresholds[i]))
            else:
                th_le.setText("0.0")
            th_le.setToolTip("이 비율 초과 시 해당 클래스로 판정 (0.0 = 한 개라도 있으면 불량)")
            
            hbox.addWidget(lbl)
            hbox.addWidget(name_le)
            hbox.addWidget(th_lbl)
            hbox.addWidget(th_le)
            hbox.addStretch()
            
            self.smw_class_name_inputs.append(name_le)
            self.smw_threshold_inputs.append(th_le)
            self.smw_class_name_layout.addWidget(hbox_widget)

    def smw_log_callback(self, msg):
        """smw_simulation에서 전달받은 로그 메시지를 HTML 스타일로 변환하여 출력합니다."""
        if msg.startswith("[SUCCESS]"):
            text = msg.replace("[SUCCESS] ", "")
            styled = f"<span style='color: #a6e3a1;'>✅ {text}</span>"
        elif msg.startswith("[WARNING]"):
            text = msg.replace("[WARNING] ", "")
            styled = f"<span style='color: #f9e2af;'>⚠️ {text}</span>"
        elif msg.startswith("[ERROR]"):
            text = msg.replace("[ERROR] ", "")
            styled = f"<span style='color: #f38ba8;'>❌ {text}</span>"
        else:
            styled = msg
        self.smw_log_output.append(styled)
        self.smw_log_output.verticalScrollBar().setValue(self.smw_log_output.verticalScrollBar().maximum())
        QApplication.processEvents()

    def smw_progress_callback(self, current, total):
        """smw_simulation에서 전달받은 진행률을 프로그레스바에 반영합니다."""
        self.smw_progress.setMaximum(total)
        self.smw_progress.setValue(current)
        QApplication.processEvents()

    def run_smw_simulation(self):
        """SMW Simulation 실행 (배치 추론)"""
        engine_p = self.smw_engine_input.text().strip()
        img_dir = self.smw_img_folder_input.text().strip()
        save_dir = self.smw_save_folder_input.text().strip()

        if not engine_p or not os.path.exists(engine_p):
            return QMessageBox.warning(self, "Error ❌", "Engine/TRT 파일 경로를 확인해주세요.")
        if not img_dir or not os.path.isdir(img_dir):
            return QMessageBox.warning(self, "Error ❌", "이미지 폴더 경로를 확인해주세요.")
        if not save_dir:
            return QMessageBox.warning(self, "Error ❌", "결과 저장 폴더를 지정해주세요.")

        # 클래스명 수집
        class_names = []
        for le in self.smw_class_name_inputs:
            name = le.text().strip()
            if not name:
                return QMessageBox.warning(self, "Error ❌", "모든 클래스명을 입력해주세요.")
            class_names.append(name)

        # Threshold dict 수집
        threshold_dict = {}
        for i, th_input in enumerate(self.smw_threshold_inputs):
            try:
                threshold_dict[i] = float(th_input.text().strip())
            except ValueError:
                threshold_dict[i] = 0.0

        num_patches = self.smw_patch_spin.value()
        ok_class_idx = self.smw_ok_class_spin.value()
        save_overlay = self.smw_save_overlay_checkbox.isChecked()

        self.smw_log_output.clear()
        self.smw_log_output.append(f"🔧 SMW Simulation 시작 (Batch Inference)...")
        self.smw_log_output.append(f"   Engine: {os.path.basename(engine_p)}")
        self.smw_log_output.append(f"   Patches: {num_patches}")
        self.smw_log_output.append(f"   Classes: {class_names}")
        self.smw_log_output.append(f"   OK Class: {class_names[ok_class_idx] if ok_class_idx < len(class_names) else ok_class_idx}")
        self.smw_log_output.append(f"   Thresholds: {threshold_dict}")
        self.smw_log_output.append(f"   Save Overlay: {'✅ Yes' if save_overlay else '❌ No'}")
        self.smw_log_output.append(f"   Image Folder: {img_dir}")
        self.smw_log_output.append("")
        self.btn_smw_run.setEnabled(False)

        result = run_smw_simulation(
            engine_path=engine_p,
            img_dir=img_dir,
            save_dir=save_dir,
            resize_str=self.smw_resize_input.text(),
            mean_str=self.smw_mean_input.text(),
            std_str=self.smw_std_input.text(),
            num_patches=num_patches,
            class_names=class_names,
            threshold_dict=threshold_dict,
            ok_class_idx=ok_class_idx,
            save_overlay=save_overlay,
            log_callback=self.smw_log_callback,
            progress_callback=self.smw_progress_callback
        )

        if result["success"]:
            csv_path = result["csv_path"]
            output_dir = result["output_dir"]
            perf = result.get("performance", {})
            
            self.smw_log_output.append(
                f"\n✅ SMW Simulation Completed!\n"
                f"CSV: <span style='color: #89b4fa;'>{csv_path}</span>\n"
                f"Images: <span style='color: #89b4fa;'>{output_dir}</span>"
            )
            
            if perf:
                self.smw_log_output.append("")
                self.smw_log_output.append("<span style='color: #cba6f7;'>📊 Performance Summary:</span>")
                self.smw_log_output.append(f"   Throughput: <span style='color: #f9e2af;'>{perf.get('throughput_ips', 0):.2f}</span> images/sec")
                self.smw_log_output.append(f"   Avg Inference: <span style='color: #f9e2af;'>{perf.get('avg_infer_ms', 0):.2f}</span> ms/image")
        else:
            error_msg = result.get("error", "Unknown error")
            self.smw_log_output.append(
                f"<span style='color: #f38ba8;'>❌ SMW Simulation Failed: {error_msg}</span>"
            )

        self.smw_log_output.verticalScrollBar().setValue(self.smw_log_output.verticalScrollBar().maximum())
        self.btn_smw_run.setEnabled(True)

    # --- Config Manager ---
    def refresh_config_list(self):
        self.config_combo.clear()
        if os.path.exists(self.config_dir):
            for file in os.listdir(self.config_dir):
                if file.endswith(".json"): self.config_combo.addItem(file)

    def save_config(self):
        filename = self.config_name_input.text().strip()
        if not filename: return QMessageBox.warning(self, "Error ❌", "저장할 파일명을 입력해주세요.")
        if not filename.endswith(".json"): filename += ".json"
        filepath = os.path.join(self.config_dir, filename)
        
        config_data = {
            "trt_path": self.trt_path_input.text(), "onnx_path": self.onnx_path_input.text(),
            "engine_path": self.engine_path_input.text(), "dynamic_batch": self.dynamic_batch_cb.isChecked(),
            "min_shape": self.min_shape_input.text(), "opt_shape": self.opt_shape_input.text(),
            "max_shape": self.max_shape_input.text(), "layer_name": self.layer_name_input.text(),
            "gpu_architecture": self.gpu_arch_combo.currentText(),
            "precision": self.precision_combo.currentText(),
            "use_custom_script": self.custom_script_cb.isChecked(),
            "fp32_keywords": self.fp32_keywords_input.text(),
            "auto_test": self.auto_test_cb.isChecked() # 설정 저장 반영
        }
        try:
            with open(filepath, 'w', encoding='utf-8') as f: json.dump(config_data, f, indent=4)
            QMessageBox.information(self, "Success ✅", f"설정 저장 완료.\n{filename}")
            self.refresh_config_list()
            idx = self.config_combo.findText(filename)
            if idx >= 0: self.config_combo.setCurrentIndex(idx)
        except Exception as e: QMessageBox.critical(self, "Error ❌", str(e))

    def load_config(self):
        filename = self.config_combo.currentText()
        if not filename: return
        filepath = os.path.join(self.config_dir, filename)
        try:
            with open(filepath, 'r', encoding='utf-8') as f: config_data = json.load(f)
            self.trt_path_input.setText(config_data.get("trt_path", ""))
            self.onnx_path_input.setText(config_data.get("onnx_path", ""))
            self.engine_path_input.setText(config_data.get("engine_path", ""))
            self.dynamic_batch_cb.setChecked(config_data.get("dynamic_batch", True))
            self.min_shape_input.setText(config_data.get("min_shape", ""))
            self.opt_shape_input.setText(config_data.get("opt_shape", ""))
            self.max_shape_input.setText(config_data.get("max_shape", ""))
            self.layer_name_input.setText(config_data.get("layer_name", ""))
            arch_idx = self.gpu_arch_combo.findText(config_data.get("gpu_architecture", "Ampere"))
            if arch_idx >= 0: self.gpu_arch_combo.setCurrentIndex(arch_idx)
            idx = self.precision_combo.findText(config_data.get("precision", "FP16"))
            if idx >= 0: self.precision_combo.setCurrentIndex(idx)
            self.custom_script_cb.setChecked(config_data.get("use_custom_script", False))
            self.fp32_keywords_input.setText(config_data.get("fp32_keywords", "Softmax, ReduceMean, Pow, Sqrt"))
            self.auto_test_cb.setChecked(config_data.get("auto_test", True))
            self.config_name_input.setText(filename.replace(".json", ""))
        except Exception as e: QMessageBox.critical(self, "Error ❌", str(e))

    def select_trt(self):
        path, _ = QFileDialog.getOpenFileName(self, "Select trtexec", "", "Executable Files (*.exe);;All Files (*)")
        if path: self.trt_path_input.setText(path)

    def select_onnx(self):
        path, _ = QFileDialog.getOpenFileName(self, "Select ONNX File", "", "ONNX Files (*.onnx);;All Files (*)")
        if path:
            self.onnx_path_input.setText(path)
            self.engine_path_input.setText(os.path.splitext(path)[0] + ".engine")

    def select_engine(self):
        path, _ = QFileDialog.getSaveFileName(self, "Save Engine/TRT File", "", "TensorRT Engine (*.engine *.trt);;All Files (*)")
        if path: self.engine_path_input.setText(path)

    # ==========================================
    # 🔥 빌드 및 테스트 흐름 제어 로직 (Chaining)
    # ==========================================
    def run_trtexec(self):
        onnx_path = self.onnx_path_input.text().strip()
        engine_path = self.engine_path_input.text().strip()
        
        if not os.path.exists(onnx_path):
            return QMessageBox.warning(self, "Error ❌", "ONNX 경로를 확인해주세요.")

        self.log_output.clear()
        self.btn_run.setEnabled(False)
        self.btn_run.setText("⏳ Building... Please Wait")
        self.current_action = "BUILD" # 현재 작업 상태: 빌드 중

        precision = self.precision_combo.currentText()
        if self.custom_script_cb.isChecked() and precision in ("FP16", "BF16"):
            def parse_shape(s): return tuple(map(int, s.lower().split('x')))
            mins = parse_shape(self.min_shape_input.text().strip())
            opts = parse_shape(self.opt_shape_input.text().strip())
            maxs = parse_shape(self.max_shape_input.text().strip())
            keywords = self.fp32_keywords_input.text()
            
            self.mp_queue = mp.Queue()
            self.mp_process = mp.Process(target=build_engine_process, args=(
                onnx_path, engine_path, self.dynamic_batch_cb.isChecked(),
                mins, opts, maxs, keywords, self.mp_queue, precision
            ))
            
            self.btn_stop.setEnabled(True)
            self.mp_process.start()
            
            self.monitor_thread = LogMonitorThread(self.mp_queue, self.mp_process)
            self.monitor_thread.log_signal.connect(self.handle_thread_log)
            self.monitor_thread.finished_signal.connect(self.process_finished)
            self.monitor_thread.start()
            
        else:
            trt_path = self.trt_path_input.text().strip()
            if not os.path.exists(trt_path):
                self.btn_run.setEnabled(True)
                self.btn_run.setText("🚀 Build TensorRT Engine")
                return QMessageBox.warning(self, "Error ❌", "trtexec 경로를 확인해주세요.")

            onnx_dir = os.path.dirname(onnx_path)
            if onnx_dir:
                self.process.setWorkingDirectory(onnx_dir)

            args = [f"--onnx={onnx_path}", f"--saveEngine={engine_path}"]
            if self.dynamic_batch_cb.isChecked():
                layer, mins, opts, maxs = self.layer_name_input.text().strip(), self.min_shape_input.text().strip(), self.opt_shape_input.text().strip(), self.max_shape_input.text().strip()
                if layer and mins and opts and maxs: args.extend([f"--minShapes={layer}:{mins}", f"--optShapes={layer}:{opts}", f"--maxShapes={layer}:{maxs}"])
            precision = self.precision_combo.currentText()
            if precision == "FP16": args.append("--fp16")
            elif precision == "BF16": args.append("--bf16")
            args.append("--verbose")

            self.log_output.append(f"🟢 Running CMD command:\n{trt_path} {' '.join(args)}\n" + "-" * 60)
            self.btn_stop.setEnabled(True)
            self.process.start(trt_path, args)

    def handle_thread_log(self, msg):
        self.log_output.append(msg)
        self.log_output.verticalScrollBar().setValue(self.log_output.verticalScrollBar().maximum())

    def stop_process(self):
        if hasattr(self, 'mp_process') and self.mp_process.is_alive():
            self.mp_process.terminate()
            self.mp_process.join()
            self.log_output.append("\n⚠️ Process stopped by user.")
            self.process_finished(False)
            
        elif self.process.state() == QProcess.Running:
            self.process.kill()
            self.log_output.append("\n⚠️ Process stopped by user.")
            # QProcess.kill()은 자동으로 finished 시그널(exitCode != 0)을 발생시킵니다.
            
    def handle_stdout(self):
        self.log_output.append(self.process.readAllStandardOutput().data().decode('utf-8', errors='replace').strip())
        self.log_output.verticalScrollBar().setValue(self.log_output.verticalScrollBar().maximum())

    def handle_stderr(self):
        self.log_output.append(f"<span style='color: #f38ba8;'>{self.process.readAllStandardError().data().decode('utf-8', errors='replace').strip()}</span>")
        self.log_output.verticalScrollBar().setValue(self.log_output.verticalScrollBar().maximum())

    # ==========================================
    # 🔥 자동 벤치마크 (Performance Test) 연계 로직
    # ==========================================
    def process_finished(self, exit_code_or_bool=0, exit_status=None):
        if isinstance(exit_code_or_bool, bool):
            success = exit_code_or_bool
        else:
            success = (exit_code_or_bool == 0 and exit_status == QProcess.NormalExit)

        engine_path = self.engine_path_input.text().strip()

        # 1. 빌드가 끝났을 때
        if self.current_action == "BUILD":
            if success and self.auto_test_cb.isChecked() and os.path.exists(engine_path):
                self.log_output.append("\n" + "=" * 60)
                self.log_output.append("✅ Build Finished! Automatically starting Performance Test...")
                self.log_output.append("=" * 60 + "\n")
                
                self.current_action = "TEST" # 상태 변경
                trt_path = self.trt_path_input.text().strip()
                args = [f"--loadEngine={engine_path}", "--verbose"]
                
                # 워킹 디렉토리 세팅 (엔진 파일 위치 기준)
                engine_dir = os.path.dirname(engine_path)
                if engine_dir: self.process.setWorkingDirectory(engine_dir)
                
                self.log_output.append(f"🟢 Running Perf Test:\n{trt_path} {' '.join(args)}\n")
                self.process.start(trt_path, args)
                return # 벤치마크 중이므로 아직 버튼을 복구하지 않고 함수 탈출
            
            elif success:
                self.log_output.append("\n" + "=" * 60 + "\n✅ Build Process Finished.")
            else:
                self.log_output.append("\n" + "=" * 60 + "\n❌ Build Failed or Terminated.")

        # 2. 성능 테스트(벤치마크)가 끝났을 때
        elif self.current_action == "TEST":
            if success:
                self.log_output.append("\n" + "=" * 60 + "\n✅ Performance Test Finished.")
            else:
                self.log_output.append("\n" + "=" * 60 + "\n❌ Performance Test Failed or Terminated.")
            
            self.current_action = "IDLE" # 상태 초기화

        # 모든 작업(빌드 or 빌드+테스트)이 끝난 후 UI 버튼 원상 복구
        self.btn_run.setEnabled(True)
        self.btn_run.setText("🚀 Build TensorRT Engine")
        self.btn_stop.setEnabled(False)
        self.log_output.verticalScrollBar().setValue(self.log_output.verticalScrollBar().maximum())

    # ==========================================
    # 🔥 추가: ONNX Simplifier 실행 로직
    # ==========================================
    def run_onnxsim(self):
        onnx_path = self.val_onnx_input.text().strip()
        
        if not onnx_path or not os.path.exists(onnx_path) or not onnx_path.lower().endswith('.onnx'):
            QMessageBox.warning(self, "Error ❌", "유효한 ONNX 파일을 먼저 선택해주세요.")
            return

        # 저장될 _sim.onnx 경로 생성
        out_path = onnx_path.rsplit('.onnx', 1)[0] + "_sim.onnx"

        self.val_log_output.append(f"\n✨ Starting ONNX Simplification...\nInput: {os.path.basename(onnx_path)}")
        self.btn_simplify.setEnabled(False)
        self.btn_simplify.setText("⏳ Simplifying...")
        QApplication.processEvents() # UI 강제 업데이트 (프리징 방지)

        try:
            # 처음부터 임포트하면 설치 안 된 PC에서 GUI 자체가 안 뜰 수 있으므로 여기서 임포트
            import onnx
            from onnxsim import simplify

            # 1. 모델 로드
            model = onnx.load(onnx_path)

            # 2. 최적화 진행 (이 과정에서 Cast 꼬임 등이 해결됨)
            model_simp, check = simplify(model)
            
            if not check:
                raise RuntimeError("Simplified ONNX model could not be validated by onnxsim.")

            # 3. 모델 저장
            onnx.save(model_simp, out_path)

            self.val_log_output.append(f"<span style='color: #a6e3a1;'>✅ Simplification Completed!</span>")
            self.val_log_output.append(f"Saved to: {os.path.basename(out_path)}")
            
            # 🔥 핵심: 작업이 끝나면 입력창의 경로를 최적화된 모델로 자동 교체
            self.val_onnx_input.setText(out_path)

        except ImportError:
            self.val_log_output.append("<span style='color: #f38ba8;'>❌ onnxsim 모듈을 찾을 수 없습니다. 터미널에서 'pip install onnxsim'을 실행하세요.</span>")
        except Exception as e:
            self.val_log_output.append(f"<span style='color: #f38ba8;'>❌ Simplification Error: {str(e)}</span>")
        finally:
            self.btn_simplify.setEnabled(True)
            self.btn_simplify.setText("✨ Simplify")
            self.val_log_output.verticalScrollBar().setValue(self.val_log_output.verticalScrollBar().maximum())

if __name__ == '__main__':
    mp.freeze_support() # Windows 환경 멀티프로세싱 안정화
    app = QApplication(sys.argv)
    ex = TensorRTBuilderGUI()
    ex.show()
    sys.exit(app.exec_())