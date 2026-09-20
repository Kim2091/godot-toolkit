extends RefCounted

const LightGuide = preload("res://scripts/light_guide.gd")
const KeyboardTransform = preload("res://scripts/keyboard_transform.gd")
const AXES := [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
const COLORS := [Color("f16c65"), Color("83d979"), Color("6da7ff")]
var view: Control
var path := ""
var world := Transform3D.IDENTITY
var original := Transform3D.IDENTITY
var radius := 0.0
var light := false
var light_guide := LightGuide.new()
var mode := 0
var active := false
var axis := -2
var hover := -2
var plane := Plane()
var start := Vector3.ZERO
var modal: RefCounted

static func from_array(a: Array) -> Transform3D:
	return Transform3D(Basis(Vector3(a[0], a[1], a[2]), Vector3(a[4], a[5], a[6]), Vector3(a[8], a[9], a[10])), Vector3(a[12], a[13], a[14]))

static func to_array(t: Transform3D) -> Array:
	return [t.basis.x.x, t.basis.x.y, t.basis.x.z, 0, t.basis.y.x, t.basis.y.y, t.basis.y.z, 0,
		t.basis.z.x, t.basis.z.y, t.basis.z.z, 0, t.origin.x, t.origin.y, t.origin.z, 1]

func set_target(details: Dictionary) -> void:
	cancel()
	path = ""; radius = 0; light = false
	if details.has("world_transform") and details.get("authoring", {}).get("editable", false):
		path = details.path
		world = from_array(details.world_transform)
		light = details.authoring.kind == "light"
		if light:
			light_guide.configure(details)
			radius = light_guide.radius
	view.queue_redraw()

func set_mode(value: int) -> void:
	cancel(); mode = value; hover = -2; view.queue_redraw()

func cancel() -> void:
	if active: _finish(false)

func begin_modal(operation: int, position: Vector2) -> bool:
	if active or view.mouse_captured or path.is_empty() or not view._view_rect().has_point(position): return false
	if operation == KeyboardTransform.Kind.AIM and not light: return false
	if absf(world.basis.determinant()) < 1e-12 or not view._project(world.origin).is_finite(): return false
	original = world; axis = -1; active = true; hover = -2
	modal = KeyboardTransform.new()
	modal.begin(view, operation, original, position)
	drag(position)
	return true

func extent() -> float:
	var eye: Vector3 = view.center + view._basis().z * view.distance
	var depth: float = (world.origin - eye).dot(-view._basis().z)
	return maxf(depth * 2.0 * tan(deg_to_rad(30)) * 80.0 / maxf(view._view_rect().size.y, 1), 0.00001)

func circle(index: int, size: float) -> PackedVector3Array:
	var points := PackedVector3Array()
	for i in range(65):
		var angle := TAU * i / 64.0
		points.append((AXES[(index + 1) % 3] * cos(angle) + AXES[(index + 2) % 3] * sin(angle)) * size)
	return points

func hit(position: Vector2) -> int:
	if path.is_empty() or view.mouse_captured or not view._view_rect().has_point(position): return -2
	var origin: Vector2 = view._project(world.origin)
	if not origin.is_finite(): return -2
	if mode == 0 and origin.distance_to(position) <= 8: return -1
	var best := 9.0
	var result := -2
	for i in range(3):
		var points := PackedVector3Array([world.origin + AXES[i] * extent() * 0.18, world.origin + AXES[i] * extent()])
		if mode == 1:
			points = circle(i, extent())
			for j in range(points.size()): points[j] += world.origin
		for j in range(points.size() - 1):
			var a: Vector2 = view._project(points[j]); var b: Vector2 = view._project(points[j + 1])
			if not a.is_finite() or not b.is_finite() or a.distance_to(b) < 0.001: continue
			var d := position.distance_to(Geometry2D.get_closest_point_to_segment(position, a, b))
			if d < best: best = d; result = i
	return result

func begin(position: Vector2, handle: int) -> bool:
	if view.mouse_captured or handle == -2 or absf(world.basis.determinant()) < 1e-12: return false
	original = world
	var normal: Vector3 = view._basis().z
	if mode == 1:
		normal = AXES[handle]
	elif handle >= 0:
		normal -= AXES[handle] * normal.dot(AXES[handle])
	if normal.length_squared() < 0.0001: return false
	plane = Plane(normal.normalized(), world.origin)
	var ray: Dictionary = view._ray(position)
	var point = plane.intersects_ray(ray.origin, ray.direction)
	if point == null or (mode == 1 and Vector3(point).distance_to(world.origin) < 0.00001): return false
	start = point; axis = handle; active = true
	view.queue_redraw()
	return true

func drag(position: Vector2) -> void:
	if modal != null:
		world = modal.update(view, position, path, world)
		view._gizmo_preview(path, world * original.affine_inverse())
		view.queue_redraw()
		return
	var ray: Dictionary = view._ray(position)
	var point = plane.intersects_ray(ray.origin, ray.direction)
	if point == null: return
	world = original
	if mode == 0:
		var delta: Vector3 = point - start
		if axis >= 0:
			var amount := delta.dot(AXES[axis])
			if view.snap: amount = snappedf(amount, 1.0)
			delta = AXES[axis] * amount
		elif view.snap: delta = delta.snapped(Vector3.ONE)
		world.origin += delta
	else:
		var a := (start - original.origin).normalized()
		var b: Vector3 = (point - original.origin).normalized()
		var angle := atan2(AXES[axis].dot(a.cross(b)), a.dot(b))
		if view.snap: angle = snappedf(angle, deg_to_rad(15))
		world.basis = Basis(AXES[axis], angle) * original.basis
	view._gizmo_preview(path, world * original.affine_inverse())
	view.queue_redraw()

func _finish(commit: bool) -> void:
	active = false
	modal = null
	var changed := not world.is_equal_approx(original)
	view._gizmo_preview(path, Transform3D.IDENTITY)
	if not commit: world = original
	if commit and changed: view.transform_committed.emit(path, to_array(world))
	view.queue_redraw()

func handle_input(event: InputEvent) -> bool:
	if active:
		if modal != null:
			if event is InputEventKey:
				if event.pressed and modal.input_number(event):
					drag(modal.pointer)
				elif event.pressed and not event.echo:
					if event.keycode == KEY_ESCAPE: cancel()
					elif event.keycode in [KEY_ENTER, KEY_KP_ENTER]:
						if modal.can_confirm(): _finish(true)
					elif not (event.ctrl_pressed or event.alt_pressed or event.meta_pressed) and event.keycode in [KEY_X, KEY_Y, KEY_Z] and modal.kind != KeyboardTransform.Kind.AIM:
						var next := [KEY_X, KEY_Y, KEY_Z].find(event.keycode)
						axis = -1 if axis == next else next
						modal.axis = axis
						drag(modal.pointer)
				return true
			if event is InputEventMouseButton:
				if event.pressed:
					if event.button_index == MOUSE_BUTTON_LEFT:
						drag(event.position)
						if modal.can_confirm(): _finish(true)
					elif event.button_index == MOUSE_BUTTON_RIGHT: cancel()
				return true
		if event is InputEventMouseMotion:
			drag(event.position); return true
		if event is InputEventMouseButton:
			if event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
				drag(event.position); _finish(true)
			elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed: cancel()
			return true
	elif event is InputEventMouseMotion:
		var next := hit(event.position)
		if hover != next: hover = next; view.queue_redraw()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if begin(event.position, hit(event.position)):
			view.grab_focus(); return true
	return false

func draw() -> void:
	if path.is_empty(): return
	if light: light_guide.draw(view, world, extent())
	var pivot: Vector2 = view._project(world.origin)
	if not pivot.is_finite(): return
	var display_mode: int = mode if modal == null else modal.kind
	if modal != null:
		if axis >= 0:
			view._line(original.origin - AXES[axis] * extent() * 100, original.origin + AXES[axis] * extent() * 100, COLORS[axis])
		if modal.kind == KeyboardTransform.Kind.AIM and modal.has_target:
			view._line(world.origin, modal.target, LightGuide.DIRECTION, 1.5)
			var point: Vector2 = view._project(modal.target)
			if point.is_finite(): view.draw_circle(point, 6, LightGuide.DIRECTION, false, 1.5, true)
		elif modal.kind in [KeyboardTransform.Kind.ROTATE, KeyboardTransform.Kind.SCALE]:
			view.draw_dashed_line(pivot, modal.pointer, Color("b2bcc4"), 1, 5, true)
	for i in range(3):
		var highlighted: bool = not view.mouse_captured and (axis == i if active else hover == i)
		var color: Color = Color.WHITE if highlighted else COLORS[i]
		if display_mode == 1:
			var points := circle(i, extent())
			for j in range(points.size() - 1): view._line(world.origin + points[j], world.origin + points[j + 1], color)
		else:
			var end: Vector2 = view._project(world.origin + AXES[i] * extent())
			if not end.is_finite(): continue
			view.draw_line(pivot, end, color, 2.5, true)
			var direction := (end - pivot).normalized()
			var side := Vector2(-direction.y, direction.x)
			if display_mode == KeyboardTransform.Kind.SCALE:
				view.draw_rect(Rect2(end - Vector2(4, 4), Vector2(8, 8)), color)
			else:
				view.draw_colored_polygon(PackedVector2Array([end, end - direction * 11 + side * 4, end - direction * 11 - side * 4]), color)
			view.draw_string(ThemeDB.fallback_font, end + Vector2(5, -4), ["X", "Y", "Z"][i], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, color)
	if display_mode == 0: view.draw_rect(Rect2(pivot - Vector2(4, 4), Vector2(8, 8)), Color.WHITE, false, 1.5)
