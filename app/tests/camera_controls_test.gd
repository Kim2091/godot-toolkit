extends SceneTree

const LayoutView = preload("res://scripts/layout_view.gd")
var failures := 0
var view: Control
var camera_updates := 0

func check(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		failures += 1

func key(code: Key, pressed := true, ctrl := false) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = pressed
	event.ctrl_pressed = ctrl
	root.push_input(event, true)

func tap(code: Key, ctrl := false) -> void:
	key(code, true, ctrl)
	key(code, false, ctrl)

func eye() -> Vector3:
	var position: Array = view.camera().position
	return Vector3(position[0], position[1], position[2])

func motion(relative: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.relative = relative
	event.screen_relative = relative
	root.push_input(event, true)

func capture_mouse() -> void:
	view.grab_focus()
	tap(KEY_Z)
	check(view.mouse_captured, "Z must capture the mouse for the focused viewport")
	if DisplayServer.get_name() != "headless":
		check(Input.mouse_mode == Input.MOUSE_MODE_CAPTURED, "Drone mode must capture the OS mouse")
	# Advance movement explicitly so checks do not depend on test frame timing.
	view.set_process(false)

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	root.size = Vector2i(960, 640)
	view = LayoutView.new()
	view.position = Vector2(20, 20)
	view.size = Vector2(700, 500)
	root.add_child(view)
	view.camera_changed.connect(func(_camera: Dictionary): camera_updates += 1)
	await process_frame
	check(view.camera_mode == LayoutView.CameraMode.DRONE, "Drone must be the default camera mode")
	check(not view.mouse_captured, "Starting the app must leave the cursor available")
	for up in [Vector3.UP, Vector3(0, 0, 1)]:
		view.world_up = up
		view.center = Vector3.ZERO
		view.distance = 8
		view.yaw = 0; view.pitch = 0
		view.move_speed = 10
		capture_mouse()
		var start := eye()
		motion(Vector2(80, -40))
		check(eye().is_equal_approx(start), "Mouse look must rotate at a fixed position in either up axis")
		check(view.yaw < 0 and view.pitch < 0, "Moving the mouse right/up must look right/up")
		var forward: Vector3 = -view._basis().z
		key(KEY_W)
		view._process(0.1)
		key(KEY_W, false)
		check((eye() - start).is_equal_approx(forward), "W must move along the new camera direction")
		var position := eye()
		key(KEY_S); view._process(0.1); key(KEY_S, false)
		check(eye().is_equal_approx(start), "S must reverse forward movement")
		key(KEY_A); view._process(0.1); key(KEY_A, false)
		check((eye() - start).is_equal_approx(-view._basis().x), "A must strafe left")
		key(KEY_D); view._process(0.1); key(KEY_D, false)
		check(eye().is_equal_approx(start), "D must strafe right")
		key(KEY_E); view._process(0.1); key(KEY_E, false)
		check((eye() - start).is_equal_approx(up), "E must move up along the stage's up axis")
		key(KEY_Q); view._process(0.1); key(KEY_Q, false)
		check(eye().is_equal_approx(start), "Q must move down along the stage's up axis")
		key(KEY_W); key(KEY_D)
		view._process(0.05); view._process(0.05)
		key(KEY_W, false); key(KEY_D, false)
		check(is_equal_approx(eye().distance_to(start), 1.0), "Diagonal movement must retain the same speed across frame steps")
		position = eye()
		key(KEY_SHIFT); key(KEY_W); view._process(0.1)
		key(KEY_W, false); key(KEY_SHIFT, false)
		check(is_equal_approx(eye().distance_to(position), 4.0), "Shift must boost flight speed")
		var wheel := InputEventMouseButton.new()
		wheel.button_index = MOUSE_BUTTON_WHEEL_UP; wheel.pressed = true
		root.push_input(wheel, true)
		check(view.move_speed > 10, "The wheel must adjust captured flight speed")
		key(KEY_W)
		tap(KEY_Z)
		position = eye()
		view._process(0.1)
		key(KEY_W, false)
		check(not view.mouse_captured and eye().is_equal_approx(position), "Z must release the mouse and stop held movement")
	check(camera_updates > 0, "Flying must publish camera updates for the Remix worker")
	capture_mouse()
	tap(KEY_Z, true)
	check(view.mouse_captured, "Ctrl+Z must not toggle mouse capture")
	tap(KEY_ESCAPE)
	check(not view.mouse_captured, "Escape must release mouse capture")
	if DisplayServer.get_name() != "headless":
		check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "Releasing capture must restore the OS cursor")
	capture_mouse()
	key(KEY_W)
	view.notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_OUT)
	check(not view.mouse_captured and view._flight_keys.is_empty(), "Losing window focus must release capture and held keys")
	key(KEY_W, false)
	capture_mouse()
	view.camera_mode = LayoutView.CameraMode.ORBIT
	check(not view.mouse_captured, "Switching to Orbit must release capture")
	var pivot: Vector3 = view.center
	var position := eye()
	view._look(Vector2(50, 20), false)
	check(view.center == pivot and not eye().is_equal_approx(position), "Orbit must rotate around its pivot")
	view.camera_mode = LayoutView.CameraMode.DRONE
	var field := LineEdit.new()
	field.position = Vector2(750, 20); field.size = Vector2(180, 40)
	root.add_child(field)
	field.grab_focus()
	tap(KEY_Z)
	check(not view.mouse_captured, "Typing in an inspector field must not capture the viewport")
	view.set_scene({"meshes": [], "lights": []})
	view.queue_free()
	await process_frame
	print("Camera controls: %d failures" % failures)
	quit(1 if failures else 0)
