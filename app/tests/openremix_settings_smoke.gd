extends SceneTree

const Settings = preload("res://scripts/render_settings.gd")
const Sessions = preload("res://scripts/project_sessions.gd")
var app: Control
var frames := 0
var failed := false
var applied := false
var directory := ""

func _initialize() -> void: run.call_deferred()

func check(value: bool, message: String) -> bool:
	if not value: push_error(message); failed = true
	return value

func wait_frames(count := 8) -> bool:
	var target := frames + count
	var deadline := Time.get_ticks_msec() + 600000
	while frames < target and not failed and Time.get_ticks_msec() < deadline: await process_frame
	return check(not failed and frames >= target, "Timed out waiting for OpenRemix settings frames")

func change(options: Dictionary, output: Dictionary = {}) -> bool:
	var values: Dictionary = app.render_settings.values.duplicate(true)
	values.pathtrace.merge(options, true); values.merge(output, true)
	applied = false
	app._apply_render_settings(values)
	var deadline := Time.get_ticks_msec() + 600000
	while not applied and not failed and Time.get_ticks_msec() < deadline: await process_frame
	if not check(applied and not failed, "Worker did not acknowledge settings"): return false
	return await wait_frames()

func finish() -> void:
	app.renderer.stop_worker()
	print("OpenRemix settings GPU test: ", "FAILED" if failed else "passed", "; artifacts: ", directory)
	quit(1 if failed else 0)

func run() -> void:
	directory = ProjectSettings.globalize_path("res://../.work/openremix-settings/gpu-%d" % Time.get_ticks_usec())
	app = load("res://main.tscn").instantiate()
	app.render_settings = Settings.new(directory.path_join("settings.json"))
	app.sessions = Sessions.new(directory.path_join("recent.json"))
	app.render_settings.select_renderer("openremix")
	app.render_settings.save_settings({"upscaler": "none", "width": 320, "height": 180})
	root.add_child(app)
	app.renderer.status_changed.connect(func(message: String): print(message))
	app.renderer.frame_presented.connect(func(_context: Dictionary): frames += 1)
	app.renderer.response_received.connect(func(response: Dictionary):
		if not response.get("ok", false): check(false, str(response))
		if response.get("request_op") == "render_settings": applied = true)
	app._command({"op": "create", "capture": app.root_directory.path_join("tests/fixtures/capture.usda"), "path": directory.path_join("project.usda")})
	app._command({"op": "add_light", "type": "SphereLight", "translation": [0, 3, 0], "intensity": 1000})
	app.viewport.frame_selection(true)
	if not await wait_frames(): finish(); return
	var worker_pid: int = app.renderer.process.pid
	var revision: int = app.state.revision
	var camera: Dictionary = app.viewport.camera()
	var runtime: Dictionary = app.renderer.effective_settings.runtime
	check(runtime.nrd and runtime.sharc, "Defaults enable REBLUR SH and SHARC")
	check(runtime.sharc_caching, "Frozen capture meshes must receive SHARC updates")
	check(not runtime.local_firefly_filter, "Extra firefly filter defaults to opt-in")
	# Move every mesh temporarily, then cancel. Dynamic previews must not remain
	# cache receivers; cancelling restores their static classification.
	app.renderer.send({"op": "preview_transform", "revision": revision, "path": "/RootNode", "delta": [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 1, 0, 0, 1]})
	if not await wait_frames(): finish(); return
	check(not app.renderer.effective_settings.runtime.sharc_caching, "Moving previews pause caching when no static receivers remain")
	app.renderer.send({"op": "preview_transform", "revision": revision, "path": "/RootNode", "delta": [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]})
	if not await wait_frames(): finish(); return
	check(app.renderer.effective_settings.runtime.sharc_caching, "Cancelling a preview restores static cache receivers")
	if not await change({"localFireflyFilter": true, "sharcDownscale": 3, "samples": 2, "localDirectClamp": 2.5}): finish(); return
	runtime = app.renderer.effective_settings.runtime
	check(runtime.nrd and runtime.local_firefly_filter and runtime.sharc, "Live NRD firefly filter and cache are active")
	check(app.renderer.effective_settings.pathtrace.localDirectClamp == 2.5, "Float controls reach the worker")
	app._show_render_settings()
	await process_frame; await process_frame
	var dialog = app.render_settings_dialog
	for tab in [0, 1, 4]:
		dialog.tabs.current_tab = tab
		await process_frame; await process_frame
		check(dialog.position.y + dialog.size.y <= root.size.y and dialog.size.y < root.size.y, "Settings and Apply must fit the window")
		root.get_texture().get_image().save_png(directory.path_join("settings-%d.png" % tab))
	dialog.hide()
	if app.renderer.capabilities.ray_reconstruction:
		if not await change({}, {"upscaler": "dlss", "ray_reconstruction": true}): finish(); return
		runtime = app.renderer.effective_settings.runtime
		check(app.renderer.effective_settings.ray_reconstruction and not runtime.nrd and not runtime.local_firefly_filter and runtime.sharc,
			"RR replaces NRD/firefly filtering while retaining SHARC")
		check(app.render_settings.values.pathtrace.localFireflyFilter, "RR retains saved NRD filter preference")
	if not await change({}, {"upscaler": "fsr31", "ray_reconstruction": false}): finish(); return
	runtime = app.renderer.effective_settings.runtime
	check(app.renderer.effective_settings.upscaler == "fsr31" and runtime.nrd and runtime.local_firefly_filter, "NRD firefly filtering resumes with FSR")
	if not await change({"accumulate": true}): finish(); return
	runtime = app.renderer.effective_settings.runtime
	check(not runtime.sharc and not runtime.nrd and not runtime.local_firefly_filter and app.renderer.effective_settings.upscaler == "none",
		"Progressive reference rendering bypasses reconstruction, denoising and cache")
	if not await change({"accumulate": false}): finish(); return
	if not await change({"sharc": false, "denoiser": "off", "sigma": false, "taa": false}, {"upscaler": "none"}): finish(); return
	runtime = app.renderer.effective_settings.runtime
	check(not runtime.sharc and not runtime.nrd and not runtime.local_firefly_filter, "Disabled filter/cache controls reach the actual runtime")
	if not await change({"sharc": true, "denoiser": "reblur-sh", "sigma": true, "taa": true}): finish(); return
	check(app.renderer.effective_settings.runtime.nrd and app.renderer.effective_settings.runtime.sharc_caching, "Filters and cache resume after re-enabling")
	check(app.renderer.process.pid == worker_pid, "Advanced settings changes reuse the worker")
	check(app.state.revision == revision and app.viewport.camera() == camera, "Advanced settings preserve the document and camera")
	var restored := Settings.new(directory.path_join("settings.json")); restored.load_settings()
	check(restored.values == app.render_settings.values, "Saved advanced settings survive a new settings session")
	finish()
