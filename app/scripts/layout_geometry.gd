extends RefCounted

# Geometry is prepared only when the USD snapshot changes. Repeated capture
# instances share both the GPU mesh and the lazily built picking BVH.
class Geometry:
	var surfaces: Array
	var mesh: ArrayMesh
	var triangles: TriangleMesh

	func _init(source: Array) -> void:
		surfaces = source
		var vertex_count := 0
		var index_count := 0
		for surface in surfaces:
			vertex_count += surface.vertices.size()
			index_count += surface.indices.size()
		var vertices := PackedVector3Array()
		var indices := PackedInt32Array()
		vertices.resize(vertex_count)
		indices.resize(index_count)
		var vertex_offset := 0
		var index_offset := 0
		for surface in surfaces:
			for i in range(surface.vertices.size()):
				var vertex: Array = surface.vertices[i]
				vertices[vertex_offset + i] = Vector3(vertex[0], vertex[1], vertex[2])
			for i in range(surface.indices.size()):
				indices[index_offset + i] = vertex_offset + int(surface.indices[i])
			vertex_offset += surface.vertices.size()
			index_offset += surface.indices.size()
		mesh = ArrayMesh.new()
		if index_count > 0:
			var arrays := []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = vertices
			arrays[Mesh.ARRAY_INDEX] = indices
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	func intersect_ray(origin: Vector3, direction: Vector3) -> Dictionary:
		if triangles == null:
			triangles = mesh.generate_triangle_mesh()
		return triangles.intersect_ray(origin, direction) if triangles != null else {}

class Entry:
	var id: String
	var source_path: String
	var transform: Transform3D
	var inverse: Transform3D
	var invertible: bool
	var bounds: AABB
	var geometry: Geometry

	func matches(path: String) -> bool:
		return not path.is_empty() and (id == path or id.begins_with(path + "/") or source_path == path or source_path.begins_with(path + "/"))

var entries: Array[Entry] = []

func rebuild(scene: Dictionary) -> void:
	entries.clear()
	var shared := {}
	for data in scene.get("meshes", []):
		var surfaces: Array = data.surfaces
		var key := hash(surfaces)
		var geometry: Geometry
		# Compare on hash hits as well, so a collision cannot substitute geometry.
		for candidate: Geometry in shared.get(key, []):
			if candidate.surfaces == surfaces:
				geometry = candidate
				break
		if geometry == null:
			geometry = Geometry.new(surfaces)
			if not shared.has(key):
				shared[key] = []
			shared[key].append(geometry)
		if geometry.mesh.get_surface_count() == 0:
			continue
		var entry := Entry.new()
		entry.id = data.id
		entry.source_path = data.get("source_path", data.id)
		var matrix: Array = data.transform
		entry.transform = Transform3D(Basis(Vector3(matrix[0], matrix[1], matrix[2]), Vector3(matrix[4], matrix[5], matrix[6]), Vector3(matrix[8], matrix[9], matrix[10])), Vector3(matrix[12], matrix[13], matrix[14]))
		var determinant := entry.transform.basis.determinant()
		entry.invertible = is_finite(determinant) and determinant != 0.0
		if entry.invertible:
			entry.inverse = entry.transform.affine_inverse()
		entry.geometry = geometry
		entry.bounds = entry.transform * geometry.mesh.get_aabb()
		entries.append(entry)

func pick(origin: Vector3, direction: Vector3) -> String:
	return raycast(origin, direction).get("path", "")

func raycast(origin: Vector3, direction: Vector3, exclude := "") -> Dictionary:
	var closest := INF
	var result := {}
	for entry in entries:
		if entry.matches(exclude) or not entry.invertible or entry.bounds.intersects_ray(origin, direction) == null:
			continue
		var local_direction := (entry.inverse.basis * direction).normalized()
		var hit := entry.geometry.intersect_ray(entry.inverse * origin, local_direction)
		if hit.is_empty():
			continue
		var position := entry.transform * Vector3(hit.position)
		var distance_squared := origin.distance_squared_to(position)
		if distance_squared < closest:
			closest = distance_squared
			var normal := (entry.inverse.basis.transposed() * Vector3(hit.normal)).normalized()
			# Pick the camera-facing side, including mirrored/double-sided geometry.
			if normal.dot(direction) > 0: normal = -normal
			result = {"path": entry.id, "position": position, "normal": normal}
	return result
