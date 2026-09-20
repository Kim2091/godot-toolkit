extends Node

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

func start_worker(executable: String, library: String) -> void:
	stop_worker()
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
			status_changed.emit("Remix viewport ready"))
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
	var start := {"op": "start", "library": library, "width": 960, "height": 540}
	if shared_frames:
		start["frame_channel"] = endpoint
	send(start)
	status_changed.emit("Starting Remix…")

func send(message: Dictionary) -> void:
	if process.is_empty():
		return
	mutex.lock()
	next_id += 1
	message["id"] = next_id
	message["version"] = 1
	if message.get("op") in ["scene", "camera"]:
		for i in range(messages.size() - 1, -1, -1):
			if messages[i].get("op") == message.op:
				messages.remove_at(i)
	messages.append(message)
	mutex.unlock()

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
		var payload := JSON.stringify(message).to_utf8_buffer()
		if payload.size() > 64 * 1024 * 1024:
			_deliver.call_deferred({"ok": false, "error": "Scene exceeds the renderer message limit."}, worker_generation)
			continue
		pipe.store_32(payload.size())
		pipe.store_buffer(payload)
		pipe.flush()
		var length := pipe.get_32()
		if length <= 0 or length > 64 * 1024 * 1024:
			_deliver.call_deferred({"ok": false, "error": "Renderer disconnected. Unsaved document edits are retained."}, worker_generation)
			break
		var bytes := pipe.get_buffer(length)
		var decoded = JSON.parse_string(bytes.get_string_from_utf8())
		if not decoded is Dictionary:
			_deliver.call_deferred({"ok": false, "error": "Invalid renderer response."}, worker_generation)
			break
		if decoded.get("ok", false):
			if message.op == "scene":
				applied.revision = message.scene.get("revision", -1)
			elif message.op == "camera":
				applied.camera = message.camera.duplicate(true)
			elif message.op == "frame":
				decoded["view_context"] = applied.duplicate(true)
		decoded["request_op"] = message["op"]
		_deliver.call_deferred(decoded, worker_generation)

func _deliver(response: Dictionary, worker_generation: int) -> void:
	if worker_generation != generation:
		return
	if not response.get("ok", false):
		is_ready = false
		is_starting = false
		frame_pending = false
		status_changed.emit(response.get("error", "Renderer failed."))
	elif response.get("request_op") == "start":
		if shared_frames:
			gpu.import_frame()
		else:
			is_ready = true
			is_starting = false
			status_changed.emit("Remix preview running in its native window")
	elif response.get("request_op") == "frame":
		if shared_frames and response.get("result", {}).get("status") == "presented":
			copy_context = response.get("view_context", {}).duplicate(true)
			gpu.copy_frame()
		else:
			frame_pending = false
		if response.get("result", {}).get("status") == "closed":
			is_ready = false
			status_changed.emit("Remix preview closed")
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
