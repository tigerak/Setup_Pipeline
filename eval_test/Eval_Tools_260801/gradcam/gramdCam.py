import os
import importlib
from datetime import datetime

import numpy as np
import torch.nn.functional as F
import torch
from PIL import Image

_orig_ln_forward = torch.nn.LayerNorm.forward
def _patched_ln_forward(self, input_tensor):
    norm_shape = self.normalized_shape
    if isinstance(norm_shape, int):
        norm_shape = (norm_shape,)
        
    # onnx2torch가 실수로 0을 넘겼다면 가중치(Weight)의 shape으로 복구
    if getattr(norm_shape, '__iter__', None) and 0 in norm_shape:
        if self.weight is not None:
            norm_shape = self.weight.shape
        else:
            norm_shape = input_tensor.shape[-1:]
            
    return F.layer_norm(input_tensor, norm_shape, self.weight, self.bias, self.eps)

torch.nn.LayerNorm.forward = _patched_ln_forward

_orig_layer_norm = F.layer_norm
def _patched_layer_norm(input_tensor, normalized_shape, weight=None, bias=None, eps=1e-5):
    if isinstance(normalized_shape, int):
        normalized_shape = (normalized_shape,)
        
    if getattr(normalized_shape, '__iter__', None) and 0 in normalized_shape:
        if weight is not None:
            normalized_shape = weight.shape
        else:
            normalized_shape = input_tensor.shape[-1:]
            
    return _orig_layer_norm(input_tensor, normalized_shape, weight, bias, eps)

F.layer_norm = _patched_layer_norm

def _parse_preprocess(resize_str, mean_str, std_str):
	resize_parts = [p.strip() for p in resize_str.split(',')]
	mean_parts = [p.strip() for p in mean_str.split(',')]
	std_parts = [p.strip() for p in std_str.split(',')]

	if len(resize_parts) != 2:
		raise ValueError("resize는 'W, H' 형식이어야 합니다.")
	if len(mean_parts) != 3 or len(std_parts) != 3:
		raise ValueError("mean/std는 'R, G, B' 형식이어야 합니다.")

	resize_w, resize_h = int(resize_parts[0]), int(resize_parts[1])
	mean = np.array([float(v) for v in mean_parts], dtype=np.float32)
	std = np.array([float(v) for v in std_parts], dtype=np.float32)

	if np.any(std == 0):
		raise ValueError("std 값에 0이 포함될 수 없습니다.")

	return resize_w, resize_h, mean, std


def _build_torch_model_from_onnx(onnx_path):
    try:
        onnx = importlib.import_module("onnx")
        onnx2torch_mod = importlib.import_module("onnx2torch")
        convert = getattr(onnx2torch_mod, "convert")
        
        # ------------------------------------------------------------------
        # [Clip 버그 무력화 패치 완결판] 레지스트리 자동 추적 및 덮어쓰기
        # ------------------------------------------------------------------
        try:
            reg_mod = importlib.import_module("onnx2torch.node_converters.registry")
            OperationDescription = getattr(reg_mod, "OperationDescription")
            common_mod = importlib.import_module("onnx2torch.utils.common")
            OperationConverterResult = getattr(common_mod, "OperationConverterResult")
            onnx_mapping_from_node = getattr(common_mod, "onnx_mapping_from_node")

            # 1. 레지스트리 딕셔너리 무조건 찾아내기
            registry_dict = None
            
            # 시도 1: onnx2torch 공식 변수명 확인
            for attr_name in ["_CONVERTER_REGISTRY", "_REGISTRY", "_CONVERTERS", "REGISTRY"]:
                if hasattr(reg_mod, attr_name):
                    registry_dict = getattr(reg_mod, attr_name)
                    break
            
            # 시도 2: 못 찾았다면, 모듈 안의 모든 dict를 뒤져서 OperationDescription 키를 가진 것을 강제 탐색
            if registry_dict is None:
                for attr_name, attr_val in vars(reg_mod).items():
                    if isinstance(attr_val, dict) and len(attr_val) > 0:
                        first_key = list(attr_val.keys())[0]
                        if type(first_key).__name__ == "OperationDescription":
                            registry_dict = attr_val
                            break

            # 2. 딕셔너리를 찾았다면 커스텀 Clip 덮어쓰기 진행
            if registry_dict is not None:
                class DynamicClip(torch.nn.Module):
                    def forward(self, input_tensor, min_val=None, max_val=None):
                        out = input_tensor
                        if min_val is not None:
                            if not isinstance(min_val, torch.Tensor):
                                min_val = torch.tensor(min_val, device=out.device)
                            out = torch.maximum(out, min_val)
                        if max_val is not None:
                            if not isinstance(max_val, torch.Tensor):
                                max_val = torch.tensor(max_val, device=out.device)
                            out = torch.minimum(out, max_val)
                        return out

                def _custom_clip_converter(node, graph):
                    return OperationConverterResult(
                        torch_module=DynamicClip(),
                        onnx_mapping=onnx_mapping_from_node(node)
                    )

                # 1~25 opset 버전 전체의 Clip 변환기 강제 교체
                for opset in range(1, 26):
                    desc = OperationDescription(domain='', operation_type='Clip', version=opset)
                    registry_dict[desc] = _custom_clip_converter
                
                print("[SUCCESS] Clip 몽키 패치가 완벽하게 적용되었습니다!")
            else:
                print("[Warning] 레지스트리 딕셔너리를 찾지 못했습니다.")
                
        except Exception as patch_err:
            print(f"[Warning] Clip 몽키 패치 중 오류 발생: {patch_err}")
        # ------------------------------------------------------------------

    except ImportError as exc:
        raise ImportError(
            f"onnx/onnx2torch 모듈을 로드하지 못했습니다: {exc}"
        ) from exc

    onnx_model = onnx.load(onnx_path)
    model = convert(onnx_model)
    model.eval()
    return model

def _build_torch_model_with_auto_fallback(onnx_path, fixed_shape=None):
    """
    1) 기본 onnx2torch 변환 시도
    2) 실패 시 onnxsim simplify (Shape 고정 포함) 후 재시도
    """
    try:
        model = _build_torch_model_from_onnx(onnx_path)
        return model, "direct", None
    except Exception as first_exc:
        first_error = str(first_exc)

        # simplify fallback
        try:
            onnx = importlib.import_module("onnx")
            onnxsim = importlib.import_module("onnxsim")
            simplify = getattr(onnxsim, "simplify")

            model_in = onnx.load(onnx_path)
            
            # --- 수정된 부분: 입력 Shape 강제 고정 ---
            kwargs = {}
            if fixed_shape is not None:
                # 모델의 첫 번째 입력 이름을 자동으로 찾아서 shape 매핑
                input_name = model_in.graph.input[0].name
                kwargs['overwrite_input_shapes'] = {input_name: fixed_shape}
            
            model_simp, ok = simplify(model_in, **kwargs)
            # ----------------------------------------

            if not ok:
                raise RuntimeError("onnxsim validation failed")

            onnx2torch_mod = importlib.import_module("onnx2torch")
            convert = getattr(onnx2torch_mod, "convert")
            model = convert(model_simp)
            model.eval()
            return model, "onnxsim", first_error
        except Exception as second_exc:
            raise RuntimeError(f"direct={first_error} | simplify={second_exc}") from second_exc

def _load_onnx_model(onnx_path):
	try:
		onnx = importlib.import_module("onnx")
	except ImportError as exc:
		raise ImportError("onnx 모듈이 필요합니다. pip install onnx") from exc
	return onnx.load(onnx_path)


def _extract_onnx_graph_layers_reverse(onnx_path):
	"""onnx2torch 변환이 실패해도 ONNX graph node 기준으로 레이어 목록을 반환합니다."""
	onnx_model = _load_onnx_model(onnx_path)
	layers = []
	for idx, node in enumerate(onnx_model.graph.node):
		node_name = node.name.strip() if getattr(node, "name", "") else ""
		if not node_name:
			if len(node.output) > 0 and node.output[0]:
				node_name = node.output[0]
			else:
				node_name = f"node_{idx}"
		layers.append({
			"name": node_name,
			"type": getattr(node, "op_type", "Unknown"),
			"source": "onnx_graph",
		})
	layers.reverse()
	return layers


def _get_onnx_input_summary(onnx_path):
	"""에러 메시지용 간단한 입력/동적 shape 요약."""
	onnx_model = _load_onnx_model(onnx_path)
	summary_parts = []
	for value_info in onnx_model.graph.input:
		shape_parts = []
		tensor_type = value_info.type.tensor_type
		for dim in tensor_type.shape.dim:
			if dim.dim_param:
				shape_parts.append(dim.dim_param)
			elif dim.dim_value:
				shape_parts.append(str(dim.dim_value))
			else:
				shape_parts.append("?")
		summary_parts.append(f"{value_info.name}:({', '.join(shape_parts)})")
	return "; ".join(summary_parts)


def _normalize_layer_key(name):
	if not name:
		return ""
	key = str(name).lower().strip()
	for ch in ["/", "\\", ".", ":", "-", " "]:
		key = key.replace(ch, "_")
	while "__" in key:
		key = key.replace("__", "_")
	return key.strip("_")


def _resolve_target_layer(module_dict, selected_name):
	"""
	선택한 레이어명을 torch module dict에서 최대한 유연하게 매칭.
	- exact match
	- normalized exact match
	- suffix/contains match
	"""
	if selected_name in module_dict:
		return module_dict[selected_name], selected_name, "exact"

	norm_selected = _normalize_layer_key(selected_name)
	norm_map = {k: _normalize_layer_key(k) for k in module_dict.keys()}

	# normalized exact
	for original_name, norm_name in norm_map.items():
		if norm_name == norm_selected:
			return module_dict[original_name], original_name, "normalized-exact"

	# suffix match
	for original_name, norm_name in norm_map.items():
		if norm_name.endswith(norm_selected) or norm_selected.endswith(norm_name):
			return module_dict[original_name], original_name, "suffix"

	# contains match
	for original_name, norm_name in norm_map.items():
		if norm_selected and norm_selected in norm_name:
			return module_dict[original_name], original_name, "contains"

	return None, None, "not-found"


def list_onnx_layers_reverse(onnx_path):
	"""
	가능하면 onnx2torch 변환 결과의 named_modules를 사용하고,
	실패하면 ONNX graph node를 역순으로 반환합니다.

	Returns:
		list[dict]: [{"name": layer_name, "type": class_name}, ...]
	"""
	try:
		model = _build_torch_model_from_onnx(onnx_path)
		layers = []
		for name, module in model.named_modules():
			if not name:
				continue
			layers.append({"name": name, "type": module.__class__.__name__, "source": "torch_module"})
		layers.reverse()
		return layers
	except Exception:
		return _extract_onnx_graph_layers_reverse(onnx_path)


def _reshape_transform_auto(tensor):
	"""
	Transformer 계열 출력(B, N, C)을 Grad-CAM용 2D feature map(B, C, H, W)으로 변환.
	Conv 계열 출력은 가능한 한 원형 유지.
	"""
	if not isinstance(tensor, torch.Tensor):
		raise ValueError("reshape_transform 입력이 Tensor가 아닙니다.")

	if tensor.ndim == 4:
		# 보통 Conv 출력: B,C,H,W
		# 일부 케이스 NHWC: B,H,W,C
		if tensor.shape[1] <= 4 and tensor.shape[-1] > 4:
			return tensor.permute(0, 3, 1, 2)
		return tensor

	if tensor.ndim == 3:
		batch, tokens, channels = tensor.shape
		spatial_tokens = tokens
		start_idx = 0

		# CLS 토큰이 있을 수 있으므로 (N-1)도 검사
		side = int(spatial_tokens ** 0.5)
		if side * side != spatial_tokens:
			candidate = tokens - 1
			side = int(candidate ** 0.5)
			if candidate > 0 and side * side == candidate:
				spatial_tokens = candidate
				start_idx = 1

		if side * side == spatial_tokens and spatial_tokens > 0:
			feat = tensor[:, start_idx:start_idx + spatial_tokens, :]
			feat = feat.reshape(batch, side, side, channels).permute(0, 3, 1, 2)
			return feat

		# 정사각 맵 복원이 불가능한 경우: 시퀀스를 1D map으로 강등
		return tensor.transpose(1, 2).unsqueeze(-1)

	if tensor.ndim == 2:
		return tensor.unsqueeze(-1).unsqueeze(-1)

	raise ValueError(f"지원하지 않는 feature ndim: {tensor.ndim}")


def _infer_target_layer_ndim(model, target_layer, input_tensor):
	captured = {"ndim": None}

	def hook_fn(_, __, output):
		out = output[0] if isinstance(output, (list, tuple)) and len(output) > 0 else output
		if isinstance(out, torch.Tensor):
			captured["ndim"] = out.ndim

	handle = target_layer.register_forward_hook(hook_fn)
	try:
		with torch.no_grad():
			_ = model(input_tensor)
	except Exception:
		pass
	finally:
		handle.remove()

	return captured["ndim"]


def run_onnx_gradcam(
	onnx_path,
	img_dir,
	save_dir,
	resize_str,
	mean_str,
	std_str,
	target_class,
	target_layer_name,
	model_meta=None,
	log_callback=None,
	progress_callback=None,
):
	"""
	ONNX 모델에 대해 onnx2torch + pytorch-grad-cam 기반 Grad-CAM 실행.

	저장 포맷:
	- PNG 한 장에 좌측: overlay, 우측: 원본 (grid 형태)

	Returns:
		dict: {
			"success": bool,
			"output_dir": str | None,
			"saved_images": list[str],
			"error": str | None
		}
	"""

	def log(msg):
		if log_callback:
			log_callback(msg)

	def progress(current, total):
		if progress_callback:
			progress_callback(current, total)

	if model_meta is None:
		model_meta = {}

	if not os.path.exists(onnx_path):
		return {"success": False, "output_dir": None, "saved_images": [], "error": "ONNX 파일이 존재하지 않습니다."}
	if not os.path.isdir(img_dir):
		return {"success": False, "output_dir": None, "saved_images": [], "error": "이미지 폴더가 존재하지 않습니다."}
	if not target_layer_name:
		return {"success": False, "output_dir": None, "saved_images": [], "error": "타겟 레이어가 선택되지 않았습니다."}

	try:
		resize_w, resize_h, mean, std = _parse_preprocess(resize_str, mean_str, std_str)
	except Exception as exc:
		return {"success": False, "output_dir": None, "saved_images": [], "error": f"전처리 파라미터 파싱 실패: {exc}"}

	try:
		gradcam_mod = importlib.import_module("pytorch_grad_cam")
		image_utils_mod = importlib.import_module("pytorch_grad_cam.utils.image")
		target_utils_mod = importlib.import_module("pytorch_grad_cam.utils.model_targets")
		GradCAM = getattr(gradcam_mod, "GradCAM")
		GradCAMPlusPlus = getattr(gradcam_mod, "GradCAMPlusPlus", None)
		show_cam_on_image = getattr(image_utils_mod, "show_cam_on_image")
		ClassifierOutputTarget = getattr(target_utils_mod, "ClassifierOutputTarget")
	except ImportError as exc:
		return {
			"success": False,
			"output_dir": None,
			"saved_images": [],
			"error": "pytorch-grad-cam 모듈이 필요합니다. pip install grad-cam",
		}

	convert_mode = "direct"
	original_convert_error = None
	try:
		shape_str = (model_meta.get('fixed_input_shape') or '').strip()
		fixed_shape = None
		if shape_str:
			shape_list = [int(x.strip()) for x in shape_str.split(',')]
			if len(shape_list) != 4:
				raise ValueError("fixed_input_shape는 'N,C,H,W' 4개 값이어야 합니다.")
			fixed_shape = shape_list
		model, convert_mode, original_convert_error = _build_torch_model_with_auto_fallback(onnx_path, fixed_shape=fixed_shape)
	except Exception as exc:
		input_summary = ""
		try:
			input_summary = _get_onnx_input_summary(onnx_path)
		except Exception:
			input_summary = "입력 shape 요약 추출 실패"
		return {
			"success": False,
			"output_dir": None,
			"saved_images": [],
			"error": (
				f"ONNX 모델 변환 실패: {exc}\n"
				f"입력 정보: {input_summary}\n"
				f"Fixed Input Shape: {shape_str if shape_str else 'Auto'}\n"
				"자동 복구(onnxsim simplify)까지 실패했습니다.\n"
				"입력한 메타 정보를 기준으로 ONNX 재export(특히 static shape) 후 다시 시도해주세요."
			),
		}

	module_dict = dict(model.named_modules())
	target_layer, resolved_layer_name, match_mode = _resolve_target_layer(module_dict, target_layer_name)
	if target_layer is None:
		return {
			"success": False,
			"output_dir": None,
			"saved_images": [],
			"error": (
				f"선택한 레이어를 torch 모델에서 찾지 못했습니다: {target_layer_name}\n"
				"레이어 목록이 ONNX graph fallback일 수 있습니다. 다른 레이어(뒤쪽 Conv/Norm/Block)를 선택하거나 static ONNX로 재export 해주세요."
			),
		}

	image_files = sorted(
		[f for f in os.listdir(img_dir) if f.lower().endswith((".png", ".jpg", ".jpeg", ".bmp"))]
	)
	if not image_files:
		return {"success": False, "output_dir": None, "saved_images": [], "error": "이미지 폴더에 처리할 파일이 없습니다."}

	today = datetime.now().strftime("%y%m%d")
	output_dir = os.path.join(save_dir, f"{today}_gradcam")
	os.makedirs(output_dir, exist_ok=True)

	device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
	model.to(device)

	log(f"[SUCCESS] ONNX -> Torch 변환 완료")
	if convert_mode == "onnxsim":
		log(f"[WARNING] direct 변환 실패로 onnxsim simplify fallback 사용: {original_convert_error}")
	log(f"[SUCCESS] Device: {device}")
	log(f"[SUCCESS] Target Layer: {resolved_layer_name} (from: {target_layer_name}, match: {match_mode})")
	log(f"[SUCCESS] Target Class: {target_class}")

	saved_paths = []
	progress(0, len(image_files))

	# 첫 이미지 기준으로 target layer output 차원 추정 (Transformer 대응)
	test_img_path = os.path.join(img_dir, image_files[0])
	test_pil = Image.open(test_img_path).convert("RGB").resize((resize_w, resize_h), Image.BILINEAR)
	test_np = np.array(test_pil, dtype=np.float32) / 255.0
	test_norm = (test_np - mean) / std
	test_chw = test_norm.transpose(2, 0, 1)
	test_tensor = torch.from_numpy(test_chw).unsqueeze(0).float().to(device)

	target_ndim = _infer_target_layer_ndim(model, target_layer, test_tensor)
	use_reshape_transform = target_ndim in (2, 3)
	if use_reshape_transform:
		log(f"[SUCCESS] Transformer/Sequence layer 감지 (ndim={target_ndim}), reshape_transform 활성화")
	else:
		log(f"[SUCCESS] Conv-like layer 감지 (ndim={target_ndim})")

	try:
		if use_reshape_transform:
			cam_extractor = GradCAM(model=model, target_layers=[target_layer], reshape_transform=_reshape_transform_auto)
		else:
			cam_extractor = GradCAM(model=model, target_layers=[target_layer])
	except Exception as exc:
		if GradCAMPlusPlus is None:
			return {
				"success": False,
				"output_dir": output_dir,
				"saved_images": [],
				"error": f"GradCAM 초기화 실패: {exc}",
			}
		try:
			if use_reshape_transform:
				cam_extractor = GradCAMPlusPlus(model=model, target_layers=[target_layer], reshape_transform=_reshape_transform_auto)
			else:
				cam_extractor = GradCAMPlusPlus(model=model, target_layers=[target_layer])
			log("[WARNING] GradCAM 초기화 실패로 GradCAM++ fallback 사용")
		except Exception as fallback_exc:
			return {
				"success": False,
				"output_dir": output_dir,
				"saved_images": [],
				"error": f"GradCAM/GradCAM++ 초기화 실패: {fallback_exc}",
			}

	for index, image_name in enumerate(image_files, start=1):
		image_path = os.path.join(img_dir, image_name)
		try:
			pil_img = Image.open(image_path).convert("RGB").resize((resize_w, resize_h), Image.BILINEAR)
			img_np_uint8 = np.array(pil_img, dtype=np.uint8)
			img_np_float = img_np_uint8.astype(np.float32) / 255.0

			normalized = (img_np_float - mean) / std
			chw = normalized.transpose(2, 0, 1)
			input_tensor = torch.from_numpy(chw).unsqueeze(0).float().to(device)

			cam_targets = [ClassifierOutputTarget(int(target_class))]
			grayscale_cam = cam_extractor(input_tensor=input_tensor, targets=cam_targets)
			grayscale_cam = grayscale_cam[0]

			overlay = show_cam_on_image(img_np_float, grayscale_cam, use_rgb=True)

			grid = np.concatenate([overlay, img_np_uint8], axis=1)
			save_name = os.path.splitext(image_name)[0] + ".png"
			save_path = os.path.join(output_dir, save_name)
			Image.fromarray(grid.astype(np.uint8)).save(save_path, format="PNG")
			saved_paths.append(save_path)

			log(f"[{index}/{len(image_files)}] {image_name} -> {save_name}")
		except Exception as exc:
			log(f"[WARNING] 처리 실패 ({image_name}): {exc}")
		finally:
			progress(index, len(image_files))

	if len(saved_paths) == 0:
		return {
			"success": False,
			"output_dir": output_dir,
			"saved_images": [],
			"error": "모든 이미지 처리에 실패했습니다.",
		}

	log(f"[SUCCESS] 저장 완료: {output_dir}")
	return {"success": True, "output_dir": output_dir, "saved_images": saved_paths, "error": None}