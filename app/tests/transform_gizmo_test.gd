extends SceneTree

const LayoutView = preload("res://scripts/layout_view.gd")
const Gizmo = preload("res://scripts/transform_gizmo.gd")
var failures := 0
var view: Control
var commits: Array = []
var previews: Array = []

func check(condition: bool, message: String) -> void:
	if not condition: push_error(message); failures += 1

func button(position: Vector2, pressed: bool, which := MOUSE_BUTTON_LEFT) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = which; event.pressed = pressed; event.position = position
	view._gui_input(event)

func motion(position: Vector2) -> void:
	var event := InputEventMouseMotion.new(); event.position = position
	view._gui_input(event)

func target(pose := Transform3D.IDENTITY) -> void:
	view.gizmo.set_target({"path": "/Light", "world_transform": Gizmo.to_array(pose),
		"authoring": {"kind": "light", "editable": true}, "properties": [{"name": "inputs:radius", "value": 2.0}]})

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	root.size = Vector2i(1000, 800)
	view = LayoutView.new(); root.add_child(view)
	view.size = Vector2(900, 700)
	view.transform_committed.connect(func(path: String, matrix: Array): commits.append([path, Gizmo.from_array(matrix)]))
	view.transform_preview_requested.connect(func(path: String, delta: Array): previews.append([path, Gizmo.from_array(delta)]))
	await process_frame
	for up in [Vector3.UP, Vector3.BACK]:
		view.world_up = up; view.yaw = 0.6; view.pitch = 0.3
		view.distance = 12; view.center = Vector3.ZERO; view.snap = false
		# Simulate the Remix letterbox to exercise the same projection as the image.
		view.rendered_texture = ImageTexture.create_from_image(Image.create(960, 540, false, Image.FORMAT_RGBA8))
		view.show_render = true
		for axis in range(3):
			target(); view.gizmo.set_mode(0)
			var start: Vector3 = Gizmo.AXES[axis] * view.gizmo.extent() * 0.8
			var finish: Vector3 = start + Gizmo.AXES[axis] * 1.7
			var screen: Vector2 = view._project(start)
			check(view.gizmo.hit(screen) == axis, "Projected move handle must be selectable in either up axis")
			var count := commits.size()
			button(screen, true)
			motion(view._project(finish))
			check(view.gizmo.active and commits.size() == count, "Dragging must preview without committing")
			check(view.gizmo.world.origin.is_equal_approx(Gizmo.AXES[axis] * 1.7), "Move must stay on the chosen world axis")
			button(view._project(finish), false)
			check(commits.size() == count + 1 and commits.back()[0] == "/Light", "Release must commit exactly one transform")
			check(previews.back()[1].is_equal_approx(Transform3D.IDENTITY), "Finishing must discard the transient preview")
			check(view.gizmo.radius == 2.0, "Radius guide must use the authored emitter radius")
		# Rotation around each world axis must keep translation and scale intact.
		for axis in range(3):
			var pose := Transform3D(Basis.from_scale(Vector3(2, 3, 4)), Vector3(0.2, 0.1, 0.3))
			target(pose); view.gizmo.set_mode(1)
			var a: Vector3 = Gizmo.AXES[(axis + 1) % 3] * view.gizmo.extent()
			var b := Basis(Gizmo.AXES[axis], deg_to_rad(32)) * a
			check(view.gizmo.begin(view._project(pose.origin + a), axis), "Rotation plane must intersect the pointer ray")
			view.snap = true; view.gizmo.drag(view._project(pose.origin + b))
			check(view.gizmo.world.origin.is_equal_approx(pose.origin), "Rotation must keep the light's origin")
			check(view.gizmo.world.basis.is_equal_approx(Basis(Gizmo.AXES[axis], deg_to_rad(30)) * pose.basis), "Rotation must snap to 15 degrees and preserve scale")
			view.gizmo.cancel(); view.snap = false
			check(view.gizmo.world.is_equal_approx(pose), "Cancel must restore the complete transform")
	# Mouse center handle, translation snapping, Escape and focus/capture cancellation.
	target(); view.gizmo.set_mode(0); view.snap = true
	var start: Vector2 = view._project(Vector3.ZERO)
	var endpoint: Vector2 = view._project(Vector3.RIGHT * 1.7)
	var count := commits.size()
	button(start, true); motion(endpoint)
	check(view.gizmo.active, "Center square must begin a free move")
	var snapped: Vector3 = view.gizmo.world.origin
	check(snapped.is_equal_approx(snapped.snapped(Vector3.ONE)), "Free move must respect unit snapping")
	var escape := InputEventKey.new(); escape.keycode = KEY_ESCAPE; escape.pressed = true
	view._unhandled_key_input(escape)
	check(not view.gizmo.active and view.gizmo.world.origin.is_zero_approx() and commits.size() == count, "Escape must cancel without an undo entry")
	button(start, true); motion(endpoint); view.notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_OUT)
	check(not view.gizmo.active and commits.size() == count, "Losing focus must cancel the preview")
	button(start, true); motion(endpoint); view.set_mouse_capture(true)
	check(not view.gizmo.active and commits.size() == count, "Entering drone mode must cancel the preview")
	check(view.gizmo.path == "/Light" and view.gizmo.hit(start) == -2 and not view.gizmo.begin(start, 0), "Drone flight must retain the selected gizmo without allowing pointer manipulation")
	view.set_mouse_capture(false)
	button(start, true); button(start, false)
	check(commits.size() == count, "Clicking without dragging must not author a transform")
	view.gizmo.set_target({"path": "/CaptureRoot", "world_transform": Gizmo.to_array(Transform3D.IDENTITY), "authoring": {"kind": "xform", "editable": false}})
	check(view.gizmo.hit(start) == -2, "Read-only capture instance roots must not show transform handles")
	# A large emitter can cross the eye plane while flying past the light.
	var eye: Vector3 = view.center + view._basis().z * view.distance
	var forward: Vector3 = -view._basis().z
	var clipped: PackedVector2Array = view._project_segment(eye - forward, eye + forward * 3)
	check(clipped.size() == 2 and clipped[0].is_finite() and clipped[1].is_finite(), "Guide lines crossing the eye plane must retain their visible portion")
	clipped = view._project_segment(eye - forward * 1000000, eye + forward * 1000000)
	check(clipped.size() == 2 and clipped[0].is_finite() and clipped[1].is_finite(), "Clipping very large guides must not round the depth to zero")
	check(view._project_segment(eye - forward, eye - forward * 2).is_empty(), "Guides entirely behind the camera must be clipped")
	view.queue_free(); await process_frame
	print("Transform gizmo: %d failures" % failures)
	quit(1 if failures else 0)
