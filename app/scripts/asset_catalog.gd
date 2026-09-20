extends RefCounted

signal changed
signal error(message: String)

var project_directory := ""
var folders: Dictionary = {}
var entries: Dictionary = {}
var writable := true
var last_error := ""

func open_project(directory: String) -> void:
	project_directory = directory
	folders = {}; entries = {}; writable = true; last_error = ""
	var path := directory.path_join("assets/.library.json")
	if FileAccess.file_exists(path):
		var parser := JSON.new()
		var parsed := parser.parse(FileAccess.get_file_as_string(path))
		var data = parser.data
		if parsed != OK or not _valid_catalog(data):
			writable = false
			_report("The asset catalog is invalid. Organization is read-only; the original catalog was preserved.")
		else:
			folders = data.folders
			entries = data.assets
	discover()

func _valid_catalog(data: Variant) -> bool:
	if not data is Dictionary or data.get("version") != 1 or not data.get("folders") is Dictionary or not data.get("assets") is Dictionary:
		return false
	for id in data.folders:
		var folder = data.folders[id]
		if not id is String or id.is_empty() or not folder is Dictionary or not folder.get("name") is String or not folder.get("parent") is String:
			return false
		if not _valid_name(folder.name):
			return false
	for id in data.folders:
		var parent: String = id
		var visited := {}
		while not parent.is_empty():
			if visited.has(parent) or not data.folders.has(parent):
				return false
			visited[parent] = true
			parent = data.folders[parent].get("parent", "")
	for id in data.assets:
		var entry = data.assets[id]
		if not id is String or not id.begins_with("assets/") or id.simplify_path() != id or not id.ends_with("/asset.usda"):
			return false
		if not entry is Dictionary or not entry.get("name") is String or not entry.get("folder") is String:
			return false
		if not entry.get("kind", "unknown") in ["unknown", "mesh", "material"] or entry.name.is_empty():
			return false
		if not entry.folder.is_empty() and not data.folders.has(entry.folder):
			return false
	return true

func discover() -> void:
	if project_directory.is_empty():
		return
	var root := project_directory.path_join("assets")
	if not DirAccess.dir_exists_absolute(root):
		changed.emit()
		return
	for name in DirAccess.get_directories_at(root):
		if name.begins_with("."):
			continue
		var id := "assets/" + name + "/asset.usda"
		if FileAccess.file_exists(project_directory.path_join(id)) and not entries.has(id):
			entries[id] = {"name": name, "folder": "", "kind": "unknown"}
	changed.emit()

func available(id: String) -> bool:
	return entries.has(id) and FileAccess.file_exists(project_directory.path_join(id))

func absolute_path(id: String) -> String:
	return project_directory.path_join(id) if entries.has(id) else ""

func _valid_name(value: String) -> bool:
	return not value.strip_edges().is_empty() and value not in [".", ".."] and not "/" in value and not "\\" in value

func _folder_exists(id: String) -> bool:
	return id.is_empty() or folders.has(id)

func _name_free(name: String, parent: String, except := "") -> bool:
	for id in folders:
		if id != except and folders[id].parent == parent and folders[id].name.nocasecmp_to(name) == 0:
			return false
	return true

func _report(message: String) -> bool:
	last_error = message
	error.emit(message)
	return false

func _save(before_folders: Dictionary, before_entries: Dictionary) -> bool:
	if not writable:
		folders = before_folders; entries = before_entries
		return _report("Repair the asset catalog before changing organization.")
	var directory := project_directory.path_join("assets")
	if DirAccess.make_dir_recursive_absolute(directory) != OK:
		folders = before_folders; entries = before_entries
		return _report("Could not create the asset catalog directory.")
	var path := directory.path_join(".library.json")
	var temporary := path + ".saving"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		folders = before_folders; entries = before_entries
		return _report("Could not write the asset catalog.")
	file.store_string(JSON.stringify({"version": 1, "folders": folders, "assets": entries}, "\t"))
	file.flush()
	var write_error := file.get_error()
	file.close()
	if write_error != OK or DirAccess.rename_absolute(temporary, path) != OK:
		folders = before_folders; entries = before_entries
		return _report("Could not save the asset catalog; organization was not changed.")
	changed.emit()
	return true

func create_folder(name: String, parent := "") -> String:
	name = name.strip_edges()
	if not _valid_name(name) or not _folder_exists(parent) or not _name_free(name, parent):
		_report("Choose a unique folder name without path separators.")
		return ""
	var before := folders.duplicate(true)
	var id := "%s_%s" % [Time.get_ticks_usec(), randi()]
	folders[id] = {"name": name, "parent": parent}
	return id if _save(before, entries.duplicate(true)) else ""

func rename_folder(id: String, name: String) -> bool:
	name = name.strip_edges()
	if not folders.has(id) or not _valid_name(name) or not _name_free(name, folders[id].parent, id):
		return _report("Choose a unique folder name without path separators.")
	var before := folders.duplicate(true)
	folders[id].name = name
	return _save(before, entries.duplicate(true))

func move_folder(id: String, destination: String) -> bool:
	if not folders.has(id) or not _folder_exists(destination) or not _name_free(folders[id].name, destination, id):
		return _report("A folder with that name already exists at the destination.")
	var parent := destination
	while not parent.is_empty():
		if parent == id:
			return _report("A folder cannot be moved inside itself or its descendants.")
		parent = folders[parent].parent
	var before := folders.duplicate(true)
	folders[id].parent = destination
	return _save(before, entries.duplicate(true))

func remove_folder(id: String) -> bool:
	if not folders.has(id):
		return false
	var destination: String = folders[id].parent
	for child in folders:
		if folders[child].parent == id and not _name_free(folders[child].name, destination, id):
			return _report("Rename the conflicting child folder before removing this folder.")
	var before := folders.duplicate(true)
	var old_entries := entries.duplicate(true)
	for child in folders:
		if folders[child].parent == id:
			folders[child].parent = destination
	for asset in entries:
		if entries[asset].folder == id:
			entries[asset].folder = destination
	folders.erase(id)
	return _save(before, old_entries)

func move_assets(ids: Array, destination: String) -> bool:
	if not _folder_exists(destination):
		return _report("Destination folder does not exist.")
	for id in ids:
		if not entries.has(id):
			return _report("Asset no longer exists in this catalog.")
	var before := entries.duplicate(true)
	for id in ids:
		entries[id].folder = destination
	return _save(folders.duplicate(true), before)

func rename_asset(id: String, name: String) -> bool:
	name = name.strip_edges()
	if not entries.has(id) or name.is_empty():
		return _report("Enter an asset display name.")
	var before := entries.duplicate(true)
	entries[id].name = name
	return _save(folders.duplicate(true), before)

func set_kind(id: String, kind: String) -> void:
	if not entries.has(id) or kind not in ["mesh", "material"] or entries[id].get("kind") == kind:
		return
	var before := entries.duplicate(true)
	entries[id].kind = kind
	if writable:
		_save(folders.duplicate(true), before)
	else:
		changed.emit()

func folder_path(id: String) -> String:
	var names := PackedStringArray(["Assets"])
	var parents: Array[String] = []
	while folders.has(id):
		parents.push_front(folders[id].name)
		id = folders[id].parent
	names.append_array(parents)
	return " / ".join(names)

func query(folder := "", search := "", kind := "all") -> Array:
	var result := []
	for id in entries:
		var entry: Dictionary = entries[id]
		if search.is_empty() and entry.folder != folder:
			continue
		if not search.is_empty() and not entry.name.to_lower().contains(search.to_lower()):
			continue
		if kind != "all" and entry.get("kind", "unknown") not in [kind, "unknown"]:
			continue
		result.append(id)
	result.sort_custom(func(a: String, b: String): return entries[a].name.naturalnocasecmp_to(entries[b].name) < 0)
	return result
