extends RefCounted

const BONE := Color("90dbf5")
const ROOT := Color("ffd28a")
const OUTLINE := Color("09121c")
var rigs: Dictionary = {}
var bindings: Array[Dictionary] = []
var selected: Array[String] = []
var preview_path := ""
var preview_delta := Transform3D.IDENTITY

func configure(scene: Dictionary) -> void:
	rigs.clear(); bindings.clear(); selected.clear()
	preview_path = ""; preview_delta = Transform3D.IDENTITY
	for id: String in scene.get("skeletons", {}):
		var source: Dictionary = scene.skeletons[id]
		var points := PackedVector3Array()
		for position: Array in source.positions:
			points.append(Vector3(position[0], position[1], position[2]))
		rigs[id] = {"points": points, "parents": source.parents}
	for mesh: Dictionary in scene.get("meshes", []):
		var skeleton: String = mesh.get("skeleton", "")
		if rigs.has(skeleton):
			bindings.append({"path": mesh.id, "source": mesh.get("source_path", mesh.id), "skeleton": skeleton})

func _within(path: String, parent: String) -> bool:
	return not parent.is_empty() and (path == parent or path.begins_with(parent + "/"))

func select(path: String) -> void:
	selected.clear()
	if path.is_empty(): return
	var seen := {}
	for binding in bindings:
		if _within(binding.path, path) or _within(binding.source, path) or binding.skeleton == path:
			seen[binding.skeleton] = true
	for id: String in seen: selected.append(id)

func preview(path: String, delta: Transform3D) -> void:
	preview_path = path
	preview_delta = delta

func _transform(id: String) -> Transform3D:
	if _within(id, preview_path): return preview_delta
	for binding in bindings:
		if binding.skeleton == id and _within(binding.path, preview_path): return preview_delta
	return Transform3D.IDENTITY

func _clip_segment(points: PackedVector2Array, rectangle: Rect2) -> PackedVector2Array:
	# Clip to the image rectangle as well as the near plane, including Remix's
	# letterboxing. Flying through a rig must not draw huge lines over the UI.
	if points.size() != 2 or not points[0].is_finite() or not points[1].is_finite():
		return PackedVector2Array()
	var a := points[0]
	var delta := points[1] - a
	var low := 0.0
	var high := 1.0
	for axis in range(2):
		if absf(delta[axis]) < 0.000001:
			if a[axis] < rectangle.position[axis] or a[axis] > rectangle.end[axis]:
				return PackedVector2Array()
			continue
		var enter := (rectangle.position[axis] - a[axis]) / delta[axis]
		var leave := (rectangle.end[axis] - a[axis]) / delta[axis]
		low = maxf(low, minf(enter, leave))
		high = minf(high, maxf(enter, leave))
		if low > high: return PackedVector2Array()
	return PackedVector2Array([a + delta * low, a + delta * high])

func projected(view: Control) -> Dictionary:
	var lines := PackedVector2Array()
	var joints := PackedVector2Array()
	var roots := PackedVector2Array()
	var rectangle: Rect2 = view._view_rect()
	if rectangle.size.x < 10 or rectangle.size.y < 10:
		return {"lines": lines, "joints": joints, "roots": roots}
	for id in selected:
		var rig: Dictionary = rigs[id]
		var transform := _transform(id)
		for i in range(rig.points.size()):
			var position: Vector3 = transform * rig.points[i]
			var parent: int = rig.parents[i]
			if parent >= 0 and parent < rig.points.size() and parent != i:
				lines.append_array(_clip_segment(view._project_segment(transform * rig.points[parent], position), rectangle.grow(-2.5)))
			var point: Vector2 = view._project(position)
			if point.is_finite() and rectangle.grow(-4.5).has_point(point):
				if parent < 0: roots.append(point)
				else: joints.append(point)
	return {"lines": lines, "joints": joints, "roots": roots}

func draw(view: Control) -> void:
	if selected.is_empty(): return
	var overlay := projected(view)
	if not overlay.lines.is_empty():
		view.draw_multiline(overlay.lines, OUTLINE, 4.5, true)
		view.draw_multiline(overlay.lines, BONE, 1.5, true)
	for point: Vector2 in overlay.joints:
		view.draw_circle(point, 3.5, OUTLINE, true, -1, true)
		view.draw_circle(point, 2.0, BONE, true, -1, true)
	for point: Vector2 in overlay.roots:
		view.draw_circle(point, 4.5, OUTLINE, true, -1, true)
		view.draw_circle(point, 3.0, ROOT, true, -1, true)
