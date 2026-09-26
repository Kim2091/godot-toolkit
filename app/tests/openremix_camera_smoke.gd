extends SceneTree

const Client = preload("res://scripts/renderer_client.gd")
const LayoutView = preload("res://scripts/layout_view.gd")
var client: Node
var camera: Control
var document: Object
var frames := 0
var deadline := 0
var previous_time := 0
var intervals: Array[int] = []
var output: String
var upscaler := "dlss"
var failures := 0

func _initialize() -> void: run.call_deferred()

func fail(message: String) -> void:
	push_error(message)
	if client != null: client.stop_worker()
	if is_instance_valid(camera): camera.free()
	quit(1)

func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2: fail("Supply a read-only project path and output directory"); return
	var project := args[0]
	output = args[1]
	if args.size() > 2: upscaler = args[2]
	DirAccess.make_dir_recursive_absolute(output)
	document = ClassDB.instantiate("RemixDocument")
	var opened: Dictionary = document.execute_data(JSON.stringify({"op": "open", "path": project}))
	if not opened.get("ok", false): fail(str(opened)); return
	var result: Dictionary = document.execute_data('{"op":"scene"}')
	if not result.get("ok", false): fail(str(result)); return
	camera = LayoutView.new()
	# Replay drone input explicitly; this controller does not need a wire viewport.
	camera.world_up = Vector3(0, 0, 1) if result.result.get("up_axis", "Y") == "Z" else Vector3.UP
	var saved = JSON.parse_string(FileAccess.get_file_as_string(project + ".studio.json"))
	if not saved is Dictionary or not camera.restore_view_state(saved.get("camera", {}), false):
		fail("Project requires a saved camera for the movement regression"); return
	client = Client.new(); root.add_child(client)
	client.status_changed.connect(func(message: String): print(message))
	client.response_received.connect(func(response: Dictionary):
		if not response.get("ok", false): fail(str(response)))
	client.frame_presented.connect(presented)
	camera.camera_changed.connect(func(value: Dictionary): client.send({"op": "camera", "camera": value}))
	var view := TextureRect.new()
	view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	root.add_child(view)
	client.texture_ready.connect(func(texture: Texture2D): view.texture = texture)
	client.start_worker(ProjectSettings.globalize_path("res://../build/remix-renderer"), OS.get_environment("OPENREMIX_RUNTIME_PATH"), {"backend": "pathtrace", "upscaler": upscaler, "ray_reconstruction": true, "quality": "balanced", "width": 320, "height": 180}, "openremix")
	client.send({"op": "scene", "scene": result.result})
	client.send({"op": "camera", "camera": camera.camera()})
	deadline = Time.get_ticks_msec() + 600000

func presented(_context: Dictionary) -> void:
	frames += 1
	var now := Time.get_ticks_msec()
	if frames > 8: intervals.append(now - previous_time)
	previous_time = now
	var effective: Dictionary = client.effective_settings
	if effective.get("upscaler") != upscaler or (upscaler == "dlss" and not effective.get("ray_reconstruction")):
		failures += 1
		print("Unexpected reconstruction at frame %d: %s" % [frames, effective])
	if frames % 16 == 0: print("Camera motion frame %d; %d ms; %s" % [frames, intervals.back(), effective])
	# Exercise the same drone handlers as mouse look and WASD. First translate,
	# then rotate, then combine both; all updates reach the shared GPU viewport.
	if frames >= 8 and frames < 392:
		if frames < 136 or frames >= 264:
			camera.mouse_captured = true
			camera._flight_keys = {KEY_D: true}
			camera._process(1.0 / 20)
			camera.mouse_captured = false
		if frames >= 136: camera._look(Vector2(10, 0.2), true)
	if frames in [8, 136, 264, 392, 408]: capture.call_deferred(frames)

func capture(frame: int) -> void:
	await RenderingServer.frame_post_draw
	client.frame_texture.get_image().save_png(output.path_join("frame-%03d.png" % frame))
	if frame != 408: return
	intervals.sort()
	print("Moving camera: %d frames; %d reconstruction fallbacks; frame time median %d ms, p95 %d ms, max %d ms" % [frames, failures, intervals[intervals.size()/2], intervals[int(intervals.size()*0.95)], intervals.back()])
	client.stop_worker()
	camera.free()
	quit(1 if failures else 0)

func _process(_delta: float) -> bool:
	if deadline and Time.get_ticks_msec() > deadline: fail("Camera motion regression timed out")
	return false
