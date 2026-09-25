extends SceneTree

const Sessions = preload("res://scripts/project_sessions.gd")
const INSTANCE := "/RootNode/instances/inst_0123456789ABCDEF_1"
var failures := 0
var app: Control

func check(ok: bool, message: String) -> void:
	if not ok: push_error(message); failures += 1

func settle() -> void:
	for i in 4: await process_frame

func _initialize() -> void: run.call_deferred()

func run() -> void:
	var directory := ProjectSettings.globalize_path("res://../.work/mesh-revert/%d" % Time.get_ticks_usec()).simplify_path()
	app = load("res://main.tscn").instantiate()
	app.sessions = Sessions.new(directory.path_join("recent.json"))
	root.add_child(app)
	app.render_toggle.button_pressed = false
	app._command({"op": "create", "capture": app.root_directory.path_join("tests/fixtures/capture.usda"), "path": directory.path_join("work.usda")})
	app._select(INSTANCE + "/mesh")
	check(not is_instance_valid(app.inspector.revert_mesh_button), "Original mesh must not show Revert")
	app._command({"op": "add_light", "path": INSTANCE + "/mesh"})
	var light: String = app.selection
	app._command({"op": "replace_mesh", "path": INSTANCE + "/mesh", "asset": app.root_directory.path_join("tests/fixtures/replacement.usda")})
	var replacement: String = app.selection
	app._select(replacement + "/triangle")
	check(is_instance_valid(app.inspector.revert_mesh_button), "Selecting replacement geometry must expose Revert in Properties")
	var revision: int = app.state.revision
	app.inspector.revert_mesh_button.pressed.emit()
	await settle()
	check(app.state.revision == revision + 1, "Properties action must commit one edit")
	check(app.selection == INSTANCE + "/mesh" and app.viewport.selected_path == app.selection, "Selection must move to the restored mesh")
	check(app.viewport.gizmo.path == app.selection, "Gizmo must follow the restored selection")
	check(not is_instance_valid(app.inspector.revert_mesh_button), "Revert must disappear after restoring the captured mesh")
	check(not app._request({"op": "inspect", "path": light}).is_empty(), "Attached light must survive")
	app._command({"op": "undo"})
	app._select(replacement)
	check(is_instance_valid(app.inspector.revert_mesh_button), "Undo must restore replacement controls")
	app._command({"op": "redo"})
	check(not is_instance_valid(app.inspector.revert_mesh_button), "Redo must clear stale replacement controls")
	app._select(INSTANCE + "/mesh")
	check(not is_instance_valid(app.inspector.revert_mesh_button), "Original mesh must remain restored")
	app.queue_free(); await settle()
	print("Mesh revert UI: %d failures" % failures)
	quit(1 if failures else 0)
