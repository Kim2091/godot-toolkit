extends Node

signal status_changed
signal warning(message: String)
var document: Object
var state: Dictionary = {}
var error := ""
var timer := Timer.new()

func _ready() -> void:
	timer.one_shot = true
	timer.wait_time = 0.35
	timer.timeout.connect(sync_now)
	add_child(timer)

func _request(command: Dictionary) -> bool:
	if document == null:
		return false
	var response = JSON.parse_string(document.execute(JSON.stringify(command)))
	if not response is Dictionary or not response.get("ok", false):
		error = response.get("error", "Invalid game link response") if response is Dictionary else "Invalid game link response"
		warning.emit(error)
		status_changed.emit()
		return false
	state = response.result
	error = ""
	status_changed.emit()
	return true

func open_project() -> void:
	timer.stop()
	state = {}
	if _request({"op": "game_link_status"}):
		changed()

func changed() -> void:
	if state.get("linked", false):
		timer.start()

func link_game(folder: String, mod_name: String) -> bool:
	timer.stop()
	return _request({"op": "game_link", "folder": folder, "name": mod_name})

func sync_now() -> bool:
	timer.stop()
	return _request({"op": "game_sync"}) if state.get("linked", false) else false

func unlink_game() -> bool:
	timer.stop()
	return _request({"op": "game_unlink"})

func flush() -> void:
	if not timer.is_stopped():
		sync_now()
