extends SceneTree

const Gizmo = preload("res://scripts/transform_gizmo.gd")
var app: Control
var failures := 0
var frames := 0
var responses: Array[Dictionary] = []
var directory := ""

func check(condition: bool, message: String) -> void:
	if not condition: push_error(message); failures += 1

func settle() -> void:
	for i in range(5): await process_frame

func pointer(position: Vector2) -> void:
	app.viewport.warp_mouse(position)
	await settle()
	# Warping updates the OS cursor but may suppress motion events on X11.
	var event := InputEventMouseMotion.new()
	event.position = root.get_mouse_position()
	root.push_input(event, true)
	await settle()

func tap(code: Key, shift := false, ctrl := false) -> void:
	var event := InputEventKey.new(); event.keycode = code; event.physical_keycode = code
	event.shift_pressed = shift; event.ctrl_pressed = ctrl; event.pressed = true
	root.push_input(event, true)
	event = event.duplicate(); event.pressed = false; root.push_input(event, true)

func number(text: String) -> void:
	for character in text:
		tap(KEY_MINUS if character == "-" else KEY_PERIOD if character == "." else KEY_0 + int(character))

func click(which := MOUSE_BUTTON_LEFT) -> void:
	var event := InputEventMouseButton.new(); event.button_index = which
	event.position = root.get_mouse_position(); event.pressed = true
	root.push_input(event, true)
	event = event.duplicate(); event.pressed = false; root.push_input(event, true)

func presented() -> bool:
	var deadline := Time.get_ticks_msec() + 90000
	var after := frames + 8
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if frames >= after and app.renderer.presented_context.get("revision", -1) == app.state.revision: return true
	check(false, "Keyboard preview did not render")
	return false

func _initialize() -> void: run.call_deferred()

func run() -> void:
	root.size = Vector2i(1600, 1000)
	app = load("res://main.tscn").instantiate(); root.add_child(app)
	app.render_toggle.button_pressed = false
	directory = app.root_directory.path_join(".work/keyboard_transforms/" + str(Time.get_ticks_usec()))
	app._command({"op": "create", "capture": app.root_directory.path_join("tests/fixtures/capture.usda"), "path": directory.path_join("project.usda")})
	app._command({"op": "add_light", "type": "SpotLight", "translation": [0, 3, 0]})
	var light: String = app.selection
	app._command({"op": "set_authoring_property", "path": light, "property": "inputs:radius", "value": 0.5})
	app._command({"op": "add_mesh", "asset": app.root_directory.path_join("tests/fixtures/replacement.usda"), "translation": [2, 1, 0]})
	var mesh: String = app.selection
	var view: Control = app.viewport
	view.center = Vector3(1, 1, 0); view.distance = 10; view.yaw = 0.5; view.pitch = 0.65; view._camera_updated()
	await settle()
	for path in [light, mesh]:
		app._select(path); view.grab_focus()
		for operation in [[KEY_G, KEY_X], [KEY_R, KEY_Z], [KEY_S, KEY_Y]]:
			var original: Transform3D = view.gizmo.world
			var revision: int = app.state.revision
			var pivot: Vector2 = view._project(original.origin)
			await pointer(pivot + Vector2(90, 0))
			app.tree.grab_focus()
			tap(operation[0]); tap(operation[1])
			if view.gizmo.modal == null:
				push_error("Could not start %s for %s: selection=%s cursor=%s expected=%s rect=%s focus=%s captured=%s" % [operation, path, app.selection, view.get_local_mouse_position(), pivot + Vector2(90, 0), view._view_rect(), root.gui_get_focus_owner(), view.mouse_captured])
				quit(1); return
			check(view.gizmo.modal != null and not view.mouse_captured, "Transform shortcut must start, and Z must lock rotation rather than capture the mouse")
			await pointer(pivot + (Vector2(0, -90) if operation[0] == KEY_R else Vector2(170, 0)))
			var preview: Transform3D = view.gizmo.world
			check(app.state.revision == revision and not preview.is_equal_approx(original), "Mouse movement must preview without authoring USD")
			click(); await settle()
			check(app.state.revision == revision + 1 and app.selection == path and view.gizmo.world.is_equal_approx(preview), "Left click must commit exactly one transform without changing selection")
			tap(KEY_Z, false, true); await settle()
			check(view.gizmo.world.is_equal_approx(original), "Ctrl+Z must undo the whole modal operation")
			await pointer(pivot + Vector2(90, 0)); tap(operation[0]); await pointer(pivot + Vector2(170, -40))
			revision = app.state.revision
			click(MOUSE_BUTTON_RIGHT); await settle()
			check(app.state.revision == revision and view.gizmo.world.is_equal_approx(original) and not view.gizmo.active, "Right click must cancel without an undo entry")
		var numeric_original: Transform3D = view.gizmo.world
		var numeric_revision: int = app.state.revision
		await pointer(view._project(numeric_original.origin) + Vector2(90, 0))
		tap(KEY_R); tap(KEY_Y); number("-22.5")
		var expected := Basis(Vector3.UP, deg_to_rad(-22.5)) * numeric_original.basis
		check(view.gizmo.world.basis.is_equal_approx(expected) and app.state.revision == numeric_revision, "Typing an angle must preview the exact rotation without authoring USD")
		await pointer(view._project(numeric_original.origin) + Vector2(0, -90))
		if path == light: tap(KEY_ENTER)
		else: click()
		await settle()
		check(app.state.revision == numeric_revision + 1 and view.gizmo.world.basis.is_equal_approx(expected), "Enter and left click must confirm the exact numeric angle as one edit")
		tap(KEY_Z, false, true); await settle()
		check(view.gizmo.world.is_equal_approx(numeric_original), "Undo must restore the pose before numeric entry for lights and meshes")
	app._select(light); view.grab_focus()
	var original: Transform3D = view.gizmo.world
	var destination := Vector3(-0.6, 0, 0.3)
	await pointer(view._project(Vector3(0.7, 0, -0.4)))
	var revision: int = app.state.revision
	tap(KEY_T, true); await pointer(view._project(destination))
	check(view.gizmo.modal != null and (-view.gizmo.world.basis.z.normalized()).dot((destination - original.origin).normalized()) > 0.999, "Shift+T must aim the selected light at the surface under the cursor")
	check(app.state.revision == revision and view.gizmo.world.origin == original.origin, "Aiming must preview rotation without moving or authoring the light")
	click(); await settle()
	check(app.state.revision == revision + 1, "Confirming aim must author one undo step")
	var aimed: Transform3D = view.gizmo.world
	# Text input must keep normal typing shortcuts, and S must keep drone movement.
	var spin: SpinBox = app.inspector.controls[light + "|inputs:intensity"].widget
	var text := spin.get_line_edit(); text.grab_focus(); var old_text := text.text
	tap(KEY_G); tap(KEY_R); tap(KEY_S); tap(KEY_T, true)
	check(not view.gizmo.active, "Typing in properties must not start transforms")
	text.text = old_text; text.release_focus(); view.grab_focus()
	view.set_mouse_capture(true); view.set_process(false)
	tap(KEY_S); tap(KEY_G); tap(KEY_R); tap(KEY_T, true)
	check(not view.gizmo.active and view.mouse_captured and view.gizmo.world.is_equal_approx(aimed), "Captured drone input must not start object transforms")
	view.set_mouse_capture(false)
	# Verify the same modal path previews through the actual Remix worker.
	app.renderer.frame_presented.connect(func(_context: Dictionary): frames += 1)
	app.renderer.response_received.connect(func(r: Dictionary): responses.append(r); check(r.get("ok", false), str(r)))
	app.render_toggle.button_pressed = true
	if not await presented(): app.renderer.stop_worker(); quit(1); return
	responses.clear()
	await pointer(view._project(aimed.origin) + Vector2(90, 0)); tap(KEY_R); tap(KEY_X)
	await pointer(view._project(aimed.origin) + Vector2(0, -90))
	number("37.5")
	await presented()
	check(view.gizmo.world.basis.is_equal_approx(Basis(Vector3.RIGHT, deg_to_rad(37.5)) * aimed.basis), "Numeric entry must drive the live Remix preview")
	check(responses.any(func(r: Dictionary): return r.get("request_op") == "preview_transform" and r.get("result", {}).get("updated") == 1), "Keyboard transforms must update live Remix previews")
	check(not responses.any(func(r: Dictionary): return r.get("request_op") == "scene"), "Light transform previews must not reupload scene geometry")
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(directory.path_join("rotation.png"))
	tap(KEY_ESCAPE); await presented()
	check(view.gizmo.world.is_equal_approx(aimed), "Cancel must restore the live preview baseline")
	app.renderer.stop_worker(); await settle()
	print("Keyboard transform UI: %d failures; artifacts: %s" % [failures, directory])
	quit(1 if failures else 0)
