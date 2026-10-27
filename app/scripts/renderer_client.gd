extends Node

const PROTOCOL_VERSION := 3
const MAX_FRAME_BYTES := 64 * 1024 * 1024
const MORE_FRAMES := 0x80000000
const JsonStream = preload("res://scripts/json_stream.gd")

signal status_changed(message: String)
signal response_received(response: Dictionary)
signal texture_ready(texture: Texture2D)
signal frame_presented(context: Dictionary)

var process: Dictionary = {}
var incoming := PackedByteArray()
var messages: Array[Dictionary] = []
var writer: Thread
var mutex := Mutex.new()
var stopping := false
var next_id := 0
var frame_pending := false
var is_ready := false
var is_starting := false
var gpu: Object
var log_reader: Thread
var shared_frames := false
var last_log := ""
var generation := 0
var presented_context: Dictionary = {}
var copy_context: Dictionary = {}
var frame_texture: Texture2D
var capabilities: Dictionary = {}
var effective_settings: Dictionary = {}
var renderer_id := "remix"
var output_size := Vector2i(960, 540)

func start_worker(executable: String, library: String, render_settings: Dictionary = {}, selected_renderer := "remix") -> void:
	stop_worker()
	renderer_id = selected_renderer
	capabilities = {}
	effective_settings = {}
	output_size = Vector2i(int(render_settings.get("width", 960)), int(render_settings.get("height", 540)))
	is_starting = true
	process = OS.execute_with_pipe(executable, [], true)
	if process.is_empty():
		is_starting = false
		status_changed.emit("Could not start the renderer worker.")
		return
	stopping = false
	if gpu == null:
		gpu = ClassDB.instantiate("RemixGpuBridge")
		gpu.configured.connect(func(texture: Texture2D):
			frame_texture = texture
			texture_ready.emit(texture)
			is_ready = true
			is_starting = false
			status_changed.emit("%s viewport ready" % ("OpenRemix" if renderer_id == "openremix" else "Remix")))
		gpu.frame_copied.connect(_frame_copied)
		gpu.failed.connect(func(message: String):
			is_ready = false
			is_starting = false
			status_changed.emit(message))
	var endpoint: String = gpu.open_channel()
	shared_frames = not endpoint.is_empty()
	writer = Thread.new()
	writer.start(_exchange_loop.bind(generation))
	log_reader = Thread.new()
	log_reader.start(_read_log)
	var start := {"op": "start", "library": library, "renderer": renderer_id, "width": output_size.x, "height": output_size.y}
	if not render_settings.is_empty(): start["render_settings"] = render_settings.duplicate(true)
	if shared_frames:
		start["frame_channel"] = endpoint
	send(start)
	status_changed.emit("Starting %s…" % ("OpenRemix" if renderer_id == "openremix" else "Remix"))

func send(message: Dictionary) -> void:
	if process.is_empty():
		return
	mutex.lock()
	next_id += 1
	message["id"] = next_id
	message["version"] = PROTOCOL_VERSION
	if message.get("op") in ["scene", "lights", "camera", "preview_transform", "render_settings"]:
		for i in range(messages.size() - 1, -1, -1):
			var same: bool = messages[i].get("op") == message.op
			if message.op == "preview_transform": same = same and messages[i].get("path") == message.path
			if same or (message.op == "scene" and messages[i].get("op") in ["preview_transform", "lights"]):
				messages.remove_at(i)
	messages.append(message)
	mutex.unlock()

func _read_exact(pipe: FileAccess, length: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	while bytes.size() < length:
		# Pipe reads may return fewer bytes than requested, even in blocking mode.
		var part := pipe.get_buffer(mini(length - bytes.size(), 64 * 1024))
		if part.is_empty():
			break
		bytes.append_array(part)
	return bytes

func _exchange_loop(worker_generation: int) -> void:
	var applied := {"revision": -1, "camera": {}}
	var pipe: FileAccess = process["stdio"]
	while true:
		mutex.lock()
		var stop := stopping
		var message: Dictionary = messages.pop_front() if not messages.is_empty() else {}
		mutex.unlock()
		if stop:
			break
		if message.is_empty():
			OS.delay_msec(4)
			continue
		# Serialize scenes incrementally so Godot's String limit never applies.
		# Packed geometry travels as binary frames after the JSON text.
		if not JsonStream.new().write(pipe, message, MAX_FRAME_BYTES, _is_stopping):
			if not _is_stopping():
				_deliver.call_deferred({"ok": false, "error": "Renderer disconnected during transfer. Unsaved document edits are retained."}, worker_generation)
			return
		pipe.flush()
		var bytes := PackedByteArray()
		while true:
			var header := _read_exact(pipe, 4)
			if header.size() != 4:
				_deliver.call_deferred({"ok": false, "error": "Renderer disconnected. Unsaved document edits are retained."}, worker_generation)
				return
			var flags := header.decode_u32(0)
			var length := flags & ~MORE_FRAMES
			if length <= 0 or length > MAX_FRAME_BYTES:
				_deliver.call_deferred({"ok": false, "error": "Renderer disconnected or sent an invalid frame. Unsaved document edits are retained."}, worker_generation)
				return
			var chunk := _read_exact(pipe, length)
			if chunk.size() != length:
				_deliver.call_deferred({"ok": false, "error": "Renderer response was truncated."}, worker_generation)
				return
			bytes.append_array(chunk)
			if (flags & MORE_FRAMES) == 0:
				break
		var decoded = JSON.parse_string(bytes.get_string_from_utf8())
		if not decoded is Dictionary or decoded.get("version", 0) != PROTOCOL_VERSION:
			_deliver.call_deferred({"ok": false, "error": "Invalid renderer response."}, worker_generation)
			break
		if decoded.get("ok", false):
			if message.op == "scene":
				applied.revision = message.scene.get("revision", -1)
			elif message.op == "lights":
				applied.revision = decoded.get("result", {}).get("revision", applied.revision)
			elif message.op == "camera":
				applied.camera = message.camera.duplicate(true)
			elif message.op == "frame":
				decoded["view_context"] = applied.duplicate(true)
		decoded["request_op"] = message["op"]
		_deliver.call_deferred(decoded, worker_generation)

func _is_stopping() -> bool:
	mutex.lock()
	var result := stopping
	mutex.unlock()
	return result

func _deliver(response: Dictionary, worker_generation: int) -> void:
	if worker_generation != generation:
		return
	if not response.get("ok", false):
		is_ready = false
		is_starting = false
		frame_pending = false
		status_changed.emit(response.get("error", "Renderer failed."))
	elif response.get("request_op") == "start":
		capabilities = response.get("result", {}).get("capabilities", {})
		effective_settings = response.get("result", {}).get("render_settings", {})
		if shared_frames:
			gpu.import_frame()
		else:
			is_ready = true
			is_starting = false
			status_changed.emit("Renderer preview running in its native window")
	elif response.get("request_op") == "render_settings":
		effective_settings = response.get("result", {})
	elif response.get("request_op") == "frame":
		if response.get("result", {}).has("render_settings"):
			effective_settings = response.result.render_settings
		if shared_frames and response.get("result", {}).get("status") == "presented":
			copy_context = response.get("view_context", {}).duplicate(true)
			gpu.copy_frame()
		else:
			frame_pending = false
		if response.get("result", {}).get("status") == "closed":
			is_ready = false
			status_changed.emit("Renderer preview closed")
	response_received.emit(response)

func _frame_copied() -> void:
	if copy_context.is_empty():
		return
	presented_context = copy_context
	copy_context = {}
	frame_pending = false
	frame_presented.emit(presented_context)

func _read_log() -> void:
	var pipe: FileAccess = process["stderr"]
	var file := FileAccess.open("user://renderer.log", FileAccess.WRITE)
	while true:
		var bytes := pipe.get_buffer(4096)
		if bytes.is_empty():
			break
		if file != null:
			file.store_buffer(bytes)
			file.flush()

func _process(_delta: float) -> void:
	if is_ready and not frame_pending:
		frame_pending = true
		send({"op": "frame"})

func stop_worker() -> void:
	generation += 1
	is_ready = false
	is_starting = false
	effective_settings = {}
	mutex.lock()
	stopping = true
	messages.clear()
	mutex.unlock()
	if not process.is_empty() and OS.is_process_running(process["pid"]):
		OS.kill(process["pid"])
	if writer != null and writer.is_started():
		writer.wait_to_finish()
	if log_reader != null and log_reader.is_started():
		log_reader.wait_to_finish()
	writer = null
	log_reader = null
	if gpu != null:
		gpu.close_frame()
	frame_texture = null; presented_context = {}; copy_context = {}
	texture_ready.emit(null)
	process.clear()
	frame_pending = false

func _exit_tree() -> void:
	stop_worker()
