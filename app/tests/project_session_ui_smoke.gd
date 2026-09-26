extends SceneTree
const Sessions = preload("res://scripts/project_sessions.gd")
const ThemeTools = preload("res://scripts/studio_theme.gd")
class FailedSave extends RefCounted:
	func execute_data(_request: String) -> Dictionary:
		return {"ok": false, "error": "Simulated USD save failure"}

var failures := 0
var app: Control
var directory := ""

func check(condition: bool, message: String) -> void:
	if not condition:
		push_error(message); failures += 1

func settle() -> void:
	for i in range(5):
		await process_frame

func previews() -> void:
	var deadline := Time.get_ticks_msec() + 10000
	while app.preview_jobs > 0 and Time.get_ticks_msec() < deadline:
		await process_frame
	check(app.preview_jobs == 0, "Project thumbnail timed out")

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	directory = ProjectSettings.globalize_path("res://../.work/session_ui/" + str(Time.get_ticks_usec())).simplify_path()
	root.size = Vector2i(1440, 900)
	app = load("res://main.tscn").instantiate()
	app.sessions = Sessions.new(directory.path_join("settings/recent.json"))
	root.add_child(app)
	app.render_toggle.button_pressed = false
	app.dpi_timer.stop()
	await settle()
	check(app.welcome.visible and not app.editor_page.visible, "Startup must offer the welcome screen")
	var capture: String = app.root_directory.path_join("tests/fixtures/capture.usda")
	var project := directory.path_join("a/project.usda")
	var other := directory.path_join("b/project.usda")
	app._command({"op": "create", "capture": capture, "path": project})
	check(app.renderer.process.is_empty(), "Loading with Remix disabled must not start a worker")
	await settle()
	check(not app.welcome.visible and app.editor_page.visible, "Creating a project must enter the editor")
	app.viewport.camera_mode = 1; app.viewport.yaw = 0.25; app.viewport.pitch = 0.55
	app.viewport.move_speed = 5.5; app.viewport._camera_updated()
	var saved: Dictionary = app.viewport.view_state()
	app._command({"op": "save"})
	await previews()
	check(not app.state.dirty, "Saving camera metadata must not dirty USD")
	check(app.sessions.read_view(project).camera == saved, "Save must persist the camera")
	var thumbnail := project + ".studio.png"
	check(FileAccess.file_exists(thumbnail), "Layout must produce a saved-view thumbnail without starting Remix")
	if FileAccess.file_exists(thumbnail):
		var image := Image.load_from_file(thumbnail)
		check(image.get_size() == Vector2i(384, 216), "Thumbnail dimensions")
		var background := image.get_pixel(0, 0); var visible := 0
		for y in range(216):
			for x in range(384):
				var color := image.get_pixel(x, y)
				if Vector3(color.r - background.r, color.g - background.g, color.b - background.b).length() > 0.1: visible += 1
		check(visible > 50, "Layout thumbnail must contain rendered geometry")
	var png := FileAccess.get_file_as_bytes(thumbnail)
	var metadata_before := FileAccess.get_file_as_bytes(project + ".studio.json")
	var actual_document: Object = app.document
	app.document = FailedSave.new()
	app._command({"op": "save"})
	app.document = actual_document
	check(FileAccess.get_file_as_bytes(thumbnail) == png and FileAccess.get_file_as_bytes(project + ".studio.json") == metadata_before, "Failed USD Save must preserve thumbnail and camera metadata")
	app.viewport.center += Vector3(1, 2, 3)
	var close_view: Dictionary = app.viewport.view_state()
	app._command({"op": "create", "capture": capture, "path": other})
	await settle()
	check(app.sessions.read_view(project).camera == close_view, "Project switch persists the previous camera")
	check(app.viewport.camera_mode == 0, "An unseen project starts in default Drone mode")
	app._open_project(project)
	await settle()
	check(app.viewport.view_state() == close_view and app.camera_mode.selected == 1, "Reopening restores camera and mode selector")
	check(FileAccess.get_file_as_bytes(thumbnail) == png, "Opening and switching must not overwrite the last-save thumbnail")
	var previous_state: Dictionary = app.state.duplicate(true)
	app._show_welcome()
	app._open_project(directory.path_join("missing.usda"))
	check(app.welcome.visible and app.state == previous_state, "Failed open keeps the picker and current document")
	app._show_editor()
	app._command({"op": "add_light", "path": "/RootNode/instances/inst_0123456789ABCDEF_0", "type": "SphereLight"})
	var mod_before := FileAccess.get_file_as_string(project.get_base_dir().path_join("mod.usda"))
	var view_before := FileAccess.get_file_as_bytes(project + ".studio.json")
	app.viewport.center += Vector3(2, 0, 0)
	app.notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	await settle()
	var prompt: ConfirmationDialog
	for child in app.get_children():
		if child is ConfirmationDialog: prompt = child
	check(prompt != null, "Dirty close must ask before discarding scene changes")
	if prompt != null: prompt.canceled.emit()
	await settle()
	check(not app.close_pending and FileAccess.get_file_as_bytes(project + ".studio.json") == view_before, "Cancel close must not persist a new view")
	await app._prepare_close()
	check(app.sessions.read_view(project).camera == app.viewport.view_state() and app.state.dirty, "Confirmed exit preparation remembers the view while leaving unsaved edits unsaved")
	check(FileAccess.get_file_as_string(project.get_base_dir().path_join("mod.usda")) == mod_before and FileAccess.get_file_as_bytes(thumbnail) == png, "Close must preserve last-save USD and thumbnail")
	app._command({"op": "package", "path": directory.path_join("package")})
	check(not FileAccess.file_exists(directory.path_join("package/project.usda.studio.json")), "Packaging excludes view metadata")
	# Same logical dimensions and typography at each system scale; larger windows give more workspace.
	for factor in [1.0, 1.5, 2.0]:
		ThemeTools.apply_scale(root, factor)
		root.size = Vector2i(Vector2(1280, 800) * factor)
		await settle()
		check(app.get_theme_default_font_size() == 13, "DPI uses one root scale, without doubling theme fonts")
		var picker_size: Vector2 = app.camera_mode.size
		var before_width: float = app.viewport.size.x
		check(app.editor_page.get_global_rect().size.x <= 1281, "Compact editor fits 1280 logical pixels")
		check(app.viewport.wire_viewport.size == Vector2i(app.viewport._view_rect().size * factor), "Wireframe resolution must follow physical pixels")
		root.size = Vector2i(Vector2(1600, 1000) * factor)
		await settle()
		check(app.camera_mode.size.is_equal_approx(picker_size), "Window resizing must leave control sizes unchanged")
		check(app.viewport.size.x > before_width, "Larger windows must grow the workspace")
		var sample := Vector3.ZERO
		var local: Vector2 = app.viewport._project(sample)
		check(not app.viewport._pick(local).is_empty(), "Picking remains aligned at each DPI scale")
		app._dialog(FileDialog.FILE_MODE_OPEN_FILE, "DPI dialog test", [], func(_path: String): pass)
		await settle()
		for child in app.get_children():
			if child is FileDialog:
				check(child.is_embedded() and child.visible, "File dialogs inherit the root DPI scale")
				child.hide(); child.queue_free()
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(directory.path_join("editor_%s.png" % factor))
	ThemeTools.apply_scale(root, 1)
	root.size = Vector2i(1440, 900)
	app._show_welcome(); await settle()
	check(app.welcome.cards.get_child_count() == 2 and app.welcome.back.visible, "Welcome lists recent projects and offers return")
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(directory.path_join("welcome.png"))
	print("Project session UI: %d failures; artifacts: %s" % [failures, directory])
	quit(1 if failures else 0)
