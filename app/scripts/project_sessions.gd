extends RefCounted

signal warning(message: String)
const VERSION := 1
const LIMIT := 20
var history_path := "user://recent_projects.json"
var recent: Array[Dictionary] = []

func _init(path := "") -> void:
	var settings := OS.get_environment("REMIX_STUDIO_SETTINGS_DIR")
	if not path.is_empty():
		history_path = path
	elif not settings.is_empty():
		history_path = settings.path_join("recent_projects.json")

func project_path(path: String) -> String:
	return ProjectSettings.globalize_path(path).simplify_path()

func _key(path: String) -> String:
	var normalized := project_path(path)
	return normalized.to_lower() if OS.get_name() == "Windows" else normalized

func read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parser := JSON.new()
	if parser.parse(FileAccess.get_file_as_string(path)) != OK or not parser.data is Dictionary:
		warning.emit("Could not read " + path.get_file() + "; using defaults.")
		return {}
	return parser.data

func load_history() -> void:
	recent.clear()
	var data := read_json(history_path)
	if data.get("version") != VERSION or not data.get("projects") is Array:
		return
	var seen := {}
	for entry in data.projects:
		if not entry is Dictionary or not entry.get("path") is String or not entry.path.is_absolute_path():
			continue
		var key := _key(entry.path)
		if seen.has(key):
			continue
		seen[key] = true
		var opened = entry.get("last_opened", 0)
		recent.append({"path": project_path(entry.path), "last_opened": opened if opened is float or opened is int else 0})
	recent.sort_custom(func(a: Dictionary, b: Dictionary): return a.last_opened > b.last_opened)
	if recent.size() > LIMIT:
		recent.resize(LIMIT)

func _write_json(path: String, data: Dictionary) -> bool:
	var absolute := ProjectSettings.globalize_path(path)
	if DirAccess.make_dir_recursive_absolute(absolute.get_base_dir()) != OK:
		return _failed(path)
	var temporary := absolute + ".saving"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return _failed(path)
	file.store_string(JSON.stringify(data, "\t", true, true))
	file.flush()
	var error := file.get_error()
	file.close()
	if error != OK or DirAccess.rename_absolute(temporary, absolute) != OK:
		DirAccess.remove_absolute(temporary)
		return _failed(path)
	return true

func _failed(path: String) -> bool:
	warning.emit("Could not save " + path.get_file() + ". Previous settings were kept; the USD save result is unchanged.")
	return false

func opened(path: String) -> bool:
	var previous := recent.duplicate(true)
	recent = recent.filter(func(entry: Dictionary): return _key(entry.path) != _key(path))
	recent.push_front({"path": project_path(path), "last_opened": Time.get_unix_time_from_system()})
	if recent.size() > LIMIT:
		recent.resize(LIMIT)
	if not _write_json(history_path, {"version": VERSION, "projects": recent}):
		recent = previous
		return false
	return true

func forget(path: String) -> bool:
	var previous := recent.duplicate(true)
	recent = recent.filter(func(entry: Dictionary): return _key(entry.path) != _key(path))
	if not _write_json(history_path, {"version": VERSION, "projects": recent}):
		recent = previous
		return false
	return true

func read_view(path: String) -> Dictionary:
	var data := read_json(project_path(path) + ".studio.json")
	return data if data.get("version") == VERSION else {}

func camera_for(path: String, capture := "") -> Variant:
	var data := read_view(path)
	if not capture.is_empty():
		var cameras = data.get("capture_cameras", {})
		if cameras is Dictionary and cameras.has(capture):
			return cameras[capture]
		# A legacy workfile's single camera belongs to its original capture.
		if data.has("capture_cameras"):
			return null
	return data.get("camera")

func save_view(path: String, camera: Dictionary, saved_at := 0.0, capture := "") -> bool:
	var data := read_view(path)
	data["version"] = VERSION
	data["camera"] = camera
	if not capture.is_empty():
		if not data.get("capture_cameras") is Dictionary:
			data["capture_cameras"] = {}
		data.capture_cameras[capture] = camera
	if saved_at > 0:
		data["last_saved"] = saved_at
	return _write_json(project_path(path) + ".studio.json", data)

func save_thumbnail(path: String, image: Image, saved_at: float) -> bool:
	var target := project_path(path) + ".studio.png"
	var temporary := target + ".saving.png"
	if image == null or image.is_empty() or image.save_png(temporary) != OK:
		return _failed(target)
	if DirAccess.rename_absolute(temporary, target) != OK:
		DirAccess.remove_absolute(temporary)
		return _failed(target)
	# Read again: closing or flying since Save may have updated the remembered camera.
	var data := read_view(path)
	data["version"] = VERSION
	data["preview_saved_at"] = saved_at
	return _write_json(project_path(path) + ".studio.json", data)
