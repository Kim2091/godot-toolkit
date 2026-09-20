extends Node

signal preview_ready(id: String, texture: Texture2D, kind: String)
signal failed(id: String, message: String)
signal identified(id: String, kind: String)

const VERSION := 2
var provider: Object
var directory := ""
var generation := 0
var queue: Array[Dictionary] = []
var active: Dictionary = {}
var rendering := false
var render_job: Dictionary = {}
var textures: Dictionary = {}
var viewport: SubViewport
var world: Node3D
var content: Node3D
var camera: Camera3D

func _ready() -> void:
	if ClassDB.class_exists("RemixDocument"):
		provider = ClassDB.instantiate("RemixDocument")
	set_process(false)

func open_project(path: String) -> void:
	generation += 1
	directory = path
	queue.clear(); textures.clear()
	if provider != null:
		provider.cancel_asset_preview()
	set_process(not active.is_empty() or rendering)

func _cache_base(id: String) -> String:
	return directory.path_join("assets/.thumbnails/" + id.sha256_text())

func _stamp(path: String) -> Dictionary:
	# Native timestamps preserve subsecond edits without reading large texture files.
	var stamp: String = provider.asset_file_stamp(path)
	return {"path": path, "stamp": stamp} if not stamp.is_empty() else {}

func _cached(id: String) -> Dictionary:
	var base := _cache_base(id)
	if not FileAccess.file_exists(base + ".json") or not FileAccess.file_exists(base + ".png"):
		return {}
	var parser := JSON.new()
	if parser.parse(FileAccess.get_file_as_string(base + ".json")) != OK:
		return {}
	var metadata = parser.data
	if not metadata is Dictionary or metadata.get("version") != VERSION or not metadata.get("dependencies") is Array or metadata.dependencies.is_empty():
		return {}
	for dependency in metadata.dependencies:
		if not dependency is Dictionary or not dependency.get("path") is String or dependency.path.is_empty() or not dependency.get("stamp") is String or _stamp(dependency.path) != dependency:
			return {}
	return metadata

func request(id: String, retry := false) -> void:
	if provider == null or directory.is_empty():
		return
	if not retry:
		var metadata := _cached(id)
		if not metadata.is_empty():
			if not textures.has(id):
				var image := Image.load_from_file(_cache_base(id) + ".png")
				if image != null:
					textures[id] = ImageTexture.create_from_image(image)
			if textures.has(id):
				preview_ready.emit(id, textures[id], metadata.get("kind", "mesh"))
				return
	if rendering and render_job.get("id") == id and render_job.get("generation") == generation:
		return
	if active.get("id") == id and active.get("generation") == generation:
		return
	for item in queue:
		if item.id == id:
			return
	queue.append({"id": id, "path": directory.path_join(id), "generation": generation})
	set_process(true)

func prioritize(ids: Array) -> void:
	queue.sort_custom(func(a: Dictionary, b: Dictionary): return ids.has(a.id) and not ids.has(b.id))

func _process(_delta: float) -> void:
	if rendering or provider == null:
		return
	if active.is_empty():
		if queue.is_empty():
			set_process(false)
			return
		active = queue.pop_front()
		var response = JSON.parse_string(provider.start_asset_preview(active.path))
		if not response.get("ok", false):
			failed.emit(active.id, response.get("error", "Could not load asset"))
			active = {}
		return
	var text: String = provider.poll_asset_preview()
	if text.is_empty():
		return
	var job := active
	active = {}
	if job.generation != generation:
		return
	var response = JSON.parse_string(text)
	if not response.get("ok", false):
		failed.emit(job.id, response.get("error", "Could not load asset"))
		return
	identified.emit(job.id, response.result.kind)
	if DisplayServer.get_name() == "headless":
		failed.emit(job.id, "Thumbnail rendering requires a desktop session")
		return
	rendering = true
	render_job = job
	_render.call_deferred(job, response.result)

func _setup() -> void:
	if viewport != null:
		return
	viewport = SubViewport.new()
	viewport.size = Vector2i(256, 256)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	viewport.msaa_3d = Viewport.MSAA_4X
	add_child(viewport)
	world = Node3D.new()
	viewport.add_child(world)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color("202c38")
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color("b5c9e2")
	environment.environment.ambient_light_energy = 0.4
	world.add_child(environment)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, -35, 0)
	light.light_energy = 1.2
	world.add_child(light)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(25, 140, 0)
	fill.light_energy = 0.4
	world.add_child(fill)
	camera = Camera3D.new()
	camera.fov = 35
	world.add_child(camera)

func _texture(path: String, normal := false, encoding := 0) -> Texture2D:
	if path.is_empty() or not FileAccess.file_exists(path):
		return null
	var image := Image.new()
	var error := image.load_dds_from_buffer(FileAccess.get_file_as_bytes(path)) if path.get_extension().to_lower() == "dds" else image.load(path)
	if error != OK:
		return null
	if image == null or image.is_empty():
		return null
	if image.is_compressed() and image.decompress() != OK:
		return null
	image.clear_mipmaps()
	if maxi(image.get_width(), image.get_height()) > 512:
		var scale_factor := 512.0 / maxi(image.get_width(), image.get_height())
		image.resize(maxi(1, int(image.get_width() * scale_factor)), maxi(1, int(image.get_height() * scale_factor)))
	if normal:
		image.convert(Image.FORMAT_RGBA8)
		for y in range(image.get_height()):
			for x in range(image.get_width()):
				var pixel := image.get_pixel(x, y)
				if encoding == 0:
					var a := pixel.r * 2 - 1
					var b := pixel.g * 2 - 1
					var direction := Vector3((a + b) * 0.5, (a - b) * 0.5, 0)
					direction.z = 1 - absf(direction.x) - absf(direction.y)
					direction = direction.normalized()
					pixel = Color(direction.x * 0.5 + 0.5, -direction.y * 0.5 + 0.5, direction.z * 0.5 + 0.5)
				elif encoding == 2:
					pixel.g = 1 - pixel.g
				image.set_pixel(x, y, pixel)
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)

func _color(values: Array) -> Color:
	return Color(values[0], values[1], values[2])

func _material(data: Dictionary) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = _color(data.get("albedo", [0.7, 0.7, 0.7]))
	material.albedo_texture = _texture(data.get("albedo_texture", ""))
	if material.albedo_texture != null:
		material.albedo_color = Color.WHITE
	material.roughness = data.get("roughness", 0.5)
	material.roughness_texture = _texture(data.get("roughness_texture", ""))
	if material.roughness_texture != null:
		material.roughness = 1.0
	material.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	material.metallic = data.get("metallic", 0.0)
	material.metallic_texture = _texture(data.get("metallic_texture", ""))
	if material.metallic_texture != null:
		material.metallic = 1.0
	material.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	material.normal_texture = _texture(data.get("normal_texture", ""), true, data.get("normal_encoding", 0))
	material.normal_enabled = material.normal_texture != null
	material.emission_enabled = data.get("emissive_intensity", 0.0) > 0
	material.emission = _color(data.get("emissive", [0, 0, 0]))
	material.emission_texture = _texture(data.get("emissive_texture", ""))
	if material.emission_texture != null:
		material.emission = Color.WHITE
	material.emission_energy_multiplier = minf(data.get("emissive_intensity", 0.0), 8)
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS if data.get("filter_mode", 1) == 0 else BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	material.texture_repeat = data.get("wrap_mode_u", 1) != 0 or data.get("wrap_mode_v", 1) != 0
	if data.get("kind") == "translucent":
		material.albedo_color = _color(data.get("transmittance", [1, 1, 1]))
		material.albedo_color.a = 0.45
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.roughness = 0.1
	elif data.get("alpha_test", 7) != 7:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		material.alpha_scissor_threshold = data.get("alpha_reference", 128.0) / 255.0
	elif data.get("opacity", 1.0) < 1.0:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.albedo_color.a = data.opacity
	return material

func _mesh(data: Dictionary, materials: Dictionary) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	var mesh := ArrayMesh.new()
	for surface in data.surfaces:
		if surface.vertices.is_empty() or surface.indices.is_empty():
			continue
		var points := PackedVector3Array()
		var normals := PackedVector3Array()
		var uv := PackedVector2Array()
		for vertex in surface.vertices:
			points.append(Vector3(vertex[0], vertex[1], vertex[2]))
			normals.append(Vector3(vertex[3], vertex[4], vertex[5]))
			uv.append(Vector2(vertex[6], 1.0 - vertex[7]))
		var indices := PackedInt32Array(surface.indices)
		for i in range(0, indices.size(), 3):
			var swap := indices[i + 1]; indices[i + 1] = indices[i + 2]; indices[i + 2] = swap
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = points; arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_TEX_UV] = uv; arrays[Mesh.ARRAY_INDEX] = indices
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var material: StandardMaterial3D = materials.get(surface.material, StandardMaterial3D.new()).duplicate()
		if data.get("double_sided", false):
			material.cull_mode = BaseMaterial3D.CULL_DISABLED
		mesh.surface_set_material(mesh.get_surface_count() - 1, material)
	if mesh.get_surface_count() > 0:
		mesh.regen_normal_maps()
	instance.mesh = mesh
	var m: Array = data.transform
	instance.transform = Transform3D(Basis(Vector3(m[0], m[1], m[2]), Vector3(m[4], m[5], m[6]), Vector3(m[8], m[9], m[10])), Vector3(m[12], m[13], m[14]))
	return instance

func _render(job: Dictionary, data: Dictionary) -> void:
	_setup()
	if content != null:
		content.free()
	content = Node3D.new()
	world.add_child(content)
	var bounds := AABB()
	var have_bounds := false
	if data.kind == "material":
		var sphere := MeshInstance3D.new()
		sphere.mesh = SphereMesh.new()
		sphere.material_override = _material(data.material)
		content.add_child(sphere)
		bounds = sphere.get_aabb(); have_bounds = true
	else:
		var materials := {}
		for material in data.scene.materials:
			materials[material.id] = _material(material)
			await get_tree().process_frame
			if job.generation != generation:
				rendering = false; return
		var axis := Basis(Vector3.RIGHT, -PI / 2) if data.scene.get("up_axis", "Y") == "Z" else Basis.IDENTITY
		for entry in data.scene.meshes:
			var instance := _mesh(entry, materials)
			instance.transform = Transform3D(axis, Vector3.ZERO) * instance.transform
			content.add_child(instance)
			var box := instance.transform * instance.get_aabb()
			bounds = bounds.merge(box) if have_bounds else box
			have_bounds = true
			await get_tree().process_frame
			if job.generation != generation:
				rendering = false; return
	if not have_bounds:
		failed.emit(job.id, "No visible mesh to preview")
		rendering = false; return
	var radius := maxf(bounds.size.length() * 0.5, 0.01)
	camera.position = bounds.get_center() + Vector3(1.3, 0.9, 1.7).normalized() * radius * 3.6
	camera.near = maxf(radius * 0.001, 0.00001)
	camera.far = radius * 20
	camera.look_at(bounds.get_center())
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	for i in range(3):
		await RenderingServer.frame_post_draw
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if job.generation == generation:
		var image := viewport.get_texture().get_image()
		var base := _cache_base(job.id)
		DirAccess.make_dir_recursive_absolute(base.get_base_dir())
		var metadata := {"version": VERSION, "kind": data.kind, "dependencies": []}
		for dependency in data.dependencies:
			metadata.dependencies.append(_stamp(dependency.path))
		if image.save_png(base + ".png") == OK:
			var file := FileAccess.open(base + ".json", FileAccess.WRITE)
			if file != null:
				file.store_string(JSON.stringify(metadata))
		var texture := ImageTexture.create_from_image(image)
		textures[job.id] = texture
		preview_ready.emit(job.id, texture, data.kind)
	rendering = false
