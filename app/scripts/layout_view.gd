extends Control

const LayoutGeometry = preload("res://scripts/layout_geometry.gd")
const WireframeShader = preload("res://shaders/layout_wireframe.gdshader")
enum CameraMode { DRONE, ORBIT }

signal selected(path: String)
signal camera_changed(camera: Dictionary)
signal translation_requested(delta: Vector3)

var scene: Dictionary = {}
var selected_path := "":
	set(value):
		if selected_path == value:
			return
		selected_path = value
		_update_selection()
var center := Vector3.ZERO
var distance := 8.0
var yaw := 0.6
var pitch := 0.3
var world_up := Vector3.UP
var camera_mode: CameraMode = CameraMode.DRONE:
	set(value):
		camera_mode = value
		set_mouse_capture(false)
		orbiting = false
		dragging = false
		queue_redraw()
var mouse_captured := false
var move_speed := 2.0
var look_sensitivity := 0.003
var _flight_keys: Dictionary = {}
var _capture_cursor := Vector2.ZERO
var orbiting := false
var dragging := false
var drag_start := Vector2.ZERO
var snap := false
var rendered_texture: Texture2D:
	set(value):
		rendered_texture = value
		_sync_view()
var show_render := true:
	set(value):
		show_render = value
		_sync_view()
var geometry := LayoutGeometry.new()
var wire_viewport: SubViewport
var wire_camera: Camera3D
var wire_instances: Array[MeshInstance3D] = []
var wire_material: ShaderMaterial
var selection_material: ShaderMaterial
var _view_state: Array = []

func _view_rect() -> Rect2:
	if rendered_texture == null or not show_render:
		return Rect2(Vector2.ZERO, size)
	var scale_factor := minf(size.x / rendered_texture.get_width(), size.y / rendered_texture.get_height())
	var extent := rendered_texture.get_size() * scale_factor
	return Rect2((size - extent) * 0.5, extent)

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_CLICK
	focus_exited.connect(func(): set_mouse_capture(false))
	set_process(false)
	clip_contents = true
	wire_viewport = SubViewport.new()
	wire_viewport.own_world_3d = true
	wire_viewport.transparent_bg = true
	wire_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	wire_viewport.msaa_3d = Viewport.MSAA_2X
	add_child(wire_viewport)
	wire_camera = Camera3D.new()
	wire_camera.fov = 60.0
	wire_viewport.add_child(wire_camera)
	wire_material = ShaderMaterial.new()
	wire_material.shader = WireframeShader
	selection_material = ShaderMaterial.new()
	selection_material.shader = WireframeShader
	selection_material.set_shader_parameter("wire_color", Color("62dac2"))
	resized.connect(_sync_view)
	_rebuild_geometry()

func set_mouse_capture(capture: bool, restore_cursor := true) -> void:
	if capture and (camera_mode != CameraMode.DRONE or not is_visible_in_tree()):
		return
	if capture == mouse_captured:
		return
	mouse_captured = capture
	orbiting = false
	dragging = false
	_flight_keys.clear()
	set_process(capture)
	if capture:
		var rectangle := _view_rect()
		_capture_cursor = get_local_mouse_position().clamp(rectangle.position, rectangle.end)
		grab_focus()
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		if restore_cursor and is_inside_tree() and get_window().has_focus():
			get_viewport().warp_mouse(get_global_transform_with_canvas() * _capture_cursor)
	queue_redraw()

func _notification(what: int) -> void:
	if what in [NOTIFICATION_WM_WINDOW_FOCUS_OUT, NOTIFICATION_APPLICATION_FOCUS_OUT]:
		set_mouse_capture(false, false)
		orbiting = false
		dragging = false
	elif what == NOTIFICATION_VISIBILITY_CHANGED and not is_visible_in_tree():
		set_mouse_capture(false, false)

func _exit_tree() -> void:
	set_mouse_capture(false, false)

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	if event.ctrl_pressed or event.alt_pressed or event.meta_pressed:
		return
	var focused := get_viewport().gui_get_focus_owner()
	if focused is LineEdit or focused is TextEdit:
		return
	if event.keycode == KEY_Z and camera_mode == CameraMode.DRONE:
		if has_focus() or _view_rect().has_point(get_local_mouse_position()):
			set_mouse_capture(true)
			get_viewport().set_input_as_handled()

func _input(event: InputEvent) -> void:
	if not mouse_captured:
		return
	if event is InputEventMouseMotion:
		_look(event.screen_relative, true)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton:
		if event.pressed:
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				move_speed = minf(move_speed * 1.25, 1e9)
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				move_speed = maxf(move_speed / 1.25, 0.0001)
		# Captured clicks must not select or drag scene objects or activate UI.
		get_viewport().set_input_as_handled()
	elif event is InputEventKey:
		if event.pressed and not event.echo and (event.keycode == KEY_ESCAPE or
			(event.keycode == KEY_Z and not (event.ctrl_pressed or event.alt_pressed or event.meta_pressed))):
			set_mouse_capture(false)
			get_viewport().set_input_as_handled()
			return
		if event.ctrl_pressed or event.alt_pressed or event.meta_pressed:
			_flight_keys.clear()
			return
		var key: int = event.physical_keycode if event.physical_keycode != 0 else event.keycode
		if key in [KEY_W, KEY_A, KEY_S, KEY_D, KEY_Q, KEY_E, KEY_SHIFT]:
			if event.pressed:
				_flight_keys[key] = true
			else:
				_flight_keys.erase(key)
			get_viewport().set_input_as_handled()

func _process(delta: float) -> void:
	if not mouse_captured:
		return
	var basis := _basis()
	var movement := basis.x * (int(_flight_keys.has(KEY_D)) - int(_flight_keys.has(KEY_A)))
	movement += basis.z * (int(_flight_keys.has(KEY_S)) - int(_flight_keys.has(KEY_W)))
	movement += world_up * (int(_flight_keys.has(KEY_E)) - int(_flight_keys.has(KEY_Q)))
	if movement.is_zero_approx():
		return
	var boost := 4.0 if _flight_keys.has(KEY_SHIFT) else 1.0
	center += movement.normalized() * move_speed * boost * minf(delta, 0.1)
	_camera_updated()

func _look(motion: Vector2, drone: bool) -> void:
	var eye := center + _basis().z * distance
	var sensitivity := look_sensitivity if drone else 0.008
	yaw -= motion.x * sensitivity
	pitch = clampf(pitch + motion.y * sensitivity, -1.5, 1.5)
	if drone:
		# Keep the eye fixed: center remains a point in front of a flying camera.
		center = eye - _basis().z * distance
	_camera_updated()

func _camera_updated() -> void:
	camera_changed.emit(camera())
	queue_redraw()

func _rebuild_geometry() -> void:
	if wire_viewport == null:
		return
	for instance in wire_instances:
		instance.free()
	wire_instances.clear()
	geometry.rebuild(scene)
	for entry in geometry.entries:
		var instance := MeshInstance3D.new()
		instance.mesh = entry.geometry.mesh
		instance.transform = entry.transform
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		wire_viewport.add_child(instance)
		wire_instances.append(instance)
	_update_selection()

func _update_selection() -> void:
	for i in range(wire_instances.size()):
		var highlight: bool = geometry.entries[i].matches(selected_path)
		wire_instances[i].layers = 3 if highlight else 1
		wire_instances[i].material_override = selection_material if highlight else wire_material
	_invalidate_wireframe()

func _invalidate_wireframe() -> void:
	if wire_viewport != null:
		wire_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	queue_redraw()

func _sync_view() -> void:
	if wire_viewport == null:
		return
	var rectangle := _view_rect()
	var rendering := rendered_texture != null and show_render
	var state := [rectangle, center, distance, yaw, pitch, world_up, rendering]
	if state == _view_state:
		return
	_view_state = state
	wire_viewport.size = Vector2i(maxi(1, int(rectangle.size.x)), maxi(1, int(rectangle.size.y)))
	var basis := _basis()
	wire_camera.transform = Transform3D(basis, center + basis.z * distance)
	wire_camera.near = maxf(distance * 0.00001, 0.0001)
	wire_camera.far = maxf(distance * 100.0, 1000.0)
	wire_camera.cull_mask = 2 if rendering else 1
	_invalidate_wireframe()

func set_scene(data: Dictionary, frame_all := false) -> void:
	scene = data
	world_up = Vector3(0, 0, 1) if data.get("up_axis", "Y") == "Z" else Vector3.UP
	_rebuild_geometry()
	if frame_all:
		frame_selection(true)
	queue_redraw()

func _basis() -> Basis:
	var forward := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
	if world_up.z == 1:
		forward = Vector3(forward.x, -forward.z, forward.y)
	var right := world_up.cross(forward).normalized()
	return Basis(right, forward.cross(right).normalized(), forward)

func camera() -> Dictionary:
	var basis := _basis()
	var position := center + basis.z * distance
	return {"position": _array(position), "forward": _array(-basis.z), "up": _array(basis.y), "right": _array(basis.x), "fov": 60.0}

func _array(v: Vector3) -> Array:
	return [v.x, v.y, v.z]

func _world(matrix: Array, point: Array) -> Vector3:
	return Vector3(
		point[0] * matrix[0] + point[1] * matrix[4] + point[2] * matrix[8] + matrix[12],
		point[0] * matrix[1] + point[1] * matrix[5] + point[2] * matrix[9] + matrix[13],
		point[0] * matrix[2] + point[1] * matrix[6] + point[2] * matrix[10] + matrix[14])

func _project(point: Vector3) -> Vector2:
	var basis := _basis()
	var local := basis.transposed() * (point - center - basis.z * distance)
	if local.z >= -0.001:
		return Vector2(INF, INF)
	var rectangle := _view_rect()
	var focal := rectangle.size.y / (2.0 * tan(deg_to_rad(30)))
	return rectangle.get_center() + Vector2(local.x, -local.y) * focal / -local.z

func frame_selection(all := false) -> void:
	var minimum := Vector3(INF, INF, INF)
	var maximum := -minimum
	for entry in geometry.entries:
		if not all and not entry.matches(selected_path):
			continue
		minimum = minimum.min(entry.bounds.position)
		maximum = maximum.max(entry.bounds.end)
	if minimum.is_finite():
		center = (minimum + maximum) * 0.5
		distance = maxf((maximum - minimum).length() * 1.25, 0.1)
		move_speed = maxf(distance * 0.25, 0.01)
		camera_changed.emit(camera())
	queue_redraw()

func _draw() -> void:
	_sync_view()
	draw_rect(Rect2(Vector2.ZERO, size), Color("111820"))
	var rendering := rendered_texture != null and show_render
	if rendering:
		draw_texture_rect(rendered_texture, _view_rect(), false)
	var grid_scale := pow(10.0, floor(log(maxf(distance, 0.01)) / log(10.0)) - 1)
	for i in range(-20, 21):
		var a := Vector3(i * grid_scale, 0, -20 * grid_scale)
		var b := Vector3(i * grid_scale, 0, 20 * grid_scale)
		var c := Vector3(-20 * grid_scale, 0, i * grid_scale)
		var d := Vector3(20 * grid_scale, 0, i * grid_scale)
		if world_up.z == 1:
			a = Vector3(a.x, a.z, 0); b = Vector3(b.x, b.z, 0)
			c = Vector3(c.x, c.z, 0); d = Vector3(d.x, d.z, 0)
		if not rendering:
			_line(a, b, Color("23303c")); _line(c, d, Color("23303c"))
	if wire_viewport != null:
		draw_texture_rect(wire_viewport.get_texture(), _view_rect(), false)
	for light in scene.get("lights", []):
		var point := _project(_world(light.transform, [0, 0, 0]))
		if point.is_finite():
			draw_circle(point, 5, Color("f2d28b"), false, 1.5, true)
	var help := "Orbit · Right/middle drag: orbit · Wheel: zoom · F: frame"
	if camera_mode == CameraMode.DRONE:
		help = "Drone · Z: fly · Right/middle drag: look · Wheel: zoom · F: frame"
	if mouse_captured:
		help = "Drone · WASD: move · Q/E: down/up · Shift: fast · Wheel: speed · Z/Esc: release"
		var aim := _view_rect().get_center()
		draw_line(aim - Vector2(5, 0), aim + Vector2(5, 0), Color("c3d1df"))
		draw_line(aim - Vector2(0, 5), aim + Vector2(0, 5), Color("c3d1df"))
	draw_string(ThemeDB.fallback_font, Vector2(18, 28), ("REMIX" if rendering else "LAYOUT") + " · " + help, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("9bb0c0"))
	if scene.is_empty():
		draw_string(ThemeDB.fallback_font, size * 0.5 - Vector2(150, 0), "Open a project or create one from a capture", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color("9bb0c0"))

func _line(a: Vector3, b: Vector3, color: Color) -> void:
	var x := _project(a)
	var y := _project(b)
	if x.is_finite() and y.is_finite():
		draw_line(x, y, color, 1.0, true)

func _pick(position: Vector2) -> String:
	for light in scene.get("lights", []):
		if position.distance_to(_project(_world(light.transform, [0, 0, 0]))) < 12:
			return light.id
	var rectangle := _view_rect()
	var basis := _basis()
	var local := (position - rectangle.get_center()) * (2 * tan(deg_to_rad(30))) / rectangle.size.y
	var direction := (basis.x * local.x - basis.y * local.y - basis.z).normalized()
	var origin := center + basis.z * distance
	return geometry.pick(origin, direction)

func _gui_input(event: InputEvent) -> void:
	if mouse_captured:
		return
	if event is InputEventMouseButton:
		if event.pressed:
			grab_focus()
		if event.button_index in [MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT]:
			orbiting = event.pressed
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			distance = maxf(distance * 0.85, 0.01)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			distance *= 1.15
		elif event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			if event.shift_pressed and not selected_path.is_empty():
				dragging = true
				drag_start = event.position
			else:
				selected_path = _pick(event.position)
				selected.emit(selected_path)
		elif event.button_index == MOUSE_BUTTON_LEFT and not event.pressed and dragging:
			dragging = false
			var movement: Vector2 = event.position - drag_start
			var basis := _basis()
			var delta := (basis.x * movement.x - basis.y * movement.y) * distance / maxf(size.y, 1)
			if snap:
				delta = delta.snapped(Vector3.ONE)
			translation_requested.emit(delta)
	if event is InputEventMouseMotion and orbiting:
		_look(event.relative, camera_mode == CameraMode.DRONE)
	elif event is InputEventMouseButton:
		_camera_updated()
