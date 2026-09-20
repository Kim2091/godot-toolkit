extends SceneTree
const Catalog = preload("res://scripts/asset_catalog.gd")
var failures := 0

func check(condition: bool, message: String) -> void:
	if not condition:
		push_error(message); failures += 1

func write(path: String, contents: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE); file.store_string(contents)

func _initialize() -> void:
	var root := ProjectSettings.globalize_path("res://../.work/library_tests/" + str(Time.get_ticks_usec()))
	var id := "assets/original/asset.usda"
	write(root.path_join(id), "unchanged asset")
	write(root.path_join("mod.usda"), "unchanged reference")
	var catalog := Catalog.new(); catalog.open_project(root)
	check(catalog.entries.has(id) and catalog.entries[id].folder == "", "Existing assets must be discovered at the root")
	var parent := catalog.create_folder("Nature")
	var child := catalog.create_folder("Trees", parent)
	check(not parent.is_empty() and not child.is_empty(), "Nested folder creation")
	check(catalog.create_folder("nature").is_empty(), "Sibling folder names must be unique")
	check(not catalog.move_folder(parent, child), "Moving a folder into a descendant must be rejected")
	check(catalog.move_assets([id], child), "Move assets into nested folders")
	check(catalog.rename_asset(id, "Oak") and catalog.rename_folder(child, "Forest"), "Display names can change")
	check(catalog.query(child, "oak").size() == 1, "Search uses display names")
	check(catalog.query("", "oak").size() == 1, "Search can find assets across folders")
	var reopened := Catalog.new(); reopened.open_project(root)
	check(reopened.entries[id].folder == child and reopened.entries[id].name == "Oak", "Organization must persist")
	check(reopened.remove_folder(child) and reopened.entries[id].folder == parent, "Removing a folder must move contents to its parent")
	check(FileAccess.get_file_as_string(root.path_join(id)) == "unchanged asset" and FileAccess.get_file_as_string(root.path_join("mod.usda")) == "unchanged reference", "Organization must not move files or rewrite references")
	DirAccess.remove_absolute(root.path_join(id))
	reopened.discover()
	check(reopened.entries.has(id) and not reopened.available(id), "Missing assets remain visible as unavailable")
	write(root.path_join("assets/.library.json"), "invalid catalog")
	var corrupt := Catalog.new(); corrupt.open_project(root)
	check(not corrupt.writable and corrupt.create_folder("Test").is_empty(), "Corrupt catalogs must not be overwritten")
	check(FileAccess.get_file_as_string(root.path_join("assets/.library.json")) == "invalid catalog", "Original corrupt catalog preserved")
	write(root.path_join("assets/.library.json"), JSON.stringify({"version": 1, "folders": {"a": {"name": "A", "parent": "b"}, "b": "invalid"}, "assets": {}}))
	corrupt.open_project(root)
	check(not corrupt.writable, "Malformed parent records must be rejected without traversing them")
	print("Asset catalog: %d failures" % failures)
	quit(1 if failures else 0)
