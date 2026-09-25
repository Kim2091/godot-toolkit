extends SceneTree

const Gizmo = preload("res://scripts/transform_gizmo.gd")
const PARENT := "/RootNode/instances/inst_0123456789ABCDEF_1"
var failures := 0
var app: Control
var directory := ""
var responses: Array[Dictionary] = []
var frames := 0

func check(condition: bool, message: String) -> void:
	if not condition: push_error(message); failures += 1

func settle() -> void:
	for i in range(5): await process_frame

func presented(count := 12) -> bool:
	var deadline := Time.get_ticks_msec() + 90000
	var after := frames + count
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if app.renderer.presented_context.get("revision", -1) == app.state.revision and frames >= after:
			return true
	check(false, "Placement preview did not render in time")
	return false

func parent_picker(parent: String) -> void:
	check(app.inspector.parent_button != null, "Authored asset must expose a parent picker")
	if parent.is_empty():
		app.inspector.detach_button.pressed.emit(); await settle(); return
	app.inspector.parent_button.pressed.emit()
	await settle()
	check(not app.viewport.parent_pick_path.is_empty(), "Parent button must start viewport picking")
	app.viewport.center = Vector3(2, 0, 0); app.viewport.distance = 12; app.viewport.yaw = 0; app.viewport.pitch = 0.7
	app.viewport._camera_updated()
	var event := InputEventMouseButton.new(); event.button_index = MOUSE_BUTTON_LEFT; event.pressed = true
	event.position = app.viewport._project(Vector3(4, 0, 0))
	var motion := InputEventMouseMotion.new(); motion.position = event.position
	app.viewport._gui_input(motion)
	check(app.viewport.parent_hover == parent + "/mesh", "Visible mesh must highlight before attachment")
	if app.renderer.is_ready:
		await presented(3)
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(directory.path_join("parent-picker.png"))
	app.viewport._gui_input(event)
	await settle()

func preview(path: String, delta: Transform3D) -> void:
	app.viewport._gizmo_preview(path, delta)
	await presented()

func luminance(image: Image) -> float:
	# Sample the interior of the first captured plane; avoid overlay handles.
	var sum := 0.0
	for x in range(-4, 5):
		for z in range(-4, 5):
			var location: Vector2 = root.get_final_transform() * app.viewport.get_global_transform_with_canvas() * app.viewport._project(Vector3(x * 0.18, 0, z * 0.18))
			var color := image.get_pixelv(Vector2i(location))
			sum += maxf(color.r, maxf(color.g, color.b))
	return sum / 81.0

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	root.size = Vector2i(1600, 1000)
	app = load("res://main.tscn").instantiate(); root.add_child(app)
	app.render_toggle.button_pressed = false
	directory = app.root_directory.path_join(".work/placement/" + str(Time.get_ticks_usec()))
	app._command({"op": "create", "capture": app.root_directory.path_join("tests/fixtures/capture.usda"), "path": directory.path_join("project.usda")})
	app._select(""); app.viewport.center = Vector3(0, 3, 0)
	app._spawn_light("SphereLight")
	var light: String = app.selection
	check(light.begins_with("/RootNode/StudioAssets/") and app.last_scene.lights.size() == 1, "Add light must spawn without a selected capture prim")
	var pose: Transform3D = app.viewport.gizmo.world
	await parent_picker(PARENT)
	light = app.selection
	check(light.get_base_dir() == PARENT, "Parent picker must attach the light to the chosen instance")
	check(app.viewport.gizmo.world.is_equal_approx(pose), "Attaching must preserve the visible world pose")
	app._command({"op": "duplicate", "path": light})
	check(app.selection.get_base_dir() == PARENT, "UI duplicate must inherit its parent's attachment")
	app._command({"op": "delete", "path": app.selection})
	app._select(light)
	await parent_picker("")
	light = app.selection
	check(light.begins_with("/RootNode/StudioAssets/") and app.last_scene.lights.size() == 1, "World option must detach the authored light")
	# Exercise Add mesh through the asset browser with an empty scene selection.
	var started: Dictionary = JSON.parse_string(app.document.start_ingestion(JSON.stringify({"source": app.root_directory.path_join("tests/fixtures/replacement.usda")})))
	check(started.get("ok", false), "Mesh ingestion must start")
	var imported: Dictionary = {}
	var deadline := Time.get_ticks_msec() + 30000
	while imported.is_empty() and Time.get_ticks_msec() < deadline:
		var result: String = app.document.poll_ingestion()
		if not result.is_empty(): imported = JSON.parse_string(result)
		await process_frame
	check(imported.get("ok", false), "Mesh ingestion must finish")
	if not imported.get("ok", false): quit(1); return
	app.assets.refresh(); await settle(); app._select("")
	var asset: String = imported.result.asset.trim_prefix(directory + "/")
	for i in range(app.assets.cards.item_count):
		if app.assets.cards.get_item_metadata(i) == asset: app.assets.cards.select(i); app.assets._asset_selected(i, true)
	app._use_asset("add_mesh")
	var mesh: String = app.selection
	check(mesh.begins_with("/RootNode/StudioAssets/ref_") and app.last_scene.meshes.size() == 3, "Add mesh must work without selecting a captured prim")
	app._command({"op": "delete", "path": mesh})
	app._select(light)
	app.viewport.center = Vector3(1, 1, 0); app.viewport.distance = 9; app.viewport.yaw = 0.5; app.viewport.pitch = 0.6
	app.viewport._camera_updated()
	var view: Control = app.viewport
	var gizmo = view.gizmo
	var count: int = app.state.revision
	var start: Vector2 = view._project(gizmo.world.origin + Vector3.RIGHT * gizmo.extent() * 0.8)
	var finish: Vector2 = view._project(gizmo.world.origin + Vector3.RIGHT * (gizmo.extent() * 0.8 + 1.5))
	check(gizmo.begin(start, 0), "Light move gizmo must start")
	gizmo.drag(finish)
	check(app.state.revision == count, "Live dragging must leave USD unchanged")
	gizmo._finish(true)
	check(app.state.revision == count + 1 and view.gizmo.world.origin.is_equal_approx(pose.origin + Vector3.RIGHT * 1.5), "Gizmo release must commit one world transform")
	app._command({"op": "undo"})
	check(view.gizmo.world.is_equal_approx(pose), "Undo must restore the light pose in the viewport")
	app.renderer.response_received.connect(func(response: Dictionary):
		responses.append(response)
		check(response.get("ok", false), "Renderer request failed: " + str(response))
		if response.get("request_op") == "frame": frames += 1)
	app.render_toggle.button_pressed = true
	if not await presented(): app.renderer.stop_worker(); quit(1); return
	var camera: Dictionary = view.view_state()
	var worker: int = app.renderer.process.pid
	await parent_picker(PARENT)
	check(app.selection.get_base_dir() == PARENT and view.gizmo.world.is_equal_approx(pose), "Live Remix picker must attach without moving the light")
	await parent_picker("")
	light = app.selection
	view.restore_view_state(camera)
	check(app.renderer.process.pid == worker, "Picking parents must keep the Remix worker running")
	if not await presented(): app.renderer.stop_worker(); quit(1); return
	await RenderingServer.frame_post_draw
	var baseline := root.get_texture().get_image()
	baseline.save_png(directory.path_join("gizmo.png"))
	var revision: int = app.state.revision
	responses.clear()
	await preview(light, Transform3D(Basis.IDENTITY, Vector3(1000, 0, 0)))
	await RenderingServer.frame_post_draw
	var moved := root.get_texture().get_image()
	moved.save_png(directory.path_join("preview.png"))
	var updated := false
	for response in responses:
		if response.get("request_op") == "preview_transform" and response.get("result", {}).get("updated") == 1: updated = true
		check(response.get("request_op") != "scene", "Dragging must not resend scene geometry")
	check(updated and app.state.revision == revision, "Light preview must update the worker without modifying USD")
	check(luminance(baseline) > luminance(moved) + 0.1, "Moving the light away must visibly change illumination")
	await preview(light, Transform3D.IDENTITY)
	await RenderingServer.frame_post_draw
	check(luminance(root.get_texture().get_image()) > luminance(moved) + 0.1, "Canceling the preview must restore illumination")
	# Previewing a parent must update all renderable descendants; stale requests must be ignored.
	responses.clear()
	await preview(PARENT, Transform3D(Basis.IDENTITY, Vector3(1000, 0, 0)))
	check(responses.any(func(r: Dictionary): return r.get("request_op") == "preview_transform" and r.get("result", {}).get("updated") == 1), "Parent preview must reach descendant geometry")
	await preview(PARENT, Transform3D.IDENTITY)
	responses.clear()
	app.renderer.send({"op": "preview_transform", "path": light, "delta": Gizmo.to_array(Transform3D.IDENTITY), "revision": revision - 1})
	await presented(2)
	check(responses.any(func(r: Dictionary): return r.get("request_op") == "preview_transform" and r.get("result", {}).get("updated") == 0), "Stale previews must not affect a new snapshot")
	app.renderer.stop_worker()
	await settle()
	print("Placement UI: %d failures; artifacts: %s" % [failures, directory])
	quit(1 if failures else 0)
