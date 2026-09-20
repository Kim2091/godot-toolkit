extends RefCounted

const SHAPE := Color("edca79")
const DIRECTION := Color("ffe8ab")
const SOFT_EDGE := Color("a68e60")
const AXES := [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
var type := ""
var radius := 0.0
var width := 1.0
var height := 1.0
var length := 1.0
var cone := 180.0
var softness := 0.0
var angle := 0.53

func configure(details: Dictionary) -> void:
	var properties := {}
	for property: Dictionary in details.get("properties", []):
		properties[property.name] = property.value
	type = details.get("authoring", {}).get("light_type", "SphereLight")
	radius = maxf(float(properties.get("inputs:radius", 0.5)), 0)
	width = maxf(float(properties.get("inputs:width", 1)), 0)
	height = maxf(float(properties.get("inputs:height", 1)), 0)
	length = maxf(float(properties.get("inputs:length", 1)), 0)
	cone = clampf(float(properties.get("inputs:shaping:cone:angle", 35 if type == "SpotLight" else 180)), 0, 180)
	softness = clampf(float(properties.get("inputs:shaping:cone:softness", 0)), 0, 1)
	angle = clampf(float(properties.get("inputs:angle", 0.53)), 0, 180)

func _path(paths: Array, points: PackedVector3Array, color := SHAPE) -> void:
	paths.append({"points": points, "color": color})

func _ring(paths: Array, axis: int, size: float, center := Vector3.ZERO, color := SHAPE) -> void:
	var points := PackedVector3Array()
	for i in range(65):
		var theta := TAU * i / 64.0
		points.append(center + (AXES[(axis + 1) % 3] * cos(theta) + AXES[(axis + 2) % 3] * sin(theta)) * size)
	_path(paths, points, color)

func _arrow(paths: Array, start: Vector3, end: Vector3, side := Vector3.RIGHT) -> void:
	var delta := end - start
	var head := delta.length() * 0.18
	var neck := end - delta.normalized() * head
	_path(paths, PackedVector3Array([start, end]), DIRECTION)
	_path(paths, PackedVector3Array([neck + side * head * 0.5, end, neck - side * head * 0.5]), DIRECTION)

func _cone(paths: Array, half_angle: float, reach: float, color: Color) -> void:
	# USD cone angle is measured from local -Z. A spherical cap keeps wide
	# cones (including 90 degrees) finite without distorting their angle.
	var theta := deg_to_rad(half_angle)
	var center := Vector3.FORWARD * cos(theta) * reach
	var rim := sin(theta) * reach
	_ring(paths, 2, rim, center, color)
	for direction in [Vector3.RIGHT, Vector3.UP, Vector3.LEFT, Vector3.DOWN]:
		_path(paths, PackedVector3Array([Vector3.ZERO, center + direction * rim]), color)

func paths(guide_size: float) -> Array:
	var result: Array = []
	var reach := maxf(radius * 2.5, guide_size * 1.8)
	match type:
		"SphereLight", "SpotLight":
			for axis in range(3): _ring(result, axis, radius)
		"RectLight":
			var x := width * 0.5
			var y := height * 0.5
			_path(result, PackedVector3Array([Vector3(-x, -y, 0), Vector3(x, -y, 0), Vector3(x, y, 0), Vector3(-x, y, 0), Vector3(-x, -y, 0)]))
			reach = maxf(maxf(x, y) * 2, guide_size * 1.8)
		"DiskLight":
			_ring(result, 2, radius)
		"CylinderLight":
			# USD cylinders extend along local X and emit around the YZ ring.
			for x in [-length * 0.5, length * 0.5]: _ring(result, 0, radius, Vector3(x, 0, 0))
			for direction in [Vector3.UP, Vector3.DOWN, Vector3.BACK, Vector3.FORWARD]:
				_path(result, PackedVector3Array([Vector3.LEFT * length * 0.5 + direction * radius, Vector3.RIGHT * length * 0.5 + direction * radius]))
				_arrow(result, direction * radius, direction * (radius + guide_size * 0.65), Vector3.RIGHT)
		"DistantLight":
			# A directional light has no physical radius: use a small parallel-ray
			# symbol, with the angular diameter shown around its centre ray.
			var size := guide_size * 0.5
			for x in [-size, 0.0, size]: _arrow(result, Vector3(x, 0, 0), Vector3(x, 0, -guide_size * 1.8))
			_ring(result, 2, size)
			_cone(result, angle * 0.5, guide_size * 1.8, SOFT_EDGE)
		"DomeLight":
			# Environment lights have no finite emitter. Meridians and a north
			# arrow show the environment's orientation at a readable display size.
			for axis in range(3): _ring(result, axis, guide_size * 0.65)
			_arrow(result, Vector3.ZERO, Vector3.UP * guide_size)
	if type in ["SphereLight", "SpotLight", "RectLight", "DiskLight"]:
		if cone < 180:
			_cone(result, cone, reach, SHAPE)
			if softness > 0:
				# Match Remix's falloff in cosine space.
				var inner := rad_to_deg(acos(clampf(cos(deg_to_rad(cone)) + softness, -1, 1)))
				_cone(result, inner, reach, SOFT_EDGE)
		if cone < 180 or type in ["RectLight", "DiskLight"]:
			_arrow(result, Vector3.ZERO, Vector3.FORWARD * reach)
	return result

func draw(view: Control, world: Transform3D, extent: float) -> void:
	var scale := maxf(world.basis.x.length(), maxf(world.basis.y.length(), world.basis.z.length()))
	for line: Dictionary in paths(extent / maxf(scale, 0.00001)):
		var points: PackedVector3Array = line.points
		for i in range(points.size() - 1):
			view._line(world * points[i], world * points[i + 1], line.color, 1.5)
