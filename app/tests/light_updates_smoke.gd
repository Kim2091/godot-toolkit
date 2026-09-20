extends SceneTree

const Gizmo = preload("res://scripts/transform_gizmo.gd")
var app: Control
var failures := 0
var frames := 0
var responses: Array[Dictionary] = []
var directory := ""

func check(condition: bool, message: String) -> void:
	if not condition: push_error(message); failures += 1

func presented(count := 12) -> bool:
	var deadline := Time.get_ticks_msec() + 60000
	var after := frames + count
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if app.renderer.presented_context.get("revision", -1) == app.state.revision and frames >= after: return true
	check(false, "Updated light did not render in time")
	return false

func request(data: Dictionary) -> Dictionary:
	app.renderer.send(data)
	var id: int = app.renderer.next_id
	var deadline := Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		for response in responses:
			if response.get("id") == id: return response.get("result", {})
	check(false, "Renderer did not acknowledge " + str(data.get("op")))
	return {}

func brightness() -> float:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var result := 0.0
	for x in range(-3, 4):
		for z in range(-3, 4):
			var pixel: Vector2 = root.get_final_transform() * app.viewport.get_global_transform_with_canvas() * app.viewport._project(Vector3(x * 0.15, 0, z * 0.15))
			var color := image.get_pixelv(Vector2i(pixel))
			result += maxf(color.r, maxf(color.g, color.b))
	return result / 49

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	root.size = Vector2i(1600, 1000)
	app = load("res://main.tscn").instantiate(); root.add_child(app)
	app.render_toggle.button_pressed = false
	directory = app.root_directory.path_join(".work/light_updates/" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(directory)
	app.renderer.frame_presented.connect(func(_context: Dictionary): frames += 1)
	app.renderer.response_received.connect(func(response: Dictionary):
		responses.append(response)
		check(response.get("ok", false), "Renderer request failed: " + str(response)))
	app._command({"op": "create", "capture": app.root_directory.path_join("tests/fixtures/capture.usda"), "path": directory.path_join("project.usda")})
	app._command({"op": "add_light", "type": "SphereLight", "translation": [0, 3, 0]})
	var light: String = app.selection
	app._command({"op": "set_authoring_property", "path": light, "property": "inputs:radius", "value": 0.5})
	app._command({"op": "set_authoring_property", "path": light, "property": "inputs:intensity", "value": 500})
	var view: Control = app.viewport
	view.center = Vector3(0, 1, 0); view.distance = 10; view.pitch = 0.8; view.yaw = 0.2
	view._camera_updated()
	app.render_toggle.button_pressed = true
	if not await presented(): app.renderer.stop_worker(); quit(1); return
	var lit := await brightness()
	var wire_id: int = view.wire_instances[0].get_instance_id()
	var geometry_revision: int = app.last_scene.geometry_revision
	# Shorten the fork's static-light sleep threshold so the regression is quick.
	await request({"op": "settings", "settings": {"rtx.numFramesToKeepLights": "4"}})
	responses.clear()
	# Commit repeated real gizmo drags, then update the inspector between drags.
	for i in range(8):
		var old: Transform3D = view.gizmo.world
		var step := 0.6 if i % 2 == 0 else -0.6
		var handle: Vector3 = Vector3.RIGHT * view.gizmo.extent() * 0.8
		check(view.gizmo.begin(view._project(old.origin + handle), 0), "Repeated gizmo drag must begin")
		view.gizmo.drag(view._project(old.origin + handle + Vector3.RIGHT * step))
		await presented(3)
		var revision: int = app.state.revision
		view.gizmo._finish(true)
		check(app.state.revision == revision + 1, "Each drag must commit exactly once")
		check(view.gizmo.world.origin.is_equal_approx(old.origin + Vector3.RIGHT * step), "Gizmo must retain the committed position")
		await presented(3)
		var spin: SpinBox = app.inspector.controls[light + "|inputs:intensity"].widget
		revision = app.state.revision
		spin.value = 501 + i
		spin.get_line_edit().text_submitted.emit(str(spin.value))
		await presented(3)
		check(app.state.revision == revision + 1, "Inspector edits must commit and render")
		check(view.wire_instances[0].get_instance_id() == wire_id, "Light edits must preserve wire geometry and picking acceleration")
	# After repeated edits, moving away must still change actual illumination.
	var far := Transform3D(Basis.IDENTITY, Vector3(1000, 0, 0))
	await request({"op": "preview_transform", "path": light, "delta": Gizmo.to_array(far), "revision": app.state.revision})
	await presented()
	var dark := await brightness()
	check(lit > dark + 0.15, "Light must keep following previews after many edits: lit=%.3f far=%.3f" % [lit, dark])
	await request({"op": "preview_transform", "path": light, "delta": Gizmo.to_array(Transform3D.IDENTITY), "revision": app.state.revision})
	await presented()
	check(await brightness() > dark + 0.15, "Cancel must restore the latest committed light position")
	# Several edits in one event loop must coalesce to the latest complete snapshot.
	for i in range(12):
		app._command({"op": "set_authoring_property", "path": light, "property": "inputs:intensity", "value": 700 + i})
	await presented()
	check(app.renderer.presented_context.revision == app.state.revision, "Coalesced light updates must reach the final document revision")
	check(app.last_scene.geometry_revision == geometry_revision, "Light edits must retain the geometry revision")
	app._command({"op": "set_authoring_property", "path": light, "property": "inputs:intensity", "value": 0})
	await presented()
	check(await brightness() < lit - 0.15, "Editing radiance must change actual illumination")
	app._command({"op": "undo"})
	await presented()
	check(await brightness() > dark + 0.15, "Undo must restore radiance in the renderer")
	check(responses.any(func(r: Dictionary): return r.get("request_op") == "lights"), "Light edits must use incremental renderer updates")
	check(not responses.any(func(r: Dictionary): return r.get("request_op") == "scene"), "Light edits must not upload the full scene")
	# Outdated snapshots must not erase lights or incorrectly advance frame context.
	var stale := await request({"op": "lights", "lights": [], "revision": app.state.revision + 100, "geometry_revision": geometry_revision - 1})
	check(stale.get("revision") == app.state.revision and stale.get("updated") == 0, "A snapshot for old geometry must be ignored")
	stale = await request({"op": "lights", "lights": [], "revision": app.state.revision - 1, "geometry_revision": geometry_revision})
	check(stale.get("revision") == app.state.revision and stale.get("updated") == 0, "An older light revision must be ignored")
	app._command({"op": "delete", "path": light})
	check(app.selection.is_empty() and view.selected_path.is_empty() and view.gizmo.path.is_empty(), "Deleting a light must immediately clear selection and gizmo")
	check(app.inspector.controls.is_empty(), "Deleting a light must clear the inspector")
	await presented()
	check(await brightness() < lit - 0.15, "Deleting a light must remove its illumination")
	app._command({"op": "undo"})
	await presented()
	check(await brightness() > dark + 0.15, "Undo must restore the deleted light in the renderer")
	app._command({"op": "redo"})
	await presented()
	check(await brightness() < lit - 0.15 and view.gizmo.path.is_empty(), "Redo must remove the light without leaving a gizmo")
	check(view.wire_instances[0].get_instance_id() == wire_id, "Light deletion and history must preserve geometry")
	print("Light update brightness: near=%.3f far=%.3f" % [lit, dark])
	app.renderer.stop_worker()
	for i in range(5): await process_frame
	print("Light updates: %d failures; artifacts: %s" % [failures, directory])
	quit(1 if failures else 0)
