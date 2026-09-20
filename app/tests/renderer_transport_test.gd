extends SceneTree

const RendererClient = preload("res://scripts/renderer_client.gd")
var failures := 0
var responses: Array[Dictionary] = []

func check(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		failures += 1

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	# Exercise the real client thread and worker framing without starting Vulkan.
	var client := RendererClient.new()
	root.add_child(client)
	client.set_process(false)
	var worker := ProjectSettings.globalize_path("res://../build/remix-renderer" + (".exe" if OS.get_name() == "Windows" else ""))
	client.process = OS.execute_with_pipe(worker, [], true)
	if client.process.is_empty():
		push_error("Could not start protocol worker")
		quit(1)
		return
	client.response_received.connect(func(response: Dictionary): responses.append(response))
	client.writer = Thread.new()
	client.writer.start(client._exchange_loop.bind(client.generation))
	# Non-ASCII content crosses transport boundaries. The unknown operation is
	# returned as an error, so both request and response exceed the former limit.
	var operation := "材🌲".repeat(10 * 1024 * 1024)
	client.send({"op": operation})
	client.send({"op": "hello"})
	var deadline := Time.get_ticks_msec() + 60000
	while responses.size() < 2 and Time.get_ticks_msec() < deadline:
		await process_frame
	check(responses.size() == 2, "Large transfer and following command must complete")
	if responses.size() == 2:
		check(responses[0].get("id") == 1 and responses[0].get("request_op") == operation, "Large response must retain request identity")
		check(responses[0].get("error") == "Unknown renderer operation: " + operation, "Large UTF-8 payload must round-trip intact")
		check(responses[1].get("id") == 2 and responses[1].get("ok", false), "A command after the large transfer must remain aligned")
		check(responses[1].get("result", {}).get("protocol") == RendererClient.PROTOCOL_VERSION, "Client and worker protocol must match")
	client.stop_worker()
	check(client.process.is_empty() and client.writer == null, "Worker shutdown must complete after large transfers")
	print("Renderer transport: %d failures" % failures)
	quit(1 if failures else 0)
