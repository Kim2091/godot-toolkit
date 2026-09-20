extends SceneTree

const Gizmo = preload("res://scripts/transform_gizmo.gd")
var app: Control
var failures := 0
var directory := ""

func check(condition: bool, message: String) -> void:
	if not condition: push_error(message); failures += 1

func frame() -> Image:
	for i in range(4): await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func gold(color: Color) -> bool:
	return color.r > 0.45 and color.g > 0.35 and color.r > color.b * 1.3 and color.g > color.b * 1.2

func guide_at(image: Image, local: Vector3) -> bool:
	var view: Control = app.viewport
	var pixel: Vector2 = root.get_final_transform() * view.get_global_transform_with_canvas() * view._project(view.gizmo.world * local)
	for y in range(-3, 4):
		for x in range(-3, 4):
			var p := Vector2i(pixel) + Vector2i(x, y)
			if Rect2i(Vector2i.ZERO, image.get_size()).has_point(p) and gold(image.get_pixelv(p)): return true
	return false

func gold_pixels(image: Image) -> int:
	var rectangle: Rect2 = app.viewport.get_global_rect()
	var start := Vector2i(root.get_final_transform() * rectangle.position)
	var end := Vector2i(root.get_final_transform() * rectangle.end)
	var count := 0
	for y in range(start.y + 40, end.y):
		for x in range(start.x, end.x):
			if gold(image.get_pixel(x, y)): count += 1
	return count

func property(name: String, value: float) -> void:
	app._command({"op": "set_authoring_property", "path": app.selection, "property": name, "value": value})

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	root.size = Vector2i(1600, 1000)
	app = load("res://main.tscn").instantiate(); root.add_child(app)
	app.render_toggle.button_pressed = false
	directory = app.root_directory.path_join(".work/light_guides/" + str(Time.get_ticks_usec()))
	app._command({"op": "create", "capture": app.root_directory.path_join("tests/fixtures/capture.usda"), "path": directory.path_join("project.usda")})
	var pose := Transform3D(Basis(Vector3.RIGHT, -PI / 2), Vector3(0, 2, 0))
	app._command({"op": "add_light", "type": "SphereLight", "world_matrix": Gizmo.to_array(pose)})
	var view: Control = app.viewport
	view.center = Vector3(0, 1, 0); view.distance = 10; view.yaw = 0.65; view.pitch = 0.3; view._camera_updated()
	for type in ["SphereLight", "SpotLight", "RectLight", "DiskLight", "CylinderLight", "DistantLight", "DomeLight"]:
		app._command({"op": "set_light_type", "path": app.selection, "type": type})
		if type in ["SphereLight", "SpotLight", "DiskLight", "CylinderLight"]: property("inputs:radius", 1)
		if type == "RectLight": property("inputs:width", 4); property("inputs:height", 2)
		if type == "CylinderLight": property("inputs:length", 4)
		if type == "SpotLight": property("inputs:shaping:cone:softness", 0.05)
		var image := await frame()
		image.save_png(directory.path_join(type + ".png"))
		check(gold_pixels(image) > 150, "Each light type must have a visible shape/direction overlay: " + type)
		match type:
			"SphereLight", "DiskLight": check(guide_at(image, Vector3(1, 0, 0)), "Emitter outline must use the authored radius and world rotation: " + type)
			"RectLight":
				check(guide_at(image, Vector3(2, 1, 0)) and guide_at(image, Vector3(-2, -1, 0)), "Rectangle corners must match the physical width and height")
				property("inputs:width", 2)
				check(guide_at(await frame(), Vector3(1, 1, 0)), "Dimension edits must immediately resize the guide")
				app._command({"op": "undo"})
				check(guide_at(await frame(), Vector3(2, 1, 0)), "Undo must restore the previous emitter dimensions")
			"CylinderLight": check(guide_at(image, Vector3(2, 1, 0)) and guide_at(image, Vector3(-2, 0, 1)), "Cylinder ends must lie on local X with the authored length and radius")
			"SpotLight":
				var rim := Vector3(sin(deg_to_rad(35)), 0, -cos(deg_to_rad(35))) * 2.5
				check(guide_at(image, rim), "Spot cone must open by the authored half angle along local -Z")
				for angle in [0, 90, 179]:
					property("inputs:shaping:cone:angle", angle)
					check(gold_pixels(await frame()) > 150, "Wide and zero-angle cones must remain finite and visible")
	# The same overlay is composited over a letterboxed Remix image.
	app._command({"op": "set_light_type", "path": app.selection, "type": "SpotLight"})
	var background := Image.create(960, 540, false, Image.FORMAT_RGBA8); background.fill(Color("18232c"))
	view.show_render = true
	view.rendered_texture = ImageTexture.create_from_image(background)
	await frame()
	var selected: String = app.selection
	var revision: int = app.state.revision
	var before: Transform3D = view.gizmo.world
	view.set_mouse_capture(true); view.set_process(false)
	var captured := await frame()
	check(gold_pixels(captured) > 150, "Selection guides must remain visible with the drone cursor captured")
	check(view.gizmo.path == selected, "Capturing the mouse must retain the selected object")
	var motion := InputEventMouseMotion.new(); motion.screen_relative = Vector2(35, -8)
	view._input(motion)
	view._flight_keys[KEY_D] = true; view._process(0.1); view._flight_keys.clear()
	var flown := await frame()
	flown.save_png(directory.path_join("drone.png"))
	check(gold_pixels(flown) > 150, "Light guides must stay visible while looking and moving in drone mode")
	var click := InputEventMouseButton.new(); click.button_index = MOUSE_BUTTON_LEFT; click.pressed = true
	view._input(click); view._gui_input(click)
	check(not view.gizmo.active and app.state.revision == revision and view.gizmo.world.is_equal_approx(before), "Drone clicks must not drag the visible gizmo or edit the light")
	# Mesh selection also keeps its transform handles during flight.
	view.set_mouse_capture(false)
	app._select("/RootNode/instances/inst_0123456789ABCDEF_0/mesh")
	view.set_mouse_capture(true); view.set_process(false)
	check(not view.gizmo.path.is_empty() and not view.gizmo.light, "Drone flight must retain the mesh transform gizmo too")
	(await frame()).save_png(directory.path_join("drone_mesh.png"))
	view.set_mouse_capture(false)
	print("Light guides: %d failures; artifacts: %s" % [failures, directory])
	quit(1 if failures else 0)
