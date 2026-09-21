extends SceneTree

const Sessions = preload("res://scripts/project_sessions.gd")
var failures := 0
var publications := 0

func check(ok: bool, message: String) -> void:
	if not ok:
		push_error(message); failures += 1

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var directory := ProjectSettings.globalize_path("res://../.work/game-link/%d" % Time.get_ticks_usec()).simplify_path()
	var app: Control = load("res://main.tscn").instantiate()
	app.sessions = Sessions.new(directory.path_join("recent.json"))
	root.add_child(app)
	app.viewport.show_render = false
	check(app.game_link_button.disabled, "Link action requires a project")
	var capture: String = app.root_directory.path_join("tests/fixtures/capture.usda")
	var project := directory.path_join("project/work.usda")
	var game := directory.path_join("Game")
	DirAccess.make_dir_recursive_absolute(game)
	app._command({"op": "create", "capture": capture, "path": project})
	check(not app.game_link_button.disabled, "Opening a project enables linking")
	app._command({"op": "add_light", "type": "SphereLight", "translation": [0, 1, 0]})
	var light: String = app.selection
	var unsaved := FileAccess.get_file_as_string(project.get_base_dir().path_join("mod.usda"))
	app._show_game_link()
	await process_frame; await process_frame
	var dialog = app.game_link_dialog
	check(dialog.visible and dialog.mod_name.text == "work", "Dialog proposes the workfile name")
	check(dialog.size.y < root.size.y and dialog.get_ok_button().get_global_rect().end.y <= dialog.size.y, "Dialog and Close button must fit the window")
	dialog.browse.pressed.emit()
	await process_frame; await process_frame
	var picker: FileDialog
	for child in dialog.get_children():
		if child is FileDialog: picker = child
	check(is_instance_valid(picker) and picker.visible, "Browse must open a nested modal file picker")
	picker.dir_selected.emit(game)
	await process_frame; await process_frame
	check(dialog.folder.text == game, "Folder picker must fill the game destination")
	dialog.mod_name.text = "Live test"
	dialog.connect_button.pressed.emit()
	check(app.game_link.state.get("connected", false) and dialog.sync_button.visible and not dialog.folder.editable, "Link UI creates and displays the connection")
	check(app.game_link_button.text == "Game linked" and app.state.dirty, "Link status is visible without clearing unsaved edits")
	if DisplayServer.get_name() != "headless":
		await process_frame; await process_frame
		root.get_texture().get_image().save_png(directory.path_join("linked-dialog.png"))
	check(FileAccess.get_file_as_string(project.get_base_dir().path_join("mod.usda")) == unsaved, "Linking does not save original authoring layers")
	var mod: String = app.game_link.state.target.path_join("mod.usda")
	app.game_link.status_changed.connect(func(): publications += 1)
	for i in 5:
		app._command({"op": "transform", "path": light, "translation": [i, 3, 0]})
	check(publications == 0 and not app.game_link.timer.is_stopped(), "Rapid committed edits must debounce publication")
	await create_timer(0.6).timeout
	check(publications == 1 and app.game_link.error.is_empty(), "A burst of edits must publish once")
	var count := publications
	app._command({"op": "undo"})
	await create_timer(0.6).timeout
	check(publications == count + 1, "Undo must update the live mod")
	count = publications
	app._command({"op": "redo"})
	app._command({"op": "save"})
	await create_timer(0.6).timeout
	check(publications == count + 1 and not app.state.dirty, "Save publishes immediately without a second timer update")
	app._command({"op": "transform", "path": light, "translation": [20, 3, 0]})
	await app._prepare_close()
	check(app.game_link.timer.is_stopped(), "Closing must flush the last pending live edit")
	# A pending timeout must never publish a different project's composition.
	app._command({"op": "transform", "path": light, "translation": [30, 3, 0]})
	app._command({"op": "create", "capture": capture, "path": directory.path_join("other/work.usda")})
	check(not app.game_link.state.get("linked", false) and app.game_link.timer.is_stopped(), "New project must not inherit the previous link")
	var prior_mod := FileAccess.get_file_as_string(mod)
	app._command({"op": "add_light", "type": "SphereLight"})
	await create_timer(0.6).timeout
	check(FileAccess.get_file_as_string(mod) == prior_mod, "Edits in another project must not update the linked mod")
	app._command({"op": "open", "path": project})
	await create_timer(0.6).timeout
	check(app.game_link.state.get("connected", false) and app.game_link.error.is_empty(), "Reopening restores and synchronizes the saved link")
	app._show_game_link()
	await process_frame; await process_frame
	dialog = app.game_link_dialog
	DirAccess.remove_absolute(mod.get_base_dir())
	DirAccess.make_dir_recursive_absolute(mod.get_base_dir())
	var keep := FileAccess.open(mod.get_base_dir().path_join("keep.txt"), FileAccess.WRITE)
	keep.store_string("foreign mod"); keep.close()
	dialog.sync_button.pressed.emit()
	check(not app.game_link.error.is_empty() and app.game_link_button.text == "Game link !" and dialog.notice.text.contains("failed"), "Sync errors must appear in the dialog and toolbar")
	dialog.unlink_button.pressed.emit()
	check(not app.game_link.state.get("linked", false) and app.game_link.error.is_empty(), "Unlink recovers a broken link")
	check(FileAccess.get_file_as_string(mod.get_base_dir().path_join("keep.txt")) == "foreign mod", "Unlink must preserve a replacement directory")
	check(dialog.connect_button.visible and dialog.folder.editable, "Unlink re-enables destination controls")
	app.queue_free()
	await process_frame; await process_frame
	print("Game link UI: %d failures" % failures)
	quit(1 if failures else 0)
