extends SceneTree

const Client = preload("res://scripts/renderer_client.gd")
var client: Node
var document: Object
var frames := 0
var deadline := 0
var project: String
var output: String

func _initialize() -> void: run.call_deferred()

func fail(message: String) -> void:
	push_error(message)
	if client != null: client.stop_worker()
	quit(1)

func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2: fail("Supply a read-only project path and output directory"); return
	project = args[0]; output = args[1]
	DirAccess.make_dir_recursive_absolute(output)
	document = ClassDB.instantiate("RemixDocument")
	var opened: Dictionary = document.execute_data(JSON.stringify({"op": "open", "path": project}))
	if not opened.get("ok", false): fail(str(opened)); return
	var result: Dictionary = document.execute_data('{"op":"scene"}')
	if not result.get("ok", false): fail(str(result)); return
	var scene: Dictionary = result.result
	print("Read-only viewport scene: %s; %d meshes, %d materials, %d lights" % [project, scene.meshes.size(), scene.materials.size(), scene.lights.size()])
	for light in scene.lights:
		if light.type == "DomeLight": print("Dome texture: ", light.texture)
	if scene.cameras.is_empty(): fail("Acceptance capture has no camera"); return
	var capture: Dictionary = scene.cameras[0]
	var m: Array = capture.transform
	var right := Vector3(m[0], m[1], m[2]).normalized()
	var up := Vector3(m[4], m[5], m[6]).normalized()
	var forward := -Vector3(m[8], m[9], m[10]).normalized()
	var camera := {"position": [m[12],m[13],m[14]], "right": [right.x,right.y,right.z], "up": [up.x,up.y,up.z], "forward": [forward.x,forward.y,forward.z], "fov": rad_to_deg(2*atan(float(capture.horizontal_aperture)/(2*float(capture.focal_length)*(16.0/9))))}
	client = Client.new(); root.add_child(client)
	client.status_changed.connect(func(message: String): print(message))
	client.response_received.connect(func(response: Dictionary):
		if not response.get("ok", false): fail(str(response)))
	client.frame_presented.connect(presented)
	var view := TextureRect.new(); view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	root.add_child(view); client.texture_ready.connect(func(texture: Texture2D): view.texture = texture)
	client.start_worker(ProjectSettings.globalize_path("res://../build/remix-renderer"), OS.get_environment("OPENREMIX_RUNTIME_PATH"), {"backend": "pathtrace", "upscaler": "none", "width": 320, "height": 180}, "openremix")
	client.send({"op": "settings", "settings": {"rtx.native.pathtrace.denoiser": "off", "rtx.native.pathtrace.sharc": "0", "rtx.native.pathtrace.sigma": "0", "rtx.native.pathtrace.taa": "0", "rtx.native.pathtrace.bounces": "1"}})
	client.send({"op": "scene", "scene": scene})
	client.send({"op": "camera", "camera": camera})
	deadline = Time.get_ticks_msec() + 900000

func presented(_context: Dictionary) -> void:
	frames += 1
	if frames == 3: capture.call_deferred()

func capture() -> void:
	await RenderingServer.frame_post_draw
	var image: Image = client.frame_texture.get_image()
	image.save_png(output.path_join("viewport.png"))
	var low := 1.0; var high := 0.0
	for y in image.get_height():
		for x in image.get_width():
			var l := image.get_pixel(x,y).get_luminance()
			low = minf(low,l); high = maxf(high,l)
	if high-low < 0.01: fail("Capture viewport is blank"); return
	print("Read-only OpenRemix capture viewport PASS: ", project, "; pixel range ", low, "..", high)
	client.stop_worker(); quit(0)

func _process(_delta: float) -> bool:
	if deadline and Time.get_ticks_msec() > deadline: fail("Capture viewport timed out")
	return false
