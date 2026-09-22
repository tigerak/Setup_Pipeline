import os 
import numpy as np
# NumPy 호환성 패치
if not hasattr(np, 'bool'):
    np.bool = np.bool_
import queue
import tensorrt as trt
import pycuda.driver as cuda
import onnxruntime as ort


def build_engine_process(onnx_path, engine_path, is_dynamic, min_s, opt_s, max_s, keywords_str, log_queue, precision="FP16"):
    import tensorrt as trt
    import os
    
    class QueueLogger(trt.ILogger):
        def __init__(self, q):
            trt.ILogger.__init__(self)
            self.q = q
        def log(self, severity, msg):
            if severity <= trt.Logger.INFO:
                prefix = ""
                if severity == trt.Logger.ERROR: prefix = "❌ [ERROR] "
                elif severity == trt.Logger.WARNING: prefix = "⚠️ [WARNING] "
                elif severity == trt.Logger.INFO: prefix = "ℹ️ [INFO] "
                self.q.put(f"{prefix}{msg}")

    try:
        onnx_dir = os.path.dirname(onnx_path)
        if onnx_dir: os.chdir(onnx_dir)

        log_queue.put("🟢 [Python API] Custom TensorRT Engine 빌드 시작...")
        version = trt.__version__
        log_queue.put(f"🟢 [Python API] TensorRT Version: {version}")
        
        logger = QueueLogger(log_queue)
        builder = trt.Builder(logger)
        network = builder.create_network(1 << int(trt.NetworkDefinitionCreationFlag.EXPLICIT_BATCH))
        parser = trt.OnnxParser(network, logger)
        config = builder.create_builder_config()

        with open(onnx_path, 'rb') as model:
            if not parser.parse(model.read()):
                for i in range(parser.num_errors):
                    log_queue.put(f"❌ ONNX Parsing Error: {parser.get_error(i)}")
                log_queue.put("FAIL")
                return

        if precision == "BF16" and hasattr(trt.BuilderFlag, 'BF16'):
            config.set_flag(trt.BuilderFlag.BF16)
            config.set_flag(trt.BuilderFlag.OBEY_PRECISION_CONSTRAINTS)
            log_queue.put("✅ [Config] BF16 및 정밀도 제어 모드 활성화")
        elif builder.platform_has_fast_fp16:
            config.set_flag(trt.BuilderFlag.FP16)
            config.set_flag(trt.BuilderFlag.OBEY_PRECISION_CONSTRAINTS)
            log_queue.put("✅ [Config] FP16 및 정밀도 제어 모드 활성화")

        # [개선] 1. 키워드를 소문자로 변환하여 리스트화 (입력 예: "softmax, norm+add, pow")
        fp32_keywords = [k.strip().lower() for k in keywords_str.split(',') if k.strip()]
        last_layer_index = network.num_layers - 1
        fallback_count = 0

        for i in range(network.num_layers):
            layer = network.get_layer(i)
            node_name_lower = layer.name.lower()
            
            # 하드코딩된 타입 방어 코드 (유지)
            is_sensitive = layer.type in [trt.LayerType.SOFTMAX, trt.LayerType.REDUCE] or (i == last_layer_index)

            # [개선] 2. 복합 키워드(AND 조건) 매칭 로직 추가
            if not is_sensitive:
                for kw in fp32_keywords:
                    if '+' in kw:  # AND 조건 (예: norm+add)
                        sub_kws = [sub.strip() for sub in kw.split('+')]
                        if all(sub in node_name_lower for sub in sub_kws):
                            is_sensitive = True
                            break
                    else:          # OR 조건 (단일 키워드)
                        if kw in node_name_lower:
                            is_sensitive = True
                            break

            if is_sensitive:
                # [개선] 3. 공식 DataType Enum 사용
                layer.precision = trt.DataType.FLOAT
                for j in range(layer.num_outputs):
                    layer.set_output_type(j, trt.DataType.FLOAT)
                
                # [개선] 4. 개별 로그는 UI 부하를 줄이기 위해 제거하거나 간소화
                # log_queue.put(f"   -> [Precision Fix] {layer.name} -> FP32 고정")
                fallback_count += 1
        
        log_queue.put(f"✅ 전체 {network.num_layers}개 중 {fallback_count}개 레이어 FP32 강제 할당 완료")

        profile = builder.create_optimization_profile()
        input_tensor = network.get_input(0)
        
        if is_dynamic:
            profile.set_shape(input_tensor.name, min_s, opt_s, max_s)
            log_queue.put(f"✅ Dynamic Shape 적용: {input_tensor.name} Min:{min_s} Opt:{opt_s} Max:{max_s}")
            config.add_optimization_profile(profile)
        else:
            static_shape = tuple(input_tensor.shape)
            if -1 in static_shape:
                log_queue.put(f"❌ [ERROR] ONNX 모델에 동적 차원이 포함되어 있습니다. UI에서 'Enable Dynamic Batch'를 체크해주세요! (현재 Shape: {static_shape})")
                log_queue.put("FAIL")
                return
                
            profile.set_shape(input_tensor.name, static_shape, static_shape, static_shape)
            log_queue.put(f"✅ Static Shape 자동 적용 (ONNX 기준): {input_tensor.name} Shape:{static_shape}")
            config.add_optimization_profile(profile)

        log_queue.put("⏳ 엔진 빌드 진행 중... (수 분 이상 소요될 수 있습니다. 내부 로그 출력 대기 중)")
        serialized_engine = builder.build_serialized_network(network, config)

        if serialized_engine:
            with open(engine_path, "wb") as f:
                f.write(serialized_engine)
            log_queue.put(f"🎉 Success! Engine saved to:\n{engine_path}")
            log_queue.put("SUCCESS")
        else:
            log_queue.put("❌ Error: 엔진 빌드 실패 (상세 에러는 TRT 내부 로그 확인)")
            log_queue.put("FAIL")

    except Exception as e:
        log_queue.put(f"❌ Exception occurred: {str(e)}")
        log_queue.put("FAIL")


class CustomQTRTLogger(trt.ILogger):
    def __init__(self, log_signal, severity_level=trt.Logger.VERBOSE):
        trt.ILogger.__init__(self)
        self.log_signal = log_signal
        self.severity_level = severity_level

    def log(self, severity, msg):
        if severity <= self.severity_level:
            prefix = ""
            if severity == trt.Logger.ERROR: prefix = "❌ [ERROR] "
            elif severity == trt.Logger.WARNING: prefix = "⚠️ [WARNING] "
            elif severity == trt.Logger.INFO: prefix = "ℹ️ [INFO] "
            elif severity == trt.Logger.VERBOSE: prefix = "🔍 [VERBOSE] "
            self.log_signal.emit(f"{prefix}{msg}")


# --- TensorRT 추론 Wrapper ---
class TRTWrapper:
    def __init__(self, engine_path):
        self.logger = trt.Logger(trt.Logger.WARNING)
        with open(engine_path, "rb") as f, trt.Runtime(self.logger) as runtime:
            self.engine = runtime.deserialize_cuda_engine(f.read())
        self.context = self.engine.create_execution_context()
        self.inputs, self.outputs, self.bindings, self.stream = self.allocate_buffers()

    def allocate_buffers(self):
        inputs, outputs, bindings = [], [], []
        stream = cuda.Stream()

        # --- input profile max shape 사전 파악 (output dynamic dim 보정용) ---
        input_max_shape = None
        for i in range(self.engine.num_io_tensors):
            tensor_name = self.engine.get_tensor_name(i)
            if self.engine.get_tensor_mode(tensor_name) == trt.TensorIOMode.INPUT:
                shape = self.engine.get_tensor_shape(tensor_name)
                if any(d < 0 for d in shape):
                    try:
                        profile_shapes = self.engine.get_tensor_profile_shape(tensor_name, 0)
                        input_max_shape = profile_shapes[2]  # max
                    except Exception:
                        pass
                else:
                    input_max_shape = shape
                break  # 첫 번째 input만 참조

        for i in range(self.engine.num_io_tensors):
            tensor_name = self.engine.get_tensor_name(i)
            shape = self.engine.get_tensor_shape(tensor_name)
            dtype = trt.nptype(self.engine.get_tensor_dtype(tensor_name))
            is_input = self.engine.get_tensor_mode(tensor_name) == trt.TensorIOMode.INPUT

            # Dynamic shape(-1 포함) 처리
            alloc_shape = shape
            if any(d < 0 for d in shape):
                if is_input:
                    # input: profile max shape 사용
                    try:
                        profile_shapes = self.engine.get_tensor_profile_shape(tensor_name, 0)
                        alloc_shape = profile_shapes[2]
                    except Exception:
                        alloc_shape = tuple(abs(d) if d < 0 else d for d in shape)
                else:
                    # output: -1 자리를 input max batch로 송이 (e.g. (-1,4) -> (max_batch,4))
                    if input_max_shape is not None:
                        max_batch = input_max_shape[0]
                        alloc_shape = tuple(max_batch if d < 0 else d for d in shape)
                    else:
                        alloc_shape = tuple(abs(d) if d < 0 else d for d in shape)

            size = trt.volume(alloc_shape)
            alloc = cuda.mem_alloc(size * np.dtype(dtype).itemsize)
            bindings.append(int(alloc))

            entry = {'name': tensor_name, 'alloc': alloc,
                     'shape': alloc_shape, 'dtype': dtype, 'alloc_size': size}
            if is_input:
                inputs.append(entry)
            else:
                outputs.append(entry)

        return inputs, outputs, bindings, stream

    def infer(self, input_data):
        input_data = np.ascontiguousarray(input_data)
        actual_shape = input_data.shape

        # 🔥 TensorRT 버전에 따른 동적 분기 실행 (v2 vs v3)
        trt_major_version = int(trt.__version__.split('.')[0])

        if trt_major_version >= 10:
            # Dynamic shape: 실제 입력 shape 설정
            self.context.set_input_shape(self.inputs[0]['name'], actual_shape)
            cuda.memcpy_htod_async(self.inputs[0]['alloc'], input_data, self.stream)
            for binding in self.inputs + self.outputs:
                self.context.set_tensor_address(binding['name'], binding['alloc'])
            self.context.execute_async_v3(stream_handle=self.stream.handle)
        else:
            # TRT < 10: set_binding_shape으로 dynamic batch 대응
            input_binding_idx = self.engine.get_binding_index(self.inputs[0]['name'])
            self.context.set_binding_shape(input_binding_idx, actual_shape)
            cuda.memcpy_htod_async(self.inputs[0]['alloc'], input_data, self.stream)
            self.context.execute_async_v2(bindings=self.bindings, stream_handle=self.stream.handle)

        # 동기화 후 실제 output shape 확인 (실행 완료 후에만 shape 결정됨)
        self.stream.synchronize()

        res = []
        for out in self.outputs:
            # allocate_buffers에서 저장한 alloc_size 기준으로 flat 버퍼 생성
            alloc_elems = out['alloc_size']
            flat_buf = np.zeros(alloc_elems, dtype=out['dtype'])
            cuda.memcpy_dtoh(flat_buf, out['alloc'])

            # 실제 output shape 확인 및 reshape
            try:
                if trt_major_version >= 10:
                    real_shape = tuple(self.context.get_tensor_shape(out['name']))
                else:
                    out_idx = self.engine.get_binding_index(out['name'])
                    real_shape = tuple(self.context.get_binding_shape(out_idx))
                if any(d <= 0 for d in real_shape):
                    real_shape = out['shape']
            except Exception:
                real_shape = out['shape']

            real_size = int(np.prod(real_shape))
            res.append(flat_buf[:real_size].reshape(real_shape))

        return res