extends SceneTree

const Settings = preload("res://scripts/render_settings.gd")
const Sessions = preload("res://scripts/project_sessions.gd")
var app: Control
var directory := ""
var frames := 0
var failed := false

func _initialize() -> void: run.call_deferred()

func check(ok: bool, message: String) -> void:
	if not ok: push_error(message); failed = true

func settle() -> void:
	var target := frames + 20
	var deadline := Time.get_ticks_msec() + 120000
	while frames < target and not failed and Time.get_ticks_msec() < deadline:
		await process_frame
	check(frames >= target, "Category scene must continue presenting frames")
	await RenderingServer.frame_post_draw

func snapshot(name: String) -> float:
	var image: Image = app.viewport.rendered_texture.get_image()
	image.save_png(directory.path_join(name + ".png"))
	var brightness := 0.0
	for y in range(0, image.get_height(), 4):
		for x in range(0, image.get_width(), 4):
			brightness += image.get_pixel(x, y).r
	return brightness

func run() -> void:
	directory = ProjectSettings.globalize_path("res://../.work/categories-gpu/%d" % Time.get_ticks_usec()).simplify_path()
	var captures := directory.path_join("game/rtx-remix/captures")
	DirAccess.make_dir_recursive_absolute(captures)
	var source := FileAccess.get_file_as_string(ProjectSettings.globalize_path("res://../tests/fixtures/capture.usda"))
	source = source.replace("token outputs:out", """asset inputs:diffuse_texture = @FEDCBA9876543210.dds@
				bool inputs:enable_emission = 1
				color3f inputs:emissive_color_constant = (1, 0, 0)
				float inputs:emissive_intensity = 10
				token outputs:out""")
	FileAccess.open(captures.path_join("capture.usda"), FileAccess.WRITE).store_string(source)
	var reference := FileAccess.get_file_as_string(ProjectSettings.globalize_path("res://../tests/fixtures/capture.usda"))
	FileAccess.open(directory.path_join("reference.usda"), FileAccess.WRITE).store_string(reference)
	var texture := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	texture.fill(Color.WHITE); texture.save_dds(captures.path_join("FEDCBA9876543210.dds"))
	var config := directory.path_join("game/rtx.conf")
	FileAccess.open(config, FileAccess.WRITE).store_string("rtx.hideInstanceTextures = 0xfedcba9876543210\nrtx.graphicsPreset = 0\n")
	app = load("res://main.tscn").instantiate()
	app.sessions = Sessions.new(directory.path_join("recent.json"))
	app.render_settings = Settings.new(directory.path_join("render.json"))
	app.render_settings.save_settings(Settings.DEFAULTS.merged({"upscaler": "taau", "quality": "native", "width": 640, "height": 360}, true))
	root.add_child(app)
	app.renderer.frame_presented.connect(func(_context: Dictionary): frames += 1)
	app.renderer.response_received.connect(func(response: Dictionary):
		check(response.get("ok", false), str(response))
		if response.get("request_op") == "start":
			app.renderer.send({"op": "settings", "settings": {"rtx.autoExposure.enabled": "False", "rtx.tonemap.tonemapOperator": "0"}}))
	app._command({"op": "create", "capture": captures.path_join("capture.usda"), "path": directory.path_join("project/work.usda")})
	check(app.last_scene.get("category_sources", []).has(config), "Godot must receive the game's category source")
	check(int(app.last_scene.meshes[0].surfaces[0].category_flags) == 256, "Hash classification must reach the viewport scene")
	check(app.output.get_parsed_text().contains(config), "Status output must identify the configuration source")
	app.viewport.center = Vector3(2, 0, 0); app.viewport.yaw = 0; app.viewport.pitch = 0.8; app.viewport.distance = 10
	app.viewport._sync_view()
	await settle()
	if not failed:
		var hidden := snapshot("hidden")
		# The first frame intentionally has all meshes hidden. Then add an
		# untagged reference to also cover a mix of categorized/ordinary geometry.
		app._command({"op": "add_mesh", "asset": directory.path_join("reference.usda"), "translation": [0, -2, 0]})
		app._command({"op": "save"})
		FileAccess.open(config, FileAccess.WRITE).store_string("rtx.hideInstanceTextures = -0xfedcba9876543210\n")
		app._open_project(directory.path_join("project/work.usda"))
		check(int(app.last_scene.meshes[0].surfaces[0].category_flags) == 0, "Reopening must apply hash exclusions")
		await settle()
		if not failed:
			var visible := snapshot("visible")
			print("Category GPU brightness: hidden=", hidden, " visible=", visible)
			check(visible > hidden + 100.0, "Runtime must consume category flags and actually hide tagged geometry")
	app.renderer.stop_worker()
	print("Capture category GPU test: ", "FAILED" if failed else "passed", "; artifacts: ", directory)
	await process_frame
	quit(1 if failed else 0)
