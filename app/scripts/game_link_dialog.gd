extends AcceptDialog

signal browse_requested
var link: Node
var folder := LineEdit.new()
var mod_name := LineEdit.new()
var browse := Button.new()
var connect_button := Button.new()
var sync_button := Button.new()
var unlink_button := Button.new()
var notice := Label.new()

func _ready() -> void:
	title = "Link project to game"
	ok_button_text = "Close"
	var column := VBoxContainer.new()
	column.custom_minimum_size.x = 520
	add_child(column)
	var intro := Label.new()
	intro.text = "Edits, Undo and Redo update the game automatically.\nSave still controls what is saved to your project."
	column.add_child(intro)
	var label := Label.new(); label.text = "Game folder (or rtx-remix/mods)"; column.add_child(label)
	var row := HBoxContainer.new(); column.add_child(row)
	folder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	folder.placeholder_text = "Select a game folder"
	row.add_child(folder)
	browse.text = "Browse…"; row.add_child(browse)
	browse.pressed.connect(func(): browse_requested.emit())
	label = Label.new(); label.text = "Mod folder name"; column.add_child(label)
	column.add_child(mod_name)
	row = HBoxContainer.new(); column.add_child(row)
	connect_button.text = "Link to game"; row.add_child(connect_button)
	sync_button.text = "Sync now"; row.add_child(sync_button)
	unlink_button.text = "Unlink"; row.add_child(unlink_button)
	connect_button.pressed.connect(func(): link.link_game(folder.text.strip_edges(), mod_name.text.strip_edges()))
	sync_button.pressed.connect(func(): link.sync_now())
	unlink_button.pressed.connect(func(): link.unlink_game())
	notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	notice.custom_minimum_size.x = 520
	column.add_child(notice)
	label = Label.new()
	label.text = "Enable the mod in the game's Remix menu if needed.\nUpdates use Remix's hot reload and may take a moment.\nUnlink removes only the shortcut; project files are retained."
	column.add_child(label)
	link.status_changed.connect(refresh)
	refresh()

func refresh() -> void:
	var linked: bool = link.state.get("linked", false)
	if linked:
		folder.text = String(link.state.target).get_base_dir()
		mod_name.text = String(link.state.target).get_file()
	folder.editable = not linked; mod_name.editable = not linked
	browse.disabled = linked; connect_button.visible = not linked
	sync_button.visible = linked; unlink_button.visible = linked
	if not link.error.is_empty():
		notice.text = "Live update failed: " + link.error
	elif linked:
		notice.text = ("Live updates on: " if link.state.get("connected", false) else "Link missing: ") + String(link.state.target)
	else:
		notice.text = link.state.get("message", "Creates a symlink in rtx-remix/mods. Existing mods are never replaced.")
