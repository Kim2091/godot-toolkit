extends SceneTree

var document: Object
var directory := ""
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		failures += 1

func request(data: Dictionary) -> Dictionary:
	var response: Dictionary = JSON.parse_string(document.execute(JSON.stringify(data)))
	check(response.get("ok", false), str(response))
	return response.get("result", {})

func load_dds(path: String) -> Image:
	var image := Image.new()
	if image.load_dds_from_buffer(FileAccess.get_file_as_bytes(path)) != OK:
		return null
	return image

func ingest(data: Dictionary) -> Dictionary:
	var started: Dictionary = JSON.parse_string(document.start_ingestion(JSON.stringify(data)))
	check(started.get("ok", false), str(started))
	if not started.get("ok", false):
		return {}
	var result: String = document.poll_ingestion()
	while result.is_empty():
		await process_frame
		result = document.poll_ingestion()
	var response: Dictionary = JSON.parse_string(result)
	check(response.get("ok", false), str(response))
	return response.get("result", {})

func _run() -> void:
	document = ClassDB.instantiate("RemixDocument")
	var root_path := ProjectSettings.globalize_path("res://").get_base_dir().get_base_dir()
	directory = root_path.path_join(".work/ingestion/" + str(Time.get_ticks_usec()))
	request({"op": "create", "capture": root_path.path_join("tests/fixtures/capture.usda"), "path": directory.path_join("project.usda")})
	var source := directory.path_join("source")
	DirAccess.make_dir_recursive_absolute(source)
	# FBX paths retain Windows separators even when the model is opened on Linux.
	var fbx_directory := source.path_join("fbx with spaces")
	DirAccess.make_dir_recursive_absolute(fbx_directory.path_join("Textures"))
	DirAccess.copy_absolute(root_path.path_join("tests/fixtures/textured_model.fbx"), fbx_directory.path_join("textured_model.fbx"))
	var fbx_color := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	fbx_color.fill(Color(0.8, 0.2, 0.1, 1))
	fbx_color.save_png(fbx_directory.path_join("Textures/color map.png"))
	var fbx_sources := [fbx_directory.path_join("textured_model.fbx")]
	# Optional real-world FBX files are read only; ingestion stays in this test project.
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--fbx="): fbx_sources.append(argument.trim_prefix("--fbx="))
	for fbx_source in fbx_sources:
		var fbx := await ingest({"source": fbx_source, "mdl_directory": root_path.path_join("app/materials")})
		if not fbx.has("asset"): continue
		request({"op": "add_mesh", "asset": fbx.asset})
		var fbx_scene := request({"op": "scene"})
		var texture_found := false
		for fbx_material in fbx_scene.materials:
			var texture_path: String = fbx_material.get("albedo_texture", "")
			if not texture_path.begins_with(String(fbx.asset).get_base_dir() + "/"): continue
			texture_found = true
			var texture := load_dds(texture_path)
			check(texture != null and texture.is_compressed() and texture.has_mipmaps() and texture.get_format() == Image.FORMAT_BPTC_RGBA,
				"FBX texture must resolve and become mipmapped BC7 DDS: " + fbx_source)
		check(texture_found, "FBX diffuse texture was lost: " + fbx_source)
		request({"op": "undo"})
	var colors := {"albedo": Color(0.8, 0.2, 0.1, 1), "normal": Color(0.5, 0.5, 1, 1), "orm": Color(1, 0.6, 0.25, 1)}
	for name in colors:
		var image := Image.create(16, 16, false, Image.FORMAT_RGBA8)
		image.fill(colors[name])
		image.save_png(source.path_join(name + ".png"))
	var material := await ingest({"source": source.path_join("albedo.png"), "material": true, "mdl_directory": root_path.path_join("app/materials")})
	check(material.has("asset"), "Material ingestion failed")
	if material.has("asset"):
		var copied := await ingest({"source": material.asset, "name": "material_copy"})
		check(copied.has("asset"), "USD material re-ingestion failed")
		check(FileAccess.file_exists(directory.path_join("assets/material_copy/materials_0/AperturePBR_Normal.mdl")), "USD ingestion must retain MDL sibling modules")
	var diffuse := load_dds(directory.path_join("assets/albedo/albedo.dds"))
	check(diffuse != null and diffuse.is_compressed() and diffuse.has_mipmaps() and diffuse.get_format() == Image.FORMAT_BPTC_RGBA, "Color image must become mipmapped BC7 DDS")
	var hdr := Image.create(16, 16, false, Image.FORMAT_RGBAF)
	hdr.fill(Color(4, 2, 1, 1))
	check(hdr.save_exr(source.path_join("emission.exr")) == OK, "Could not write HDR fixture")
	await ingest({"source": source.path_join("emission.exr"), "material": true, "texture_role": "emissive", "mdl_directory": root_path.path_join("app/materials")})
	var emission := load_dds(directory.path_join("assets/emission/emissive.dds"))
	check(emission != null and emission.has_mipmaps() and emission.get_format() == Image.FORMAT_BPTC_RGBFU, "HDR image must become mipmapped BC6H DDS")
	request({"op": "replace_material", "path": "/RootNode/instances/inst_0123456789ABCDEF_0/mesh", "asset": directory.path_join("assets/emission/asset.usda")})
	var emissive_scene := request({"op": "scene"})
	check(emissive_scene.materials[0].emissive_intensity > 0, "Ingested emissive material must enable emission in USD")
	var glass := await ingest({"source": source.path_join("albedo.png"), "name": "glass", "material": true, "properties": {"kind": "translucent", "ior": 1.45}, "mdl_directory": root_path.path_join("app/materials")})
	request({"op": "replace_material", "path": "/RootNode/instances/inst_0123456789ABCDEF_0/mesh", "asset": glass.asset})
	var glass_scene := request({"op": "scene"})
	check(glass_scene.materials[0].kind == "translucent" and absf(glass_scene.materials[0].ior - 1.45) < 0.001 and not glass_scene.materials[0].albedo_texture.is_empty(), "Glass must preserve its IOR and transmittance texture")
	var packed := PackedFloat32Array([-1, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0.5, 1]).to_byte_array()
	packed.append_array(PackedByteArray([0, 0, 1, 0, 2, 0]))
	var gltf := {
		"asset": {"version": "2.0"}, "scene": 0, "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 0}],
		"buffers": [{"uri": "data:application/octet-stream;base64," + Marshalls.raw_to_base64(packed), "byteLength": packed.size()}],
		"bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": 36}, {"buffer": 0, "byteOffset": 36, "byteLength": 36}, {"buffer": 0, "byteOffset": 72, "byteLength": 24}, {"buffer": 0, "byteOffset": 96, "byteLength": 6}],
		"accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3", "min": [-1, 0, 0], "max": [1, 1, 0]}, {"bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC3"}, {"bufferView": 2, "componentType": 5126, "count": 3, "type": "VEC2"}, {"bufferView": 3, "componentType": 5123, "count": 3, "type": "SCALAR"}],
		"images": [{"uri": "albedo.png"}, {"uri": "normal.png"}, {"uri": "orm.png"}], "textures": [{"source": 0}, {"source": 1}, {"source": 2}],
		"materials": [{"alphaMode": "MASK", "alphaCutoff": 0.4, "pbrMetallicRoughness": {"baseColorTexture": {"index": 0}, "metallicRoughnessTexture": {"index": 2}}, "normalTexture": {"index": 1}}],
		"meshes": [{"primitives": [{"attributes": {"POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2}, "indices": 3, "material": 0}]}]
	}
	var file := FileAccess.open(source.path_join("triangle.gltf"), FileAccess.WRITE)
	file.store_string(JSON.stringify(gltf)); file.close()
	var mesh := await ingest({"source": source.path_join("triangle.gltf"), "mdl_directory": root_path.path_join("app/materials")})
	if mesh.has("asset"):
		for name in ["normal", "roughness", "metallic"]:
			var texture := load_dds(directory.path_join("assets/triangle/texture_0_" + name + "_texture.dds"))
			check(texture != null and texture.is_compressed() and texture.has_mipmaps(), name + " texture conversion failed")
			if texture == null:
				continue
			check(texture.get_format() == (Image.FORMAT_RGTC_RG if name == "normal" else Image.FORMAT_RGTC_R), "Unexpected DDS format for " + name)
			texture.decompress()
			var expected: float = 0.5 if name == "normal" else 0.6 if name == "roughness" else 0.25
			check(absf(texture.get_pixel(4, 4).r - expected) < 0.04, "Wrong texture channel or normal encoding for " + name)
		request({"op": "add_mesh", "path": "/RootNode/instances/inst_0123456789ABCDEF_0", "asset": mesh.asset})
		var composed := request({"op": "scene"})
		check(composed.materials.any(func(value: Dictionary): return value.alpha_test == 6 and value.alpha_reference == 102), "glTF cutout threshold must reach the renderer")
		gltf.materials[0].alphaMode = "BLEND"
		file = FileAccess.open(source.path_join("blend.gltf"), FileAccess.WRITE)
		file.store_string(JSON.stringify(gltf)); file.close()
		var blended := await ingest({"source": source.path_join("blend.gltf"), "mdl_directory": root_path.path_join("app/materials")})
		if blended.has("asset"):
			request({"op": "add_mesh", "asset": blended.asset})
			composed = request({"op": "scene"})
			check(composed.materials.any(func(value: Dictionary): return value.blend_enabled and not value.use_legacy_alpha and value.blend_type == 0 and value.alpha_test == 7), "glTF BLEND must author explicit alpha blending")
			check(blended.get("warnings", []).is_empty(), "glTF BLEND should no longer report unsupported transparency")
		request({"op": "package", "path": directory.path_join("package")})
		check(FileAccess.file_exists(directory.path_join("package/mod.usda")), "Material dependencies did not package")
	print("Ingestion workflow: " + str(failures) + " failures; artifacts: " + directory)
	quit(0 if failures == 0 else 1)
