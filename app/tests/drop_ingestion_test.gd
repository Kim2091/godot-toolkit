extends SceneTree

var app: Control
var failures := 0
var directory := ""

func check(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		failures += 1

func write(path: String, contents: String) -> String:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(contents)
	file.close()
	return path

func model(name: String) -> String:
	return write(directory.path_join("source/" + name + ".obj"), "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n")

func drop(paths: Array) -> void:
	# Exercise the actual native-window signal connection, not just its handler.
	root.files_dropped.emit(PackedStringArray(paths))

func settle() -> void:
	for i in 3: await process_frame

func wait_imports() -> void:
	var deadline := Time.get_ticks_msec() + 30000
	while app.import_running or not app.import_queue.is_empty():
		if Time.get_ticks_msec() > deadline:
			check(false, "Dropped-file ingestion timed out")
			app._cancel_import()
			return
		await process_frame
	await settle()
	check(not app.import_button.disabled and app.import_button.text == "Ingest asset", "Import progress must return to idle")

func confirm() -> bool:
	if not is_instance_valid(app.import_dialog):
		check(false, "Drop did not open import options")
		return false
	app.import_dialog.confirmed.emit()
	return true

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	app = load("res://main.tscn").instantiate()
	root.add_child(app)
	app.render_toggle.button_pressed = false
	directory = app.root_directory.path_join(".work/drop-ingestion/%d" % Time.get_ticks_usec())
	var first := model("one/mesh-a")
	var second := model("two/mesh_a")
	drop([first])
	check(not is_instance_valid(app.import_dialog) and not app.import_running, "Dropping without a project must not ingest")
	check(app.welcome.notice.text.contains("project"), "Welcome screen must explain why a drop needs a project")
	var capture: String = app.root_directory.path_join("tests/fixtures/capture.usda")
	var project := directory.path_join("project/work.usda")
	app._command({"op": "create", "capture": capture, "path": project})
	var folder: String = app.assets.catalog.create_folder("Dropped assets")
	var elsewhere: String = app.assets.catalog.create_folder("Elsewhere")
	app.assets.current_folder = folder
	var image_path := directory.path_join("source/Color.PNG")
	var image := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.8, 0.2, 0.1))
	image.save_png(image_path)
	var invalid := write(directory.path_join("source/broken.gltf"), "not glTF")
	var unsupported := write(directory.path_join("source/readme.txt"), "Not an asset")
	drop([first, first, invalid, second, image_path, unsupported, directory.path_join("source"), directory.path_join("missing.obj")])
	if not is_instance_valid(app.import_dialog):
		check(false, "Mixed drop failed to show options")
		quit(1); return
	check(app.import_dialog.title == "Ingest 4 assets", "Drop must deduplicate files and skip unsupported/missing files and directories")
	for control in app.import_dialog.find_children("*", "OptionButton", true, false):
		if control.get_item_text(0) == "Opaque": control.select(1) # Cutout applies only to images.
	# Keep the destination from the drop even when library navigation changes.
	app.assets.current_folder = elsewhere
	confirm()
	check(app.import_running and app.import_queue.size() == 3 and app.import_button.disabled, "Batch must start exactly one native ingestion job")
	drop([model("busy")])
	check(app.import_queue.size() == 3 and not is_instance_valid(app.import_dialog), "A second drop must not disrupt the running batch")
	await wait_imports()
	for name in ["mesh_a", "mesh_a_2", "Color"]:
		var id: String = "assets/" + name + "/asset.usda"
		check(FileAccess.file_exists(project.get_base_dir().path_join(id)), "Dropped asset missing: " + name)
		check(app.assets.catalog.entries.get(id, {}).get("folder") == folder, "Dropped asset was registered in the wrong folder: " + name)
	check(not DirAccess.dir_exists_absolute(project.get_base_dir().path_join("assets/broken")), "Failed imports must not leave an asset behind")
	check(app.output.get_parsed_text().contains("Skipped unsupported"), "Skipped files should be explained")
	check(FileAccess.get_file_as_string(project.get_base_dir().path_join("assets/Color/asset.usda")).contains("inputs:alpha_test_type = 6"), "Dropped images must use the selected material settings")
	check(FileAccess.file_exists(project.get_base_dir().path_join("assets/Color/albedo.dds")), "Dropped images must run texture ingestion")
	check(app.assets.catalog.entries.size() == 3, "One failed import must not stop subsequent files")
	# A repeated drop must preserve existing data and pick a free name.
	var original := FileAccess.get_file_as_bytes(project.get_base_dir().path_join("assets/mesh_a/asset.usda"))
	drop([first]); confirm(); await wait_imports()
	check(FileAccess.file_exists(project.get_base_dir().path_join("assets/mesh_a_3/asset.usda")), "Repeated imports must receive a free name")
	check(FileAccess.get_file_as_bytes(project.get_base_dir().path_join("assets/mesh_a/asset.usda")) == original, "Dropping again must not overwrite an existing asset")
	drop([model("dismissed")])
	app.import_dialog.canceled.emit()
	await settle()
	check(not app.import_running and not FileAccess.file_exists(project.get_base_dir().path_join("assets/dismissed/asset.usda")), "Canceling options must not ingest")
	drop([model("cancel_first"), model("cancel_second")]); confirm()
	app._cancel_import()
	await wait_imports()
	check(not FileAccess.file_exists(project.get_base_dir().path_join("assets/cancel_second/asset.usda")), "Cancel import must discard the remaining batch")
	# Project changes close old options and cannot redirect queued imports.
	drop([model("stale_dialog")])
	var other := directory.path_join("other/work.usda")
	app._command({"op": "create", "capture": capture, "path": other})
	check(not is_instance_valid(app.import_dialog) and app.import_queue.is_empty(), "Changing project must dismiss pending import options")
	await settle()
	drop([model("switch_first"), model("switch_second")]); confirm()
	app._open_project(project)
	await wait_imports()
	for base in [project.get_base_dir(), other.get_base_dir()]:
		check(not FileAccess.file_exists(base.path_join("assets/switch_second/asset.usda")), "Queued imports must not leak across projects")
	check(not FileAccess.file_exists(project.get_base_dir().path_join("assets/switch_first/asset.usda")), "The running job must retain its original destination")
	# The ordinary file picker shares the same batch flow.
	app._choose_ingest()
	var picker: FileDialog
	for child in app.get_children():
		if child is FileDialog: picker = child
	check(picker != null and picker.file_mode == FileDialog.FILE_MODE_OPEN_FILES, "File picker must support the same multi-file import")
	if picker != null:
		picker.files_selected.emit(PackedStringArray([model("from_picker")]))
		await settle()
		confirm(); await wait_imports()
		check(FileAccess.file_exists(project.get_base_dir().path_join("assets/from_picker/asset.usda")), "File-picker ingestion regressed")
	print("Drop ingestion: %d failures; artifacts: %s" % [failures, directory])
	quit(0 if failures == 0 else 1)
