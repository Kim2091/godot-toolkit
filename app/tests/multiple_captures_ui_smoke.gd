extends SceneTree

const Sessions = preload("res://scripts/project_sessions.gd")
var failures := 0
var app: Control
var directory := ""

func check(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		failures += 1

func settle() -> void:
	for i in range(5): await process_frame

func same_camera(expected: Dictionary) -> bool:
	var actual: Dictionary = app.viewport.view_state()
	for key in expected:
		# JSON float parsing can differ by a final bit; pose and controls must
		# agree within numeric precision, including across an application restart.
		if expected[key] is float:
			if not is_equal_approx(actual[key], expected[key]): return false
		elif actual[key] != expected[key]:
			return false
	return true

func presented() -> void:
	var deadline := Time.get_ticks_msec() + 180000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if app.renderer.presented_context.get("revision", -1) == app.state.revision:
			return
	check(false, "Switched capture did not reach the Remix viewport")

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	directory = ProjectSettings.globalize_path("res://../.work/multiple_captures/" + str(Time.get_ticks_usec())).simplify_path()
	DirAccess.make_dir_recursive_absolute(directory)
	var original := FileAccess.get_file_as_string("res://../tests/fixtures/capture.usda")
	var a := directory.path_join("a.usda")
	var b := directory.path_join("b.usda")
	var file := FileAccess.open(a, FileAccess.WRITE)
	file.store_string(original); file.close()
	file = FileAccess.open(b, FileAccess.WRITE)
	file.store_string(original.replace('upAxis = "Y"', 'upAxis = "Z"').replace("(4, 0, 0)", "(20, 0, 0)")); file.close()
	var project := directory.path_join("project/project.usda")
	app = load("res://main.tscn").instantiate()
	app.sessions = Sessions.new(directory.path_join("recent.json"))
	root.add_child(app)
	check(app.add_capture_button.disabled and app.capture_picker.disabled, "Capture controls need an open project")
	app.renderer.response_received.connect(func(response: Dictionary):
		check(response.get("ok", false), "Renderer error: " + str(response.get("error", ""))))
	app._command({"op": "create", "capture": a, "path": project})
	await presented()
	var worker: int = app.renderer.process.pid
	check(app.capture_picker.item_count == 1 and not app.add_capture_button.disabled, "Initial capture must be listed")
	app.viewport.center = Vector3(1, 2, 3); app.viewport.yaw = 0.25
	app.viewport._camera_updated()
	var camera_a: Dictionary = app.viewport.view_state()
	var active_a: String = app.state.active_capture
	app._select("/RootNode/instances/inst_0123456789ABCDEF_0/mesh")
	await settle()
	var spin: SpinBox = app.inspector.controls["/RootNode/Looks/mat_0123456789ABCDEF/Shader|inputs:metallic_constant"].widget
	spin.get_line_edit().grab_focus(); spin.get_line_edit().text = "0.23"
	app.add_capture_button.pressed.emit()
	await settle()
	var dialog: FileDialog
	for child in app.get_children():
		if child is FileDialog: dialog = child
	check(dialog != null and dialog.title == "Add capture to project", "Add capture must offer a capture file picker")
	if dialog == null:
		quit(1); return
	dialog.file_selected.emit(b)
	await settle()
	check(app.capture_picker.item_count == 2 and app.capture_picker.selected == 1, "Added capture must become active")
	check(app.viewport.view_state().up_axis == "Z" and app.viewport.view_state() != camera_a, "An unseen capture needs its own framed camera")
	check(is_equal_approx(app.last_scene.materials[0].metallic, 0.23), "Capture switching must commit pending inspector edits and retain shared replacements")
	check(app.assets.project_directory == project.get_base_dir(), "Asset library must remain shared")
	await presented()
	check(app.renderer.process.pid == worker, "Capture switching must reuse the running renderer")
	app.viewport.center = Vector3(4, 5, 6); app.viewport.yaw = -0.35
	app.viewport._camera_updated()
	var camera_b: Dictionary = app.viewport.view_state()
	var active_b: String = app.state.active_capture
	app.capture_picker.select(0); app.capture_picker.item_selected.emit(0)
	await settle()
	check(app.state.active_capture == active_a and same_camera(camera_a), "Capture picker must restore the first camera")
	check(app.selection.is_empty(), "Switching captures must clear stale selection")
	app._command({"op": "undo"})
	check(app.state.active_capture == active_b and same_camera(camera_b) and app.capture_picker.selected == 1, "Undo must restore capture, picker, and camera")
	app._command({"op": "redo"})
	check(app.state.active_capture == active_a and same_camera(camera_a), "Redo must restore the selected capture's camera")
	var revision: int = app.state.revision
	await app._change_capture(directory.path_join("missing.usda"), true)
	check(app.state.revision == revision and app.capture_picker.selected == 0 and same_camera(camera_a), "Failed loads must preserve capture and camera")
	await app._change_capture(b, true)
	check(app.capture_picker.item_count == 2 and same_camera(camera_b), "Re-adding a capture must select it without duplication")
	await presented()
	app._command({"op": "save"})
	while app.preview_jobs > 0: await process_frame
	check(not app.state.dirty, "Multi-capture save must succeed")
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(directory.path_join("editor.png"))
	app.queue_free(); await settle()
	app = load("res://main.tscn").instantiate()
	app.sessions = Sessions.new(directory.path_join("recent.json"))
	root.add_child(app)
	app.render_toggle.button_pressed = false
	app._open_project(project)
	check(app.capture_picker.item_count == 2 and app.state.active_capture == active_b, "Restart must retain attached captures and the saved active capture")
	check(same_camera(camera_b), "Restart must restore the active capture's camera")
	await app._change_capture(active_a)
	check(same_camera(camera_a), "Other capture cameras must survive restart")
	check(app.renderer.process.is_empty(), "Switching with Remix disabled must not start a worker")
	check(FileAccess.get_file_as_string(a) == original, "Adding and switching must preserve capture files")
	print("Multiple captures UI: %d failures; artifacts: %s" % [failures, directory])
	quit(1 if failures else 0)
