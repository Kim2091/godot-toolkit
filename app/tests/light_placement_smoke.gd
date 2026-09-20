extends SceneTree

const Gizmo = preload("res://scripts/transform_gizmo.gd")
var app: Control
var failures := 0
var frames := 0
var directory := ""

func check(condition: bool, message: String) -> void:
	if not condition: push_error(message); failures += 1

func settle() -> void:
	for i in range(5): await process_frame

func presented() -> bool:
	var deadline := Time.get_ticks_msec() + 90000
	var after := frames + 16
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if app.renderer.presented_context.get("revision", -1) == app.state.revision and frames >= after: return true
	check(false, "Light scene did not render")
	return false

func sample_brightness(up: Vector3, units: float) -> float:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var result := 0.0
	for x in range(-3, 4):
		for y in range(-3, 4):
			var point := Vector3(x * 0.12, 0, y * 0.12) / units
			if up == Vector3.BACK: point = Vector3(point.x, point.z, 0)
			var pixel: Vector2 = root.get_final_transform() * app.viewport.get_global_transform_with_canvas() * app.viewport._project(point)
			var color := image.get_pixelv(Vector2i(pixel))
			result += maxf(color.r, maxf(color.g, color.b))
	return result / 49

func ctrl_t() -> void:
	var event := InputEventKey.new(); event.keycode = KEY_T; event.physical_keycode = KEY_T
	event.ctrl_pressed = true; event.pressed = true; root.push_input(event, true)
	event = event.duplicate(); event.pressed = false; root.push_input(event, true)

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	root.size = Vector2i(1600, 1000)
	app = load("res://main.tscn").instantiate(); root.add_child(app)
	directory = app.root_directory.path_join(".work/light_placement/" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(directory)
	app.renderer.frame_presented.connect(func(_context: Dictionary): frames += 1)
	app.renderer.response_received.connect(func(r: Dictionary): check(r.get("ok", false), str(r)))
	for units in [1.0, 0.01]:
		var up := Vector3.UP if units == 1.0 else Vector3.BACK
		var fixture := FileAccess.get_file_as_string(app.root_directory.path_join("tests/fixtures/capture.usda"))
		fixture = fixture.replace("metersPerUnit = 1", "metersPerUnit = " + str(units))
		if up == Vector3.BACK:
			fixture = fixture.replace('upAxis = "Y"', 'upAxis = "Z"')
			fixture = fixture.replace('def Xform "RootNode" {', 'def Xform "RootNode" {\n matrix4d xformOp:transform = ((100,0,0,0),(0,0,100,0),(0,-100,0,0),(0,0,0,1))\n uniform token[] xformOpOrder = ["xformOp:transform"]')
		var capture := directory.path_join("capture_" + str(units) + ".usda")
		var file := FileAccess.open(capture, FileAccess.WRITE); file.store_string(fixture); file.close()
		app._command({"op": "create", "capture": capture, "path": directory.path_join(str(units) + "/project.usda")})
		var view: Control = app.viewport
		# Camera looks through the floor: the pivot lies below it, as in large captures.
		view.center = -up * (10.0 / units); view.distance = 40.0 / units; view.pitch = PI / 3; view.yaw = 0
		# Bring the centre ray back over the first plane while retaining the wrong focus depth.
		var direction: Vector3 = -view._basis().z
		view.center = direction * (10.0 / units)
		view._camera_updated()
		if not await presented(): app.renderer.stop_worker(); quit(1); return
		var dark := await sample_brightness(up, units)
		for type in ["SphereLight", "SpotLight", "RectLight", "DiskLight", "CylinderLight", "DistantLight"]:
			app.library_selection = "previous_library_selection"
			app._spawn_light(type)
			var light: String = app.selection
			check(app.library_selection.is_empty() and app.inspector.controls.has(light + "|inputs:intensity"), "Spawning a light must switch the inspector from the asset library to the new light")
			var pose: Transform3D = view.gizmo.world
			check(pose.origin.dot(up) > 0, "A new light must spawn outside the floor even when the pivot is underground")
			check(pose.basis.z.is_equal_approx(up), "A new light must emit toward the floor")
			# Verify that the actual renderer receives Toolkit defaults on a running scene.
			if not await presented(): app.renderer.stop_worker(); quit(1); return
			var lit := await sample_brightness(up, units)
			print("%s units=%s dark=%.3f lit=%.3f" % [type, units, dark, lit])
			check(lit > dark + 0.15, "New light must visibly illuminate geometry: " + type + " at units " + str(units))
			if type == "SphereLight":
				# Real Ctrl+T input over the viewport, then one-step undo.
				var target: Vector3 = Vector3(0.5, 0, 0) / units
				view.grab_focus(); view.warp_mouse(view._project(target)); await settle()
				var revision: int = app.state.revision
				ctrl_t(); await settle()
				# OS pointer coordinates are whole pixels, so allow subpixel projection error.
				check(app.state.revision == revision + 1 and view.gizmo.world.origin.distance_to(target + up * (5.01 / units)) < 0.1 / units,
					"Ctrl+T must place the selected emitter at cursor depth in one edit: " + str(view.gizmo.world.origin) + "; revisions " + str([revision, app.state.revision]))
				check(view.gizmo.world.basis.is_equal_approx(pose.basis), "Ctrl+T must preserve orientation and scale")
				app._command({"op": "undo"})
				check(view.gizmo.world.is_equal_approx(pose), "Cursor placement must undo in one step")
				view.set_mouse_capture(true); view.set_process(false)
				ctrl_t(); await settle()
				check(view.gizmo.world.origin.distance_to(up * (5.01 / units)) < 0.02 / units, "Captured mouse must place using the drone crosshair")
				view.set_mouse_capture(false)
				var spin: SpinBox = app.inspector.controls[light + "|inputs:intensity"].widget
				spin.get_line_edit().grab_focus(); revision = app.state.revision
				ctrl_t(); await settle()
				check(app.state.revision == revision, "Typing in the inspector must not trigger cursor placement")
				spin.get_line_edit().release_focus()
				await RenderingServer.frame_post_draw
				root.get_texture().get_image().save_png(directory.path_join("light_" + str(units) + ".png"))
			app._command({"op": "delete", "path": light})
			app._select("")
		app.renderer.set_process(true)
	app.renderer.stop_worker(); await settle()
	print("Light placement: %d failures; artifacts: %s" % [failures, directory])
	quit(1 if failures else 0)
