extends Control

signal selected(path: String)
signal camera_changed(camera: Dictionary)
signal translation_requested(delta: Vector3)

var scene: Dictionary = {}
var selected_path := ""
var center := Vector3.ZERO
var distance := 8.0
var yaw := 0.6
var pitch := 0.3
var world_up := Vector3.UP
var orbiting := false
var dragging := false
var drag_start := Vector2.ZERO
var snap := false
var projected: Array[Dictionary] = []
var rendered_texture: Texture2D
var show_render := true

func _view_rect() -> Rect2:
	if rendered_texture == null or not show_render:
		return Rect2(Vector2.ZERO, size)
	var scale_factor := minf(size.x / rendered_texture.get_width(), size.y / rendered_texture.get_height())
	var extent := rendered_texture.get_size() * scale_factor
	return Rect2((size - extent) * 0.5, extent)

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	resized.connect(queue_redraw)

func set_scene(data: Dictionary, frame_all := false) -> void:
	scene = data
	world_up = Vector3(0, 0, 1) if data.get("up_axis", "Y") == "Z" else Vector3.UP
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
	for mesh in scene.get("meshes", []):
		if not all and not _is_selected(mesh):
			continue
		for surface in mesh.surfaces:
			for vertex in surface.vertices:
				var p := _world(mesh.transform, vertex)
				minimum = minimum.min(p)
				maximum = maximum.max(p)
	if minimum.is_finite():
		center = (minimum + maximum) * 0.5
		distance = maxf((maximum - minimum).length() * 1.25, 0.1)
		camera_changed.emit(camera())
	queue_redraw()

func _is_selected(item: Dictionary) -> bool:
	if selected_path.is_empty():
		return false
	for path in [String(item.id), String(item.get("source_path", item.id))]:
		if path == selected_path or path.begins_with(selected_path + "/"):
			return true
	return false

func _draw() -> void:
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
	projected.clear()
	for mesh in scene.get("meshes", []):
		var highlight := _is_selected(mesh)
		if rendering and not highlight:
			continue
		var color := Color("62dac2") if highlight else Color("6a8397")
		for surface in mesh.surfaces:
			var vertices: Array = surface.vertices
			var indices: Array = surface.indices
			for i in range(0, indices.size() - 2, 3):
				var points := PackedVector2Array()
				for j in range(3):
					points.append(_project(_world(mesh.transform, vertices[int(indices[i + j])])))
				if not points[0].is_finite() or not points[1].is_finite() or not points[2].is_finite():
					continue
				projected.append({"points": points, "path": mesh.id})
				if not rendering or highlight:
					draw_polyline(PackedVector2Array([points[0], points[1], points[2], points[0]]), color, 1.0, true)
	for light in scene.get("lights", []):
		var point := _project(_world(light.transform, [0, 0, 0]))
		if point.is_finite():
			draw_circle(point, 5, Color("f2d28b"), false, 1.5, true)
			projected.append({"light": point, "path": light.id})
	draw_string(ThemeDB.fallback_font, Vector2(18, 28), ("REMIX" if rendering else "LAYOUT") + "  ·  Middle/right drag: orbit  ·  Wheel: zoom  ·  F: frame", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("9bb0c0"))
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
	var closest := INF
	var path := ""
	for mesh in scene.get("meshes", []):
		for surface in mesh.surfaces:
			for i in range(0, surface.indices.size() - 2, 3):
				var a := _world(mesh.transform, surface.vertices[int(surface.indices[i])])
				var b := _world(mesh.transform, surface.vertices[int(surface.indices[i + 1])])
				var c := _world(mesh.transform, surface.vertices[int(surface.indices[i + 2])])
				var hit = Geometry3D.ray_intersects_triangle(origin, direction, a, b, c)
				if hit != null and origin.distance_squared_to(hit) < closest:
					closest = origin.distance_squared_to(hit)
					path = mesh.id
	return path

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
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
		yaw -= event.relative.x * 0.008
		pitch = clampf(pitch + event.relative.y * 0.008, -1.5, 1.5)
	camera_changed.emit(camera())
	queue_redraw()
