extends RefCounted

signal warning(message: String)
const Storage = preload("res://scripts/project_sessions.gd")
const DEFAULTS := {"upscaler": "auto", "quality": "auto", "ray_reconstruction": true, "width": 960, "height": 540}
const UPSCALERS := {"auto": "Automatic (DLSS / TAAU)", "dlss": "DLSS", "taau": "TAAU", "nis": "NIS", "none": "Off (native resolution)"}
const QUALITIES := {"auto": "Automatic", "ultra_performance": "Ultra performance", "performance": "Performance", "balanced": "Balanced", "quality": "Quality", "native": "Native resolution"}
var values := DEFAULTS.duplicate()
var storage := Storage.new()
var path: String

func _init(settings_path := "") -> void:
	path = settings_path if not settings_path.is_empty() else storage.history_path.get_base_dir().path_join("render_settings.json")
	storage.warning.connect(func(message: String): warning.emit(message))

static func sanitized(data: Dictionary) -> Dictionary:
	var result := DEFAULTS.duplicate()
	if data.get("upscaler") is String and UPSCALERS.has(data.upscaler):
		result.upscaler = data.upscaler
	if data.get("quality") is String and QUALITIES.has(data.quality):
		result.quality = data.quality
	if data.get("ray_reconstruction") is bool:
		result.ray_reconstruction = data.ray_reconstruction
	for key in ["width", "height"]:
		var value = data.get(key)
		if (value is int or value is float) and is_finite(value) and value >= 16 and value <= 8192 and value == floor(value):
			result[key] = int(value)
	return result

static func qualities_for(upscaler: String) -> Array:
	if upscaler == "none": return ["native"]
	if upscaler == "nis": return ["performance", "balanced", "quality", "native"]
	if upscaler == "taau": return ["ultra_performance", "performance", "balanced", "quality", "native"]
	return QUALITIES.keys()

func load_settings() -> void:
	var data := storage.read_json(path)
	values = sanitized(data.get("settings", {})) if data.get("version") == 1 and data.get("settings") is Dictionary else DEFAULTS.duplicate()

func save_settings(settings: Dictionary) -> bool:
	var next := sanitized(settings)
	if not storage._write_json(path, {"version": 1, "settings": next}): return false
	values = next
	return true
