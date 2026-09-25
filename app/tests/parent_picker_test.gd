extends SceneTree

const Sessions = preload("res://scripts/project_sessions.gd")
const INSTANCE := "/RootNode/instances/inst_0123456789ABCDEF_1"
var failures := 0
var app: Control

func check(ok: bool, message: String) -> void:
	if not ok: push_error(message); failures += 1

func settle() -> void:
	for i in 4: await process_frame

func motion(point: Vector2) -> void:
	var event := InputEventMouseMotion.new(); event.position = point
	app.viewport._gui_input(event)

func click(point: Vector2) -> void:
	var event := InputEventMouseButton.new(); event.button_index = MOUSE_BUTTON_LEFT; event.pressed = true; event.position = point
	app.viewport._gui_input(event)

func start() -> void:
	app.inspector.parent_button.pressed.emit()
	await settle()

func _initialize() -> void: run.call_deferred()

func run() -> void:
	root.size = Vector2i(1440, 900)
	var directory := ProjectSettings.globalize_path("res://../.work/parent-picker/%d" % Time.get_ticks_usec()).simplify_path()
	app = load("res://main.tscn").instantiate()
	app.sessions = Sessions.new(directory.path_join("recent.json"))
	root.add_child(app)
	app.render_toggle.button_pressed = false
	app._command({"op": "create", "capture": app.root_directory.path_join("tests/fixtures/capture.usda"), "path": directory.path_join("work.usda")})
	app._command({"op": "add_light", "type": "SphereLight", "translation": [1, 2, 3]})
	var light: String = app.selection
	var pose: Transform3D = app.viewport.gizmo.world
	app.viewport.center = Vector3(2, 0, 0); app.viewport.distance = 12; app.viewport.yaw = 0; app.viewport.pitch = 0.7
	app.viewport._camera_updated()
	await settle()
	for rendered in [false, true]:
		app.viewport.show_render = rendered
		app.viewport.rendered_texture = ImageTexture.create_from_image(Image.create(960, 540, false, Image.FORMAT_RGBA8)) if rendered else null
		await start()
		check(app.viewport.parent_pick_path == light and app.inspector.parent_button.text.contains("Cancel"), "Properties button must begin viewport picking without a dialog")
		var point: Vector2 = app.viewport._project(Vector3(4, 0, 0))
		motion(point)
		check(app.viewport.parent_hover == INSTANCE + "/mesh" and app.selection == light, "Hover must identify visible mesh depth without changing the selected light")
		check(not app.viewport.gizmo.active, "Parent picking must not start a transform")
		var revision: int = app.state.revision
		click(point); await settle()
		light = app.selection
		check(light.get_base_dir() == INSTANCE and app.state.revision == revision + 1, "Click must attach to the draw-call root in one undo step")
		check(app.viewport.gizmo.world.is_equal_approx(pose) and app.viewport.parent_pick_path.is_empty(), "Picker must preserve world pose and leave the attachment selected")
		app._command({"op": "duplicate", "path": light})
		check(app.selection.get_base_dir() == INSTANCE, "Duplicates must retain the chosen parent")
		app._command({"op": "undo"}); app._select(light)
		await start()
		motion(point)
		var escape := InputEventKey.new(); escape.keycode = KEY_ESCAPE; escape.pressed = true
		app.viewport._input(escape)
		check(app.viewport.parent_pick_path.is_empty() and app.selection == light, "Escape must cancel picking without deselecting")
		await start()
		var right := InputEventMouseButton.new(); right.button_index = MOUSE_BUTTON_RIGHT; right.pressed = true
		app.viewport._input(right)
		check(app.viewport.parent_pick_path.is_empty(), "Right click must cancel picking")
		await start()
		if rendered:
			click(Vector2(1, 1))
			check(not app.viewport.parent_pick_path.is_empty(), "Letterbox clicks must not invent a parent")
		app.viewport._notification(Control.NOTIFICATION_WM_WINDOW_FOCUS_OUT)
		check(app.viewport.parent_pick_path.is_empty(), "Focus loss must cancel picking")
		app.inspector.detach_button.pressed.emit(); await settle()
		light = app.selection
		check(light.begins_with("/RootNode/StudioAssets/") and app.viewport.gizmo.world.is_equal_approx(pose), "Detach must preserve world pose")
		app._command({"op": "undo"})
		app._select(INSTANCE + "/" + light.get_file())
		check(app.viewport.gizmo.world.is_equal_approx(pose), "Undo must restore the attachment pose")
		app._command({"op": "redo"}); app._select(light)
	app._command({"op": "add_mesh", "asset": app.root_directory.path_join("tests/fixtures/replacement.usda"), "translation": [1, 2, 3]})
	var mesh: String = app.selection
	var mesh_pose: Transform3D = app.viewport.gizmo.world
	app._select(mesh + "/triangle")
	await start()
	check(app.viewport.parent_pick_path == mesh, "Picking referenced geometry must parent the whole ingested asset")
	click(app.viewport._project(Vector3(4, 0, 0))); await settle()
	check(app.selection.get_base_dir() == INSTANCE and app.viewport.gizmo.world.is_equal_approx(mesh_pose), "Mesh picker must preserve the asset pose")
	await start()
	app._command({"op": "delete", "path": app.selection})
	check(app.viewport.parent_pick_path.is_empty(), "Deleting an object must cancel its pending picker")
	app.queue_free(); await settle()
	print("Viewport parent picker: %d failures" % failures)
	quit(1 if failures else 0)
