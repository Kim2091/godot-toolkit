extends SceneTree

const Stream = preload("res://scripts/json_stream.gd")
const Client = preload("res://scripts/renderer_client.gd")
const Sessions = preload("res://scripts/project_sessions.gd")
const Geometry = preload("res://scripts/layout_geometry.gd")
class FailedScene extends RefCounted:
	func execute_data(_request: String) -> Dictionary:
		return {"ok": false, "error": "Simulated scene failure"}
	func start_asset_preview(_path: String) -> String:
		return '{"ok":false,"error":"Preview disabled"}'
	func cancel_asset_preview() -> void: pass

var failures := 0
var directory := ""

func check(ok: bool, message: String) -> void:
	if not ok: push_error(message); failures += 1

func _initialize() -> void: run.call_deferred()

func roundtrip(message: Dictionary, limit: int) -> void:
	var path := directory.path_join("framed.bin")
	var file := FileAccess.open(path, FileAccess.WRITE_READ)
	check(Stream.new().write(file, message, limit), "Stream writer must succeed")
	file.seek(0)
	var bytes := PackedByteArray()
	while file.get_position() < file.get_length():
		var flags := file.get_32()
		var count := flags & ~Stream.MORE_FRAMES
		check(count > 0 and count <= limit, "Frame length must be bounded and nonzero")
		bytes.append_array(file.get_buffer(count))
		check(bool(flags & Stream.MORE_FRAMES) == (file.get_position() < file.get_length()), "Only the final frame may end the message")
	var json := JSON.new()
	check(json.parse(bytes.get_string_from_utf8()) == OK, "Fragmented payload must be valid UTF-8 JSON")
	check(json.data == JSON.parse_string(JSON.stringify(message)), "All scene values must survive fragmentation")

func run() -> void:
	directory = ProjectSettings.globalize_path("res://../.work/large-scene/%d" % Time.get_ticks_usec()).simplify_path()
	DirAccess.make_dir_recursive_absolute(directory)
	var vertices: Array = []
	for i in 9000: vertices.append([float(i), -2.25, 0.0, 0.0, 1.0, 0.0, null, 0.125])
	var value := {"meshes": [{"id": "/mesh_材🌲", "surfaces": [{"vertices": vertices, "indices": [0,1,2], "colors": [4294967295,0,16777215]}]}], "empty": [], "object": {}, "bool": true, "null": null}
	roundtrip({"empty": []}, 1)
	roundtrip({"x": 1}, 7) # Exactly one full frame must still have a terminator.
	roundtrip({"text": "a\"\\\n\\u0000材🌲", "values": [true, false, null, -2.5]}, 3)
	roundtrip(value, 8192)
	var canceled_file := FileAccess.open(directory.path_join("canceled.bin"), FileAccess.WRITE)
	check(not Stream.new().write(canceled_file, value, 32, func(): return true), "Cancellation must stop a partial upload")
	check(canceled_file.get_length() == 0, "A canceled upload must not emit an empty complete message")
	var doc: Object = ClassDB.instantiate("RemixDocument")
	var project := directory.path_join("scène_材/work.usda")
	var created: Dictionary = doc.execute_data(JSON.stringify({"op": "create", "capture": ProjectSettings.globalize_path("res://../tests/fixtures/capture.usda"), "path": project}))
	check(created.get("ok", false) and created.result.document.path == project, "Direct bridge must preserve Unicode paths")
	var response: Dictionary = doc.execute_data('{"op":"scene"}')
	check(response.get("ok", false) and response.result.meshes.size() == 2, "Direct scene result must contain all meshes")
	var old_response = JSON.parse_string(doc.execute('{"op":"scene"}'))
	check(response.result == old_response.result, "Direct scene transfer must preserve the existing data contract")
	check(not doc.execute_data('{"op":"invalid"}').get("ok", true), "Native exceptions must remain structured errors")

	# Exercise the UI's reported failure path without losing the USD document or
	# sending an empty scene after an unsuccessful native response.
	var app: Control = load("res://main.tscn").instantiate()
	app.sessions = Sessions.new(directory.path_join("recent.json"))
	root.add_child(app); app.render_toggle.button_pressed = false
	app._open_project(project)
	var actual_document: Object = app.document
	app.document = FailedScene.new()
	app._refresh(true)
	check(app.last_scene.is_empty() and app.viewport.scene.is_empty() and app.renderer.process.is_empty(), "Failed scene load must clear stale viewport state and stop rendering")
	check(app.state.get("open", false) and app.output.get_parsed_text().contains("Simulated scene failure"), "Failed scene load must retain the project and report the actual error")
	app.document = actual_document
	app._refresh(true)
	check(app.last_scene.meshes.size() == 2, "Scene loading must recover after a failed response")
	app.queue_free(); await process_frame

	# Optional read-only regression against a real large project. The worker
	# parses the entire streamed scene without needing to allocate GPU geometry.
	for arg in OS.get_cmdline_user_args():
		if not arg.begins_with("--project="): continue
		var path := arg.trim_prefix("--project=")
		check(doc.execute_data(JSON.stringify({"op": "open", "path": path})).get("ok", false), "Large project must open")
		print("Loading large scene: ", path)
		var start := Time.get_ticks_msec()
		response = doc.execute_data('{"op":"scene"}')
		check(response.get("ok", false), "Large scene must cross the native bridge")
		if not response.get("ok", false): continue
		var scene: Dictionary = response.result
		print("Loaded ", scene.meshes.size(), " meshes in ", (Time.get_ticks_msec() - start) / 1000.0, "s")
		var geometry := Geometry.new()
		geometry.rebuild(scene)
		check(geometry.entries.size() == scene.meshes.size(), "Large scene must build viewport geometry")
		print("Built layout geometry: ", geometry.entries.size(), " instances")
		var client := Client.new(); root.add_child(client); client.set_process(false)
		client.process = OS.execute_with_pipe(ProjectSettings.globalize_path("res://../build/remix-renderer"), [], true)
		var replies: Array = []
		client.response_received.connect(func(reply: Dictionary): replies.append(reply))
		client.writer = Thread.new(); client.writer.start(client._exchange_loop.bind(client.generation))
		client.send({"op": "large_scene_transport_probe", "scene": scene})
		client.send({"op": "hello"})
		var deadline := Time.get_ticks_msec() + 600000
		while replies.size() < 2 and Time.get_ticks_msec() < deadline: await process_frame
		check(replies.size() == 2, "Large scene upload and following message must both complete")
		if replies.size() == 2:
			check(replies[0].get("error", "") == "Unknown renderer operation: large_scene_transport_probe" and replies[1].get("ok", false), "Worker must parse the complete large scene and remain aligned")
		client.stop_worker(); client.queue_free()
		print("Large scene upload complete")
	print("Large scene bridge and streaming: %d failures" % failures)
	quit(1 if failures else 0)
