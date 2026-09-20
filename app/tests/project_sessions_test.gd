extends SceneTree
const Sessions = preload("res://scripts/project_sessions.gd")
const LayoutView = preload("res://scripts/layout_view.gd")
var failures := 0

func check(condition: bool, message: String) -> void:
	if not condition:
		push_error(message); failures += 1

func write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE); file.store_string(text)

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--project="):
			var project := argument.trim_prefix("--project=")
			var app: Control = load("res://main.tscn").instantiate()
			app.sessions = Sessions.new(project.get_base_dir().path_join("startup_history.json"))
			root.add_child(app)
			if FileAccess.file_exists(project):
				check(app.state.get("open", false) and not app.welcome.visible, "Command-line project bypasses welcome")
				check(app.viewport.view_state() == app.sessions.read_view(project).camera, "Startup restores the saved camera")
			else:
				check(app.welcome.visible and not app.state.get("open", false), "Invalid command-line project retains welcome")
			quit(1 if failures else 0)
			return
	var directory := ProjectSettings.globalize_path("res://../.work/sessions/" + str(Time.get_ticks_usec())).simplify_path()
	var sessions := Sessions.new(directory.path_join("settings/recent.json"))
	var a := directory.path_join("a.usda"); var b := directory.path_join("b.usda")
	write(a, "unchanged USD"); write(b, "another unchanged USD")
	var view := LayoutView.new(); root.add_child(view)
	for up in ["Y", "Z"]:
		for mode in [LayoutView.CameraMode.DRONE, LayoutView.CameraMode.ORBIT]:
			view.set_scene({"meshes": [], "lights": [], "up_axis": up})
			view.center = Vector3(123, -25.5, 42); view.distance = 7.25; view.yaw = -0.45; view.pitch = 1.1
			view.camera_mode = mode; view.move_speed = 22.5
			var saved := view.view_state(); var camera := view.camera()
			check(sessions.save_view(a, saved, 1234), "Save camera sidecar")
			view.reset_view()
			check(view.restore_view_state(sessions.read_view(a).camera), "Restore complete camera")
			check(view.view_state() == saved and view.camera() == camera and not view.mouse_captured, "Restore position, orientation, pivot, mode, speed, and unlocked mouse")
	var good := view.view_state()
	for invalid in [{}, {"center": "bad"}, good.merged({"distance": -1}, true), good.merged({"yaw": INF}, true), good.merged({"mode": "other"}, true), good.merged({"up_axis": "Y"}, true)]:
		check(not view.restore_view_state(invalid) and view.view_state() == good, "Invalid camera must be rejected without partial changes")
	check(sessions.save_view(b, good.merged({"distance": 20}, true)), "Separate workfile state")
	check(sessions.read_view(a).camera.distance != sessions.read_view(b).camera.distance, "Workfiles in one directory must not share cameras")
	var image := Image.create(384, 216, false, Image.FORMAT_RGBA8); image.fill(Color.RED)
	check(sessions.save_thumbnail(a, image, 1234), "Save PNG preview")
	var original_image := FileAccess.get_file_as_bytes(a + ".studio.png")
	check(sessions.save_view(a, good.merged({"distance": 50}, true)), "Close updates camera independently")
	check(sessions.read_view(a).last_saved == 1234 and sessions.read_view(a).preview_saved_at == 1234 and FileAccess.get_file_as_bytes(a + ".studio.png") == original_image, "Close must retain last-save date and thumbnail")
	for i in range(23):
		sessions.opened(directory.path_join(str(i) + ".usda"))
	sessions.opened(a); sessions.opened(b); sessions.opened(directory.path_join("./a.usda"))
	check(sessions.recent.size() == 20 and sessions.recent[0].path == a and sessions.recent[1].path == b, "Recent history must be bounded, deduplicated, and ordered")
	var reopened := Sessions.new(sessions.history_path); reopened.load_history()
	check(reopened.recent == sessions.recent, "Recent history must persist")
	check(reopened.forget(a) and FileAccess.get_file_as_string(a) == "unchanged USD", "Forget must preserve project files")
	check(reopened.recent.any(func(entry: Dictionary): return not FileAccess.file_exists(entry.path)), "Missing entries must remain available for removal")
	write(a + ".studio.json", "broken JSON")
	check(sessions.read_view(a).is_empty(), "Malformed JSON falls back to a default view")
	write(a + ".studio.json", '{"version": 99, "camera": {}}')
	check(sessions.read_view(a).is_empty(), "Unknown versions cannot be restored")
	write(directory.path_join("not_a_directory"), "block writes")
	var before := sessions.recent.duplicate(true)
	sessions.history_path = directory.path_join("not_a_directory/recent.json")
	check(not sessions.opened(a) and sessions.recent == before, "Failed history writes roll back the list")
	check(not sessions.save_view(directory.path_join("not_a_directory/project.usda"), good), "View write errors must be recoverable")
	check(FileAccess.get_file_as_string(a) == "unchanged USD" and FileAccess.get_file_as_string(b) == "another unchanged USD", "Session metadata must not modify USD")
	var startup := directory.path_join("startup/project.usda")
	var document: Object = ClassDB.instantiate("RemixDocument")
	var response: Dictionary = JSON.parse_string(document.execute(JSON.stringify({"op": "create", "capture": ProjectSettings.globalize_path("res://../tests/fixtures/capture.usda"), "path": startup})))
	check(response.get("ok", false), "Create command-line fixture")
	check(sessions.save_view(startup, good.merged({"up_axis": "Y"}, true)), "Write startup camera")
	for project in [startup, directory.path_join("missing.usda")]:
		var output := []
		var status := OS.execute(OS.get_executable_path(), ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--script", "res://tests/project_sessions_test.gd", "--", "--project=" + project], output, true)
		check(status == 0, "Command-line startup: " + str(output))
	print("Project sessions: %d failures; artifacts: %s" % [failures, directory])
	quit(1 if failures else 0)
