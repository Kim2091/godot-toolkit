extends RefCounted

signal warning(message: String)
const Storage = preload("res://scripts/project_sessions.gd")
const OpenRemix = preload("res://scripts/openremix_settings.gd")
const DEFAULTS := {"upscaler": "auto", "quality": "auto", "ray_reconstruction": true, "width": 960, "height": 540}
const UPSCALERS := {"auto": "Automatic (DLSS / TAAU)", "dlss": "DLSS", "taau": "TAAU", "nis": "NIS", "none": "Off (native resolution)"}
const QUALITIES := {"auto": "Automatic", "ultra_performance": "Ultra performance", "performance": "Performance", "balanced": "Balanced", "quality": "Quality", "native": "Native resolution"}
static var OPENREMIX_DEFAULTS := {"backend": "pathtrace", "upscaler": "auto", "quality": "auto", "ray_reconstruction": true, "width": 960, "height": 540, "pathtrace": OpenRemix.defaults()}
const OPENREMIX_UPSCALERS := {"auto": "Automatic (DLSS / FSR)", "dlss": "DLSS", "fsr31": "FSR 3.1", "none": "Off (native resolution)"}
var renderer := "remix"
var entries := {"remix": DEFAULTS.duplicate(true), "openremix": OPENREMIX_DEFAULTS.duplicate(true)}
var values := DEFAULTS.duplicate()
var storage := Storage.new()
var path: String

func _init(settings_path := "") -> void:
	path = settings_path if not settings_path.is_empty() else storage.history_path.get_base_dir().path_join("render_settings.json")
	storage.warning.connect(func(message: String): warning.emit(message))

static func sanitized(data: Dictionary, renderer_id := "remix") -> Dictionary:
	var result: Dictionary = (OPENREMIX_DEFAULTS if renderer_id == "openremix" else DEFAULTS).duplicate(true)
	if renderer_id == "openremix": result.pathtrace = OpenRemix.sanitized(data.get("pathtrace", {}))
	var upscalers: Dictionary = OPENREMIX_UPSCALERS if renderer_id == "openremix" else UPSCALERS
	if renderer_id == "openremix" and data.get("backend") in ["pathtrace", "raster"]:
		result.backend = data.backend
	if data.get("upscaler") is String and upscalers.has(data.upscaler):
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
	renderer = "remix"
	entries = {"remix": DEFAULTS.duplicate(true), "openremix": OPENREMIX_DEFAULTS.duplicate(true)}
	if data.get("version") == 1 and data.get("settings") is Dictionary:
		entries.remix = sanitized(data.settings)
	elif data.get("version") == 2 and data.get("renderers") is Dictionary:
		for key in entries:
			if data.renderers.get(key) is Dictionary: entries[key] = sanitized(data.renderers[key], key)
		if data.get("renderer") in entries: renderer = data.renderer
	values = entries[renderer].duplicate(true)

func select_renderer(renderer_id: String) -> bool:
	if renderer_id not in entries: return false
	if not storage._write_json(path, {"version": 2, "renderer": renderer_id, "renderers": entries}): return false
	renderer = renderer_id
	values = entries[renderer].duplicate(true)
	return true

func save_settings(settings: Dictionary) -> bool:
	var next := sanitized(settings, renderer)
	var updated := entries.duplicate(true)
	updated[renderer] = next
	if not storage._write_json(path, {"version": 2, "renderer": renderer, "renderers": updated}): return false
	entries = updated
	values = next
	return true
