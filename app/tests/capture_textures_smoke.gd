extends SceneTree

# Exercise a Windows-authored texture path in a referenced capture material,
# including DDS decoding, both UV axes and tiling outside [0,1] in the Remix viewport.
var app: Control
var directory := ""
var frames := 0
var deadline := 0

func _initialize() -> void:
	run.call_deferred()

func write_file(path: String, contents: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(contents)

func fail(message: String) -> void:
	push_error(message)
	app.renderer.stop_worker()
	quit(1)

func run() -> void:
	app = load("res://main.tscn").instantiate()
	root.add_child(app)
	directory = app.root_directory.path_join(".work/integration/textures_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(directory.path_join("capture/materials"))
	DirAccess.make_dir_recursive_absolute(directory.path_join("capture/textures"))
	var image := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for y in range(64):
		for x in range(64):
			var color := Color.RED if x < 32 else Color.GREEN
			if y >= 32:
				color = Color.BLUE if x < 32 else Color.YELLOW
			image.set_pixel(x, y, color)
	image.generate_mipmaps()
	image.compress(Image.COMPRESS_S3TC)
	if image.save_dds(directory.path_join("capture/textures/checker.dds")) != OK:
		fail("Could not write DDS texture fixture"); return
	write_file(directory.path_join("capture/materials/material.usda"), """#usda 1.0
(defaultPrim = "Material")
def Material "Material" {
    token outputs:mdl:surface.connect = </Material/Shader.outputs:out>
    def Shader "Shader" {
        asset inputs:diffuse_texture = @..\\textures\\checker.dds@
        token outputs:out
    }
}
""")
	write_file(directory.path_join("capture/capture.usda"), """#usda 1.0
(
    defaultPrim = "RootNode"
    metersPerUnit = 1
    upAxis = "Y"
    customLayerData = { string lightspeed_layer_type = "capture" }
)
def Xform "RootNode" {
    def Scope "Looks" {
        def Material "mat_0123456789ABCDEF" (prepend references = @materials/material.usda@) {}
    }
    def Scope "meshes" {
        def Xform "mesh_0123456789ABCDEF" {
            token visibility = "invisible"
            def Mesh "mesh" (prepend apiSchemas = ["MaterialBindingAPI"]) {
                rel material:binding = </RootNode/Looks/mat_0123456789ABCDEF>
                point3f[] points = [(-1,-1,0), (1,-1,0), (1,1,0), (-1,1,0)]
                int[] faceVertexCounts = [4]
                int[] faceVertexIndices = [0,1,2,3]
                float3[] normals = [(0,0,1)] (interpolation = "constant")
                texCoord2f[] primvars:st = [(-1,-1), (2,-1), (2,2), (-1,2)] (interpolation = "vertex")
            }
        }
    }
    def Scope "instances" {
        def Xform "inst_0123456789ABCDEF_0" (prepend references = </RootNode/meshes/mesh_0123456789ABCDEF>) {
            token visibility = "inherited"
        }
    }
}
""")
	app._command({"op": "create", "capture": directory.path_join("capture/capture.usda"), "path": directory.path_join("project/project.usda")})
	if app.last_scene.materials.is_empty() or not FileAccess.file_exists(app.last_scene.materials[0].albedo_texture):
		fail("Capture texture did not resolve to a local file"); return
	app.viewport.yaw = 0; app.viewport.pitch = 0; app.viewport.distance = 4
	app.viewport.queue_redraw()
	app.renderer.response_received.connect(response)
	deadline = Time.get_ticks_msec() + 180000

func response(data: Dictionary) -> void:
	if not data.get("ok", false):
		fail(str(data)); return
	if data.get("request_op") == "start":
		# Albedo isolates texture sampling from lighting and exposure.
		app.renderer.send({"op": "settings", "settings": {"rtx.debugView.debugViewIdx": "23"}})
	if data.get("request_op") == "frame":
		frames += 1
		if frames == 12:
			capture.call_deferred()

func capture() -> void:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	image.save_png(directory.path_join("viewport.png"))
	# USD st=(0,0) is at the bottom left. Sample all four colors in each of nine
	# tiles, including negative UVs and UVs above one, to catch clamped samplers.
	var quadrants := [
		{"name": "top left", "uv": Vector2(0.25, 0.75), "color": Color.RED},
		{"name": "top right", "uv": Vector2(0.75, 0.75), "color": Color.GREEN},
		{"name": "bottom left", "uv": Vector2(0.25, 0.25), "color": Color.BLUE},
		{"name": "bottom right", "uv": Vector2(0.75, 0.25), "color": Color.YELLOW},
	]
	var samples := []
	for tile_v in range(-1, 2):
		for tile_u in range(-1, 2):
			for quadrant in quadrants:
				var uv: Vector2 = Vector2(tile_u, tile_v) + quadrant.uv
				var point := (uv + Vector2.ONE) * (2.0 / 3.0) - Vector2.ONE
				samples.append({"name": "tile (%d,%d) %s" % [tile_u, tile_v, quadrant.name],
					"position": Vector3(point.x, point.y, 0), "color": quadrant.color})
	var errors := PackedStringArray()
	for sample in samples:
		var pixel: Vector2 = root.get_final_transform() * app.viewport.get_global_transform_with_canvas() * app.viewport._project(sample.position)
		var actual := image.get_pixelv(Vector2i(pixel))
		var expected: Color = sample.color
		for channel in range(3):
			if (expected[channel] > 0.5 and actual[channel] < 0.4) or (expected[channel] < 0.5 and actual[channel] > 0.15):
				errors.append("%s expected=%s actual=%s" % [sample.name, expected, actual])
				break
	if not errors.is_empty():
		fail("Capture texture or UV sampling failed: " + "; ".join(errors)); return
	# Saving must read the presented Remix image, not a wireframe or stale-project frame.
	if app.renderer.presented_context.get("revision", -1) != app.state.revision:
		fail("Presented frame has no matching scene revision"); return
	app._command({"op": "save"})
	while app.preview_jobs > 0:
		await process_frame
	var thumbnail := Image.load_from_file(String(app.state.path) + ".studio.png")
	if thumbnail == null:
		fail("Missing Remix project thumbnail"); return
	var rectangle: Rect2 = app.viewport._view_rect()
	for sample in samples:
		var location: Vector2 = (app.viewport._project(sample.position) - rectangle.position) / rectangle.size * Vector2(384, 216)
		var actual := thumbnail.get_pixelv(Vector2i(location))
		if Vector3(actual.r - sample.color.r, actual.g - sample.color.g, actual.b - sample.color.b).length() > 0.25:
			fail("Remix save thumbnail disagrees with displayed texture: " + sample.name); return
	var saved_project: String = app.state.path
	var saved_camera: Dictionary = app.viewport.view_state()
	var saved_png := FileAccess.get_file_as_bytes(saved_project + ".studio.png")
	# Switch while the worker still presents the previous project's frame, then Save.
	app._command({"op": "create", "capture": app.root_directory.path_join("tests/fixtures/capture.usda"), "path": directory.path_join("second/project.usda")})
	app._command({"op": "save"})
	while app.preview_jobs > 0:
		await process_frame
	var second := Image.load_from_file(String(app.state.path) + ".studio.png")
	if second == null:
		fail("Missing fallback thumbnail after switching projects"); return
	var saturated := 0
	for y in range(second.get_height()):
		for x in range(second.get_width()):
			var pixel := second.get_pixel(x, y)
			if maxf(pixel.r, maxf(pixel.g, pixel.b)) - minf(pixel.r, minf(pixel.g, pixel.b)) > 0.4:
				saturated += 1
	if saturated > 30 or FileAccess.get_file_as_bytes(saved_project + ".studio.png") != saved_png:
		fail("Project switch reused a stale Remix frame or changed the old preview"); return
	app._open_project(saved_project)
	if app.viewport.view_state() != saved_camera:
		fail("Saved Remix camera did not restore"); return
	print("Capture textures, Remix thumbnails, and project-switch isolation passed: " + directory)
	app.renderer.stop_worker()
	quit()

func _process(_delta: float) -> bool:
	if deadline > 0 and Time.get_ticks_msec() > deadline:
		fail("Capture texture test timed out")
	return false
