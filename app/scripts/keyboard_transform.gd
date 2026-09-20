extends RefCounted

enum Kind { MOVE, ROTATE, SCALE, AIM }
const AXES := [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
var kind := Kind.MOVE
var axis := -1
var original := Transform3D.IDENTITY
var initial_pointer := Vector2.ZERO
var pointer := Vector2.ZERO
var pivot := Vector2.ZERO
var camera_basis := Basis.IDENTITY
var units_per_pixel := 1.0
var target := Vector3.ZERO
var has_target := false
var value := ""
var degrees_text := ""

func can_confirm() -> bool:
	return degrees_text.is_empty() or (degrees_text.is_valid_float() and is_finite(degrees_text.to_float()))

func input_number(event: InputEventKey) -> bool:
	if kind != Kind.ROTATE or event.ctrl_pressed or event.alt_pressed or event.meta_pressed: return false
	if event.echo and event.keycode != KEY_BACKSPACE: return false
	if event.keycode == KEY_BACKSPACE:
		degrees_text = degrees_text.left(-1)
		return true
	var character := String.chr(event.unicode) if event.unicode > 0 else ""
	if event.keycode >= KEY_KP_0 and event.keycode <= KEY_KP_9:
		character = str(event.keycode - KEY_KP_0)
	elif character.is_empty():
		if event.keycode >= KEY_0 and event.keycode <= KEY_9: character = str(event.keycode - KEY_0)
		elif event.keycode in [KEY_MINUS, KEY_KP_SUBTRACT]: character = "-"
		elif event.keycode in [KEY_PLUS, KEY_KP_ADD]: character = "+"
		elif event.keycode in [KEY_PERIOD, KEY_KP_PERIOD, KEY_COMMA]: character = "."
	if character.length() == 1 and character in "0123456789":
		if degrees_text.length() < 16: degrees_text += character
	elif character == "-":
		degrees_text = degrees_text.trim_prefix("-") if degrees_text.begins_with("-") else "-" + degrees_text
	elif character == "+":
		degrees_text = degrees_text.trim_prefix("-")
	elif character in [".", ","]:
		if not degrees_text.contains("."):
			if degrees_text in ["", "-"]: degrees_text += "0"
			degrees_text += "."
	else: return false
	return true

func begin(view: Control, operation: int, pose: Transform3D, position: Vector2) -> void:
	kind = operation; original = pose; initial_pointer = position; pointer = position
	pivot = view._project(pose.origin)
	camera_basis = view._basis()
	var eye: Vector3 = view.center + camera_basis.z * view.distance
	var depth := (pose.origin - eye).dot(-camera_basis.z)
	units_per_pixel = maxf(depth, 0.001) * 2 * tan(deg_to_rad(30)) / maxf(view._view_rect().size.y, 1)

func update(view: Control, position: Vector2, path: String, previous: Transform3D) -> Transform3D:
	pointer = position
	var result := original
	var delta := pointer - initial_pointer
	match kind:
		Kind.MOVE:
			var movement := (camera_basis.x * delta.x - camera_basis.y * delta.y) * units_per_pixel
			if axis >= 0:
				var direction := Vector2(AXES[axis].dot(camera_basis.x), -AXES[axis].dot(camera_basis.y))
				# An axis pointing into the screen still needs a usable control.
				var amount := -delta.y * units_per_pixel if direction.length_squared() < 0.0025 else delta.dot(direction) * units_per_pixel / direction.length_squared()
				if view.snap: amount = snappedf(amount, 1.0)
				movement = AXES[axis] * amount
			elif view.snap: movement = movement.snapped(Vector3.ONE)
			result.origin += movement
			value = "%.3f units" % movement.length()
		Kind.ROTATE:
			var start := initial_pointer - pivot
			var end := pointer - pivot
			var radians := -start.angle_to(end) if start.length() >= 8 and end.length() >= 1 else delta.x * 0.01
			var normal: Vector3 = camera_basis.z if axis < 0 else AXES[axis]
			if not degrees_text.is_empty():
				if not can_confirm(): return previous
				# Explicit angles use the axis's positive direction regardless of
				# camera orientation, snapping, or subsequent pointer movement.
				radians = deg_to_rad(fmod(degrees_text.to_float(), 360.0))
			else:
				if normal.dot(camera_basis.z) < 0: radians = -radians
				if view.snap: radians = snappedf(radians, deg_to_rad(15))
			result.basis = Basis(normal, radians) * original.basis
			value = "%.1f°" % rad_to_deg(radians)
		Kind.SCALE:
			var start := initial_pointer - pivot
			var end := pointer - pivot
			var factor := exp(clampf((delta.x - delta.y) * 0.01, -6.9, 6.9))
			if start.length() >= 8:
				factor = end.length() / start.length()
				if start.dot(end) < 0: factor = -factor
			if view.snap: factor = snappedf(factor, 0.1)
			# Keep previews invertible when the pointer passes through the pivot.
			var minimum := minf(1, maxf(0.001, pow(1e-11 / absf(original.basis.determinant()), 1.0 / 3.0 if axis < 0 else 1.0)))
			factor = clampf(absf(factor), minimum, 1000) * (-1 if factor < 0 else 1)
			var factors: Vector3 = Vector3.ONE * factor if axis < 0 else Vector3.ONE + AXES[axis] * (factor - 1)
			result.basis = Basis.from_scale(factors) * original.basis
			value = "%.3f×" % factor
		Kind.AIM:
			var hit: Dictionary = view.surface_at(pointer, path)
			has_target = not hit.is_empty()
			if not has_target: return previous
			target = hit.position
			var direction := target - original.origin
			if direction.length_squared() < 1e-12: has_target = false; return previous
			var from := -original.basis.z.normalized()
			var to := direction.normalized()
			# Rotate the entire basis, retaining scale, shear, and the initial roll.
			var rotation := Basis(Quaternion(from, to))
			if from.dot(to) < -0.999999:
				rotation = Basis(from.cross(original.basis.x).normalized(), PI)
			result.basis = rotation * original.basis
	return result

func hint() -> String:
	var label: String = ["Move", "Rotate", "Scale", "Aim light"][kind]
	if kind == Kind.AIM:
		if not has_target: label += " · No surface under cursor"
	else:
		label += " · " + (["X", "Y", "Z"][axis] if axis >= 0 else "View plane" if kind == Kind.MOVE else "View axis" if kind == Kind.ROTATE else "Uniform")
		label += " · " + ("[" + degrees_text + "°]" if not degrees_text.is_empty() else value) + " · X/Y/Z: lock axis"
		if kind == Kind.ROTATE: label += " · Type degrees" if degrees_text.is_empty() else " · Backspace: edit"
	return label + " · Left click/Enter: confirm · Esc/right click: cancel"
