extends VBoxContainer

const Catalog = preload("res://scripts/asset_catalog.gd")
const Previews = preload("res://scripts/asset_previews.gd")

signal asset_selected(id: String, details: Dictionary)
signal asset_activated(kind: String)
signal asset_details_changed(id: String, details: Dictionary)
signal message(text: String)
signal thumbnail_changed(id: String, texture: Texture2D)

class FolderTree extends Tree:
	var browser: Control
	func _get_drag_data(_position: Vector2) -> Variant:
		var item := get_selected()
		if item == null or str(item.get_metadata(0)).is_empty():
			return null
		return {"browser": browser, "folder": item.get_metadata(0)}
	func _can_drop_data(position: Vector2, data: Variant) -> bool:
		return data is Dictionary and data.get("browser") == browser and get_item_at_position(position) != null
	func _drop_data(position: Vector2, data: Variant) -> void:
		browser.move_payload(data, str(get_item_at_position(position).get_metadata(0)))

class AssetList extends ItemList:
	var browser: Control
	func _get_drag_data(_position: Vector2) -> Variant:
		var ids: Array = browser.selected_ids()
		if ids.is_empty():
			return null
		var label := Label.new()
		label.text = "%d asset(s)" % ids.size()
		set_drag_preview(label)
		return {"browser": browser, "assets": ids}

var catalog := Catalog.new()
var previews: Node
var folders: Tree
var cards: ItemList
var search: LineEdit
var filter: OptionButton
var breadcrumbs: HBoxContainer
var empty: Label
var current_folder := ""
var project_directory := ""
var selected_id := ""
var icons: Dictionary = {}
var errors: Dictionary = {}
var refreshing := false
var refresh_pending := false
var folder_target := true
var placeholder: Texture2D

func _ready() -> void:
	custom_minimum_size.y = 170
	var bar := HFlowContainer.new()
	add_child(bar)
	var title := Label.new(); title.text = "ASSET LIBRARY"; bar.add_child(title)
	_button("New folder", func(): _name_dialog("New folder", "", func(value: String): catalog.create_folder(value, current_folder)), bar)
	_button("Rename", _rename, bar)
	_button("Move to…", _move_dialog, bar)
	_button("Remove folder", _remove, bar)
	_button("Retry preview", func():
		for id in selected_ids():
			errors.erase(id); previews.request(id, true), bar)
	_button("Refresh", refresh, bar)
	search = LineEdit.new(); search.custom_minimum_size.x = 160; search.placeholder_text = "Search all assets…"; search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search.text_changed.connect(func(_text: String): _schedule_refresh())
	bar.add_child(search)
	filter = OptionButton.new()
	for label in ["All", "Meshes", "Materials"]:
		filter.add_item(label)
	filter.item_selected.connect(func(_index: int): _schedule_refresh())
	bar.add_child(filter)
	var split := HSplitContainer.new(); split.size_flags_vertical = Control.SIZE_EXPAND_FILL; add_child(split)
	folders = FolderTree.new(); folders.browser = self; folders.custom_minimum_size.x = 160
	folders.item_selected.connect(_folder_selected)
	split.add_child(folders)
	var contents := VBoxContainer.new(); contents.size_flags_horizontal = Control.SIZE_EXPAND_FILL; split.add_child(contents)
	breadcrumbs = HBoxContainer.new(); contents.add_child(breadcrumbs)
	cards = AssetList.new(); cards.browser = self; cards.select_mode = ItemList.SELECT_MULTI
	cards.icon_mode = ItemList.ICON_MODE_TOP; cards.fixed_icon_size = Vector2i(72, 72)
	cards.fixed_column_width = 112; cards.max_columns = 0; cards.max_text_lines = 2
	cards.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cards.multi_selected.connect(_asset_selected)
	cards.item_activated.connect(func(index: int):
		selected_id = cards.get_item_metadata(index)
		asset_activated.emit(catalog.entries[selected_id].get("kind", "unknown")))
	cards.get_v_scroll_bar().value_changed.connect(func(_value: float): _prioritize())
	contents.add_child(cards)
	empty = Label.new(); empty.text = "Ingest an asset to start your library."; contents.add_child(empty)
	var image := Image.create(96, 96, false, Image.FORMAT_RGBA8)
	image.fill(Color("304150"))
	placeholder = ImageTexture.create_from_image(image)
	previews = Previews.new(); add_child(previews)
	previews.preview_ready.connect(_preview_ready)
	previews.identified.connect(func(id: String, kind: String): catalog.set_kind(id, kind))
	previews.failed.connect(func(id: String, error: String): errors[id] = error; _schedule_refresh())
	catalog.changed.connect(_schedule_refresh)
	catalog.error.connect(func(text: String): message.emit(text))

func _button(text: String, callback: Callable, parent: Node) -> Button:
	var button := Button.new(); button.text = text; button.pressed.connect(callback); parent.add_child(button)
	return button

func open_project(directory: String) -> void:
	project_directory = directory
	current_folder = ""; selected_id = ""; icons.clear(); errors.clear()
	previews.open_project(directory)
	catalog.open_project(directory)

func refresh() -> void:
	errors.clear()
	catalog.discover()

func _schedule_refresh() -> void:
	if not refresh_pending:
		refresh_pending = true
		_refresh.call_deferred()

func _refresh() -> void:
	refresh_pending = false
	if cards == null:
		return
	refreshing = true
	var old_selection := selected_ids()
	var scroll := cards.get_v_scroll_bar().value
	if not current_folder.is_empty() and not catalog.folders.has(current_folder):
		current_folder = ""
	folders.clear()
	var root := folders.create_item(); root.set_text(0, "Assets"); root.set_metadata(0, "")
	_build_folders(root, "")
	if current_folder.is_empty():
		root.select(0)
	for child in breadcrumbs.get_children():
		child.free()
	_button("Assets", func(): _navigate(""), breadcrumbs)
	var chain: Array[String] = []
	var parent := current_folder
	while catalog.folders.has(parent):
		chain.push_front(parent); parent = catalog.folders[parent].parent
	for id in chain:
		_button("/ " + catalog.folders[id].name, func(): _navigate(id), breadcrumbs)
	cards.clear()
	var ids: Array = catalog.query(current_folder, search.text, ["all", "mesh", "material"][filter.selected])
	for id in ids:
		var entry: Dictionary = catalog.entries[id]
		var available: bool = catalog.available(id)
		var caption: String = entry.name + (" (missing)" if not available else "")
		var index := cards.add_item(caption, icons.get(id, placeholder))
		cards.set_item_metadata(index, id)
		cards.set_item_tooltip(index, caption + "\n" + catalog.folder_path(entry.folder) + "\n" + id +
			("\n" + str(errors[id]) if errors.has(id) else ""))
		if not available:
			cards.set_item_custom_fg_color(index, Color("cf8c80"))
		if id in old_selection:
			cards.select(index, false)
		if available and not errors.has(id):
			previews.request(id)
	cards.get_v_scroll_bar().set_deferred("value", scroll)
	empty.visible = ids.is_empty()
	empty.text = "No matching assets." if not search.text.is_empty() else "Ingest an asset or move assets into this folder."
	refreshing = false
	if catalog.entries.has(selected_id):
		asset_details_changed.emit(selected_id, _details(selected_id))
	_prioritize.call_deferred()

func _build_folders(parent: TreeItem, id: String) -> void:
	var children: Array = catalog.folders.keys().filter(func(key: String): return catalog.folders[key].parent == id)
	children.sort_custom(func(a: String, b: String): return catalog.folders[a].name.naturalnocasecmp_to(catalog.folders[b].name) < 0)
	for child in children:
		var item := folders.create_item(parent)
		item.set_text(0, catalog.folders[child].name); item.set_metadata(0, child)
		if current_folder == child:
			item.select(0)
		_build_folders(item, child)

func _navigate(id: String) -> void:
	current_folder = id
	selected_id = ""; cards.deselect_all(); folder_target = true
	search.text = ""
	_schedule_refresh()

func _folder_selected() -> void:
	if not refreshing and folders.get_selected() != null:
		_navigate(str(folders.get_selected().get_metadata(0)))

func selected_ids() -> Array:
	var result := []
	if cards != null:
		for index in cards.get_selected_items():
			result.append(cards.get_item_metadata(index))
	return result

func _asset_selected(index: int, selected: bool) -> void:
	if refreshing or not selected:
		return
	folder_target = false
	selected_id = cards.get_item_metadata(index)
	asset_selected.emit(selected_id, _details(selected_id))

func _details(id: String) -> Dictionary:
	var details: Dictionary = catalog.entries[id].duplicate(true)
	details["asset"] = catalog.absolute_path(id)
	details["available"] = catalog.available(id)
	details["folder_path"] = catalog.folder_path(details.folder)
	details["texture"] = icons.get(id, placeholder)
	return details

func _preview_ready(id: String, texture: Texture2D, kind: String) -> void:
	icons[id] = texture
	catalog.set_kind(id, kind)
	for index in range(cards.item_count):
		if cards.get_item_metadata(index) == id:
			cards.set_item_icon(index, texture)
	thumbnail_changed.emit(id, texture)

func _prioritize() -> void:
	var ids := []
	for i in range(cards.item_count):
		var rect := cards.get_item_rect(i)
		rect.position.y -= cards.get_v_scroll_bar().value
		if rect.intersects(Rect2(Vector2.ZERO, cards.size)):
			ids.append(cards.get_item_metadata(i))
	previews.prioritize(ids)

func _name_dialog(title: String, initial: String, callback: Callable) -> void:
	if project_directory.is_empty():
		message.emit("Open a project first."); return
	var dialog := ConfirmationDialog.new(); dialog.title = title
	var field := LineEdit.new(); field.text = initial; field.custom_minimum_size.x = 300
	dialog.add_child(field); add_child(dialog)
	dialog.confirmed.connect(func(): callback.call(field.text); dialog.queue_free())
	dialog.canceled.connect(dialog.queue_free)
	field.text_submitted.connect(func(_value: String): dialog.confirmed.emit())
	dialog.popup_centered(); field.grab_focus(); field.select_all()

func _rename() -> void:
	if not folder_target and catalog.entries.has(selected_id):
		_name_dialog("Rename asset display name", catalog.entries[selected_id].name, func(value: String): catalog.rename_asset(selected_id, value))
	elif catalog.folders.has(current_folder):
		_name_dialog("Rename folder", catalog.folders[current_folder].name, func(value: String): catalog.rename_folder(current_folder, value))

func _remove() -> void:
	if not catalog.folders.has(current_folder):
		message.emit("Select a folder to remove."); return
	var dialog := ConfirmationDialog.new(); dialog.title = "Remove folder"
	dialog.dialog_text = "Move this folder's contents to its parent and remove the folder? Asset files will stay in place."
	add_child(dialog)
	var id := current_folder
	dialog.confirmed.connect(func(): catalog.remove_folder(id); dialog.queue_free())
	dialog.canceled.connect(dialog.queue_free); dialog.popup_centered()

func _move_dialog() -> void:
	var payload := {"browser": self}
	if folder_target and catalog.folders.has(current_folder):
		payload["folder"] = current_folder
	elif not selected_ids().is_empty():
		payload["assets"] = selected_ids()
	else:
		message.emit("Select assets or a folder to move."); return
	var dialog := ConfirmationDialog.new(); dialog.title = "Move to folder"
	var destination := OptionButton.new(); destination.custom_minimum_size.x = 360
	destination.add_item("Assets"); destination.set_item_metadata(0, "")
	for id in catalog.folders:
		destination.add_item(catalog.folder_path(id)); destination.set_item_metadata(destination.item_count - 1, id)
	dialog.add_child(destination); add_child(dialog)
	dialog.confirmed.connect(func(): move_payload(payload, destination.get_selected_metadata()); dialog.queue_free())
	dialog.canceled.connect(dialog.queue_free); dialog.popup_centered()

func move_payload(data: Dictionary, destination: String) -> void:
	if data.has("folder"):
		catalog.move_folder(data.folder, destination)
	elif data.has("assets"):
		catalog.move_assets(data.assets, destination)

func register_ingestion(asset: String, folder: String) -> void:
	# The job's destination is captured when ingestion starts, not when it finishes.
	catalog.discover()
	var id := asset.trim_prefix(project_directory.trim_suffix("/") + "/")
	if catalog.entries.has(id):
		catalog.move_assets([id], folder if catalog.folders.has(folder) else "")
