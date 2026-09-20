extends SceneTree
const Settings = preload("res://scripts/render_settings.gd")
const Sessions = preload("res://scripts/project_sessions.gd")
var app: Control
var frames := 0
var failed := false
var directory := ""

func _initialize() -> void:
	run.call_deferred()

func check(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message); failed = true
	return condition

func wait_frames(count := 4) -> bool:
	var target := frames + count
	var deadline := Time.get_ticks_msec() + 90000
	while frames < target and not failed and Time.get_ticks_msec() < deadline:
		await process_frame
	return check(not failed and frames >= target, "Timed out waiting for rendered frames")

func new_app() -> void:
	app = load("res://main.tscn").instantiate()
	app.render_settings = Settings.new(directory.path_join("preferences.json"))
	app.sessions = Sessions.new(directory.path_join("recent.json"))
	root.add_child(app)
	app.renderer.frame_presented.connect(func(_context: Dictionary): frames += 1)
	app.renderer.response_received.connect(func(response: Dictionary):
		if not response.get("ok", false): check(false, str(response)))
	app.renderer.status_changed.connect(func(message: String): print(message))

func finish() -> void:
	app.renderer.stop_worker()
	await process_frame; await process_frame
	quit(1 if failed else 0)

func run() -> void:
	directory = ProjectSettings.globalize_path("res://../.work/render-settings-ui/%d" % Time.get_ticks_usec()).simplify_path()
	var preferences := Settings.new(directory.path_join("preferences.json"))
	preferences.save_settings(Settings.DEFAULTS.merged({"width": 640, "height": 360}, true))
	new_app()
	check(app.renderer.process.is_empty(), "Preferences must not start a worker on welcome")
	app._command({"op": "create", "capture": app.root_directory.path_join("tests/fixtures/capture.usda"), "path": directory.path_join("project.usda")})
	app._command({"op": "add_light", "type": "SphereLight", "translation": [0, 3, 0], "intensity": 50})
	app.viewport.frame_selection(true)
	if not await wait_frames(8): await finish(); return
	check(app.viewport.rendered_texture.get_size() == Vector2(640, 360), "Startup must use saved output dimensions")
	print("Runtime capabilities: ", app.renderer.capabilities)
	app._show_render_settings()
	await process_frame; await process_frame
	var dialog = app.render_settings_dialog
	check(dialog.reconstruction.visible == app.renderer.capabilities.ray_reconstruction, "RR visibility must follow actual runtime capabilities")
	root.get_texture().get_image().save_png(directory.path_join("settings.png"))
	dialog.hide()
	var worker_pid: int = app.renderer.process.pid
	var revision: int = app.state.revision
	var camera: Dictionary = app.viewport.camera()
	var operations := [
		{"upscaler": "taau", "quality": "performance"},
		{"upscaler": "taau", "quality": "native"},
		{"upscaler": "none", "quality": "native"}]
	if app.renderer.capabilities.dlss:
		operations.append({"upscaler": "dlss", "quality": "quality", "ray_reconstruction": false})
		if app.renderer.capabilities.ray_reconstruction:
			operations.append({"upscaler": "dlss", "quality": "balanced", "ray_reconstruction": true})
	for operation in operations:
		app._apply_render_settings(app.render_settings.values.merged(operation, true))
		if not await wait_frames(6): await finish(); return
		check(app.renderer.process.pid == worker_pid, "Upscaler/quality changes must reuse the worker")
		for key in operation:
			check(app.renderer.effective_settings[key] == operation[key], "Worker did not apply " + str(operation))
		var image: Image = app.viewport.rendered_texture.get_image()
		image.save_png(directory.path_join("%s-%s-%s.png" % [operation.upscaler, operation.quality, operation.get("ray_reconstruction", false)]))
		var lit := 0
		for y in range(0, image.get_height(), 4):
			for x in range(0, image.get_width(), 4):
				var pixel := image.get_pixel(x, y)
				if maxf(pixel.r, maxf(pixel.g, pixel.b)) > 0.15: lit += 1
		check(lit > 30, "Upscaler change left no rendered geometry: " + str(operation))
	app._show_render_settings()
	dialog.width.set_value_no_signal(800); dialog.height.set_value_no_signal(600)
	await process_frame; await process_frame
	dialog.confirmed.emit()
	if not await wait_frames(8): await finish(); return
	check(app.renderer.process.pid != worker_pid and app.viewport.rendered_texture.get_size() == Vector2(800, 600), "Resolution Apply must reconnect and import the new GPU image")
	check(app.state.revision == revision and app.viewport.camera() == camera, "Renderer restart must retain edits and camera")
	var area: Rect2 = app.viewport._view_rect()
	check(is_equal_approx(area.size.x / area.size.y, 4.0 / 3.0), "Viewport must use the new output aspect ratio")
	var saved: Dictionary = app.render_settings.values.duplicate(true)
	app.render_toggle.button_pressed = false
	app._apply_render_settings(saved.merged({"width": 640, "height": 480}, true))
	check(app.renderer.process.is_empty() and not app.renderer.is_processing(), "Changing resolution while paused must not start Remix")
	app.render_toggle.button_pressed = true
	if not await wait_frames(5): await finish(); return
	check(app.viewport.rendered_texture.get_size() == Vector2(640, 480), "Re-enabling Remix uses pending settings")
	saved = app.render_settings.values.duplicate(true)
	app._command({"op": "save"})
	app.renderer.stop_worker()
	app.queue_free()
	await process_frame; await process_frame
	new_app()
	check(app.render_settings.values == saved, "Render preferences survive application recreation")
	app._open_project(directory.path_join("project.usda"))
	if not await wait_frames(5): await finish(); return
	check(app.viewport.rendered_texture.get_size() == Vector2(640, 480), "Reopened project restores saved rendering preferences")
	print("Render settings GPU test: ", "FAILED" if failed else "passed", "; artifacts: ", directory)
	await finish()
