extends SceneTree

const Sessions = preload("res://scripts/project_sessions.gd")
const FIRST := "/RootNode/instances/inst_0123456789ABCDEF_0"
const SECOND := "/RootNode/instances/inst_0123456789ABCDEF_1"
var failures := 0
var app: Control

func check(ok: bool, message: String) -> void:
	if not ok: push_error(message); failures += 1

func settle() -> void:
	for i in 4: await process_frame

func _initialize() -> void: run.call_deferred()

func run() -> void:
	root.size = Vector2i(1440, 900)
	var directory := ProjectSettings.globalize_path("res://../.work/skeleton-overlay/%d" % Time.get_ticks_usec()).simplify_path()
	app = load("res://main.tscn").instantiate()
	app.sessions = Sessions.new(directory.path_join("recent.json"))
	root.add_child(app)
	app.render_toggle.button_pressed = false
	app._command({"op": "create", "capture": app.root_directory.path_join("tests/fixtures/skinned/capture.usda"), "path": directory.path_join("work.usda")})
	var view: Control = app.viewport
	var overlay: RefCounted = view.skeleton_overlay
	view.center = Vector3(102, 0, 4); view.distance = 8; view.yaw = 0; view.pitch = 0.4
	await settle()
	check(overlay.selected.is_empty(), "Loading a capture without selection must not draw all bones")
	for rendered in [false, true]:
		view.show_render = rendered
		view.rendered_texture = ImageTexture.create_from_image(Image.create(960, 540, false, Image.FORMAT_RGBA8)) if rendered else null
		app._select(FIRST + "/mesh")
		await settle()
		check(overlay.selected == [FIRST + "/skel"], "Picking one mesh must show only its own skeleton")
		var drawing: Dictionary = overlay.projected(view)
		check(drawing.lines.size() == 2 and drawing.joints.size() == 1 and drawing.roots.size() == 1, "Bone connections and root/joint markers must appear in both viewports")
		if not drawing.roots.is_empty():
			check(drawing.roots[0].is_equal_approx(view._project(Vector3(101, 0, 4))), "Root marker must use the captured joint position")
		# Camera capture must keep the overlay, just like selection gizmos.
		view.set_mouse_capture(true)
		view._look(Vector2(5, -3), true)
		check(overlay.selected.size() == 1 and not overlay.projected(view).lines.is_empty(), "Drone movement must retain the bones")
		view.set_mouse_capture(false, false)
		var delta := Transform3D(Basis.IDENTITY, Vector3(0.25, 0, 0))
		view._gizmo_preview(FIRST + "/mesh", delta)
		drawing = overlay.projected(view)
		if not drawing.roots.is_empty():
			check(drawing.roots[0].is_equal_approx(view._project(Vector3(101.25, 0, 4))), "Overlay must follow the mesh's transform preview")
		view._gizmo_preview(FIRST + "/mesh", Transform3D.IDENTITY)
		app._select(SECOND + "/mesh")
		check(overlay.selected == [SECOND + "/skel"], "Changing selection must discard the old instance's skeleton")
		app._select(FIRST)
		check(overlay.selected == [FIRST + "/skel"], "Selecting the skinned instance in the tree must show its bones")
		app._select("")
		check(overlay.selected.is_empty(), "Deselecting must clear the overlay")
	# Projection clips near-camera connections and letterboxing.
	var rect: Rect2 = view._view_rect()
	var clipped: PackedVector2Array = overlay._clip_segment(PackedVector2Array([rect.position - rect.size, rect.end + rect.size]), rect)
	check(clipped.size() == 2 and clipped[0].is_equal_approx(rect.position) and clipped[1].is_equal_approx(rect.end), "Bone connections must be clipped to the viewport image")
	var eye: Vector3 = view.center + view._basis().z * view.distance
	var near: PackedVector2Array = view._project_segment(eye + view._basis().z, view.center)
	check(near.size() == 2 and near[0].is_finite() and near[1].is_finite(), "Bones crossing the near plane must remain finite")
	app._command({"op": "add_light"})
	check(overlay.selected.is_empty(), "Selecting an unrelated light must not retain bones")
	app._command({"op": "replace_mesh", "path": FIRST + "/mesh", "asset": app.root_directory.path_join("tests/fixtures/replacement.usda")})
	check(overlay.selected.is_empty() and overlay.rigs.is_empty(), "Replacing a skinned mesh must clear its overlay data")
	app._command({"op": "revert_mesh", "path": app.selection})
	check(overlay.selected == [FIRST + "/skel"], "Reverting must restore the selected capture's bones")
	app._command({"op": "visibility", "path": FIRST + "/mesh", "visible": false})
	check(overlay.selected.is_empty(), "Hidden geometry must not leave a stale selected overlay")
	view.set_scene({})
	check(overlay.selected.is_empty() and overlay.rigs.is_empty(), "Changing or closing the scene must clear bones")
	app.queue_free(); await settle()
	print("Skeleton overlay: %d failures" % failures)
	quit(1 if failures else 0)
