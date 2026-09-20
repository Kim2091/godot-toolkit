extends Control

const LayoutView = preload("res://scripts/layout_view.gd")
const RendererClient = preload("res://scripts/renderer_client.gd")
var document: Object
var state: Dictionary = {}
var selection := ""
var tree: Tree
var assets: ItemList
var inspector: VBoxContainer
var layer_picker: OptionButton
var status: Label
var project_label: Label
var output: RichTextLabel
var viewport: Control
var renderer: Node
var pending_capture := ""
var refreshing := false
var import_running := false
var last_scene: Dictionary = {}
var runtime_path := ""
var root_directory := ""

func _ready() -> void:
	root_directory = ProjectSettings.globalize_path("res://").get_base_dir().get_base_dir()
	if ClassDB.class_exists("RemixDocument"):
		document = ClassDB.instantiate("RemixDocument")
	_setup_theme()
	_build_ui()
	renderer = RendererClient.new()
	add_child(renderer)
	renderer.status_changed.connect(_log)
	renderer.response_received.connect(_renderer_response)
	renderer.texture_ready.connect(func(texture: Texture2D):
		viewport.rendered_texture = texture
		viewport.queue_redraw())
	get_tree().auto_accept_quit = false
	if document == null:
		_log("Native USD extension is unavailable. Build the project with scripts/bootstrap.py first.")
	else:
		_log("Ready. Open a Toolkit workfile or create a project from a Remix capture.")
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--project="):
			_open_project(argument.trim_prefix("--project="))

func _setup_theme() -> void:
	var skin := Theme.new()
	skin.default_font_size = 14
	var panel := StyleBoxFlat.new()
	panel.bg_color = Color("1b2530")
	panel.set_corner_radius_all(4)
	panel.content_margin_left = 10
	panel.content_margin_right = 10
	panel.content_margin_top = 7
	panel.content_margin_bottom = 7
	skin.set_stylebox("normal", "Button", panel)
	var hover := panel.duplicate()
	hover.bg_color = Color("2c414e")
	skin.set_stylebox("hover", "Button", hover)
	var active := panel.duplicate()
	active.bg_color = Color("236354")
	skin.set_stylebox("pressed", "Button", active)
	skin.set_color("font_color", "Label", Color("c3d1df"))
	skin.set_color("font_color", "Button", Color("deebf0"))
	skin.set_constant("separation", "HBoxContainer", 6)
	skin.set_constant("separation", "VBoxContainer", 7)
	theme = skin

func _button(text: String, action: Callable, parent: Node) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(action)
	parent.add_child(button)
	return button

func _label(text: String, parent: Node, font_size := 14) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	parent.add_child(label)
	return label

func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	add_child(margin)
	var column := VBoxContainer.new()
	margin.add_child(column)
	var header := HBoxContainer.new()
	column.add_child(header)
	_label("REMIX STUDIO", header, 20).modulate = Color("70d9c0")
	project_label = _label("No project", header)
	project_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_button("New from capture", _new_capture, header)
	_button("Open", _choose_open, header)
	_button("Save", func(): _command({"op": "save"}), header)
	_button("Package mod", _choose_package, header)
	var toolbar := HBoxContainer.new()
	column.add_child(toolbar)
	_button("Undo", func(): _command({"op": "undo"}), toolbar)
	_button("Redo", func(): _command({"op": "redo"}), toolbar)
	_button("Ingest asset", _choose_ingest, toolbar)
	_button("Cancel import", func():
		if document != null and import_running:
			document.cancel_ingestion(), toolbar)
	_button("Add mesh", func(): _use_asset("add_mesh"), toolbar)
	_button("Replace mesh", func(): _use_asset("replace_mesh"), toolbar)
	_button("Replace material", func(): _use_asset("replace_material"), toolbar)
	var lights := MenuButton.new()
	lights.text = "Add light"
	toolbar.add_child(lights)
	var types := ["SphereLight", "SpotLight", "RectLight", "DiskLight", "CylinderLight", "DistantLight", "DomeLight"]
	for type in types:
		lights.get_popup().add_item(type.trim_suffix("Light"))
	lights.get_popup().id_pressed.connect(func(id: int): _command({"op": "add_light", "path": selection, "type": types[id]}))
	_button("Duplicate", func(): _command({"op": "duplicate", "path": selection}), toolbar)
	_button("Delete", func(): _command({"op": "delete", "path": selection}), toolbar)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(spacer)
	_button("Start / restart Remix", _start_renderer, toolbar)
	var workspace := HSplitContainer.new()
	workspace.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(workspace)
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 240
	workspace.add_child(left)
	_label("SCENE", left)
	tree = Tree.new()
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tree.hide_root = true
	tree.item_selected.connect(_tree_selected)
	left.add_child(tree)
	_label("AUTHORING LAYER", left, 12)
	layer_picker = OptionButton.new()
	left.add_child(layer_picker)
	layer_picker.item_selected.connect(func(index: int):
		if not refreshing:
			_command({"op": "select_layer", "layer": layer_picker.get_item_metadata(index)}))
	_label("ASSET LIBRARY", left)
	assets = ItemList.new()
	assets.custom_minimum_size.y = 180
	left.add_child(assets)
	assets.item_activated.connect(func(_index: int): _use_asset("add_mesh"))
	var center_right := HSplitContainer.new()
	center_right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	workspace.add_child(center_right)
	var center_panel := VBoxContainer.new()
	center_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center_right.add_child(center_panel)
	var view_tools := HBoxContainer.new()
	center_panel.add_child(view_tools)
	_label("Viewport", view_tools).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var render_toggle := CheckButton.new()
	render_toggle.text = "Remix"
	render_toggle.button_pressed = true
	render_toggle.toggled.connect(func(value: bool):
		viewport.show_render = value
		viewport.queue_redraw())
	view_tools.add_child(render_toggle)
	_button("Frame all", func(): viewport.frame_selection(true), view_tools)
	_button("Frame selection", func(): viewport.frame_selection(), view_tools)
	var snap := CheckButton.new()
	snap.text = "Snap"
	snap.toggled.connect(func(value: bool): viewport.snap = value)
	view_tools.add_child(snap)
	viewport = LayoutView.new()
	viewport.size_flags_vertical = Control.SIZE_EXPAND_FILL
	viewport.custom_minimum_size = Vector2(400, 300)
	viewport.selected.connect(_select)
	viewport.camera_changed.connect(func(camera: Dictionary):
		if renderer != null and renderer.is_ready:
			renderer.send({"op": "camera", "camera": camera}))
	viewport.translation_requested.connect(_translate)
	center_panel.add_child(viewport)
	_label("Shift + drag moves the selection. Changes to captured assets affect every instance.", center_panel, 12)
	var right := VBoxContainer.new()
	right.custom_minimum_size.x = 270
	center_right.add_child(right)
	_label("PROPERTIES", right)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(scroll)
	inspector = VBoxContainer.new()
	inspector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(inspector)
	output = RichTextLabel.new()
	output.custom_minimum_size.y = 85
	output.scroll_following = true
	column.add_child(output)
	status = _label("", column, 12)

func _log(message: String) -> void:
	status.text = message
	output.append_text(message + "\n")

func _request(data: Dictionary) -> Dictionary:
	if document == null:
		_log("Build the native USD extension before opening a project.")
		return {}
	var response = JSON.parse_string(document.execute(JSON.stringify(data)))
	if not response is Dictionary or not response.get("ok", false):
		_log(response.get("error", "Invalid native response") if response is Dictionary else "Invalid native response")
		return {}
	return response.get("result", {})

func _command(data: Dictionary) -> void:
	var previous_revision: int = state.get("revision", -1)
	var result := _request(data)
	if result.is_empty():
		return
	if result.has("selection"):
		selection = result.selection
	if result.has("document"):
		state = result.document
		_refresh(state.get("revision", -1) != previous_revision)
	if data.op == "save":
		_log("Project saved.")
	elif data.op == "package":
		_log("Mod packaged at " + data.path)

func _refresh(scene_changed := true) -> void:
	refreshing = true
	project_label.text = String(state.get("path", "No project")).get_file() + (" •" if state.get("dirty", false) else "")
	tree.clear()
	var root := tree.create_item()
	var entries := {"/": root}
	for prim in state.get("prims", []):
		var parent: String = String(prim.path).get_base_dir()
		var item := tree.create_item(entries.get(parent, root))
		item.set_text(0, prim.name + ("  [" + prim.type + "]" if not String(prim.type).is_empty() else ""))
		item.set_metadata(0, prim.path)
		item.set_tooltip_text(0, prim.path)
		if not prim.visible:
			item.set_custom_color(0, Color("74818e"))
		entries[prim.path] = item
		if prim.path == selection:
			item.select(0)
	layer_picker.clear()
	for layer in state.get("layers", []):
		layer_picker.add_item(layer.name + (" (capture)" if layer.capture else ""))
		var i := layer_picker.item_count - 1
		layer_picker.set_item_metadata(i, layer.id)
		layer_picker.set_item_disabled(i, not layer.editable)
		if layer.selected:
			layer_picker.select(i)
	refreshing = false
	_refresh_assets()
	_select(selection)
	if scene_changed and state.get("open", false):
		var first := last_scene.is_empty()
		last_scene = _request({"op": "scene"})
		viewport.set_scene(last_scene, first)
		if renderer.is_ready:
			renderer.send({"op": "scene", "scene": last_scene})
		for warning in state.get("warnings", []) + last_scene.get("warnings", []):
			_log(warning)

func _tree_selected() -> void:
	if refreshing:
		return
	var item := tree.get_selected()
	if item:
		_select(item.get_metadata(0))

func _select(path: String) -> void:
	selection = path
	viewport.selected_path = path
	viewport.queue_redraw()
	for child in inspector.get_children():
		inspector.remove_child(child)
		child.queue_free()
	if path.is_empty():
		_label("Select an object to edit.", inspector)
		return
	var details := _request({"op": "inspect", "path": path})
	if details.is_empty():
		return
	var path_label := _label(path, inspector, 12)
	path_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if details.get("anchor") != null:
		var anchor := _label("Replacement: " + String(details.anchor).get_file(), inspector, 12)
		anchor.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if details.has("translation"):
		_vector_editor("Translation", details.translation, func(value: Array): _command({"op": "transform", "path": path, "translation": value}))
		_vector_editor("Rotation (degrees)", details.rotation, func(value: Array): _command({"op": "transform", "path": path, "rotation": value}))
		_vector_editor("Scale", details.scale, func(value: Array): _command({"op": "transform", "path": path, "scale": value}))
	for property in details.get("properties", []):
		if String(property.name).begins_with("xformOp") or String(property.name).begins_with("collection:"):
			continue
		_label(property.name, inspector, 12)
		var value = property.value
		var commit := func(next): _command({"op": "set_property", "path": path, "property": property.name, "value": next})
		if value is bool:
			var field := CheckButton.new()
			field.button_pressed = value
			field.toggled.connect(commit)
			inspector.add_child(field)
		elif value is float or value is int:
			var row := HBoxContainer.new()
			inspector.add_child(row)
			var field := SpinBox.new()
			field.allow_greater = true; field.allow_lesser = true
			field.step = 1.0 if property.type == "int" else 0.01
			field.value = value
			field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			field.get_line_edit().text_submitted.connect(func(_text: String): commit.call(field.value))
			row.add_child(field)
			_button("Apply", func(): commit.call(field.value), row)
		elif value is Array and value.size() == 3:
			_vector_editor("", value, commit)
		else:
			var field := LineEdit.new()
			field.text = str(value)
			field.text_submitted.connect(commit)
			inspector.add_child(field)

func _vector_editor(label: String, values: Array, commit: Callable) -> void:
	if not label.is_empty():
		_label(label, inspector, 12)
	var row := HBoxContainer.new()
	inspector.add_child(row)
	var fields: Array[SpinBox] = []
	for value in values:
		var field := SpinBox.new()
		field.allow_greater = true; field.allow_lesser = true
		field.step = 0.1; field.value = value
		field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		field.custom_minimum_size.x = 65
		fields.append(field); row.add_child(field)
	_button("Apply", func(): commit.call([fields[0].value, fields[1].value, fields[2].value]), inspector)

func _translate(delta: Vector3) -> void:
	_command({"op": "transform", "path": selection, "world_delta": [delta.x, delta.y, delta.z]})

func _dialog(mode: FileDialog.FileMode, title: String, filters: PackedStringArray, callback: Callable) -> void:
	var dialog := FileDialog.new()
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = mode
	dialog.title = title
	dialog.filters = filters
	dialog.use_native_dialog = false
	add_child(dialog)
	if mode == FileDialog.FILE_MODE_OPEN_DIR:
		dialog.dir_selected.connect(func(path: String): dialog.queue_free(); callback.call_deferred(path))
	else:
		dialog.file_selected.connect(func(path: String): dialog.queue_free(); callback.call_deferred(path))
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered_ratio(0.65)

func _guard_unsaved(action: Callable) -> void:
	if not state.get("dirty", false):
		action.call()
		return
	var dialog := ConfirmationDialog.new()
	dialog.dialog_text = "This project has unsaved edits. Discard them?"
	dialog.ok_button_text = "Discard edits"
	add_child(dialog)
	dialog.confirmed.connect(func(): dialog.queue_free(); action.call())
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered()

func _choose_open() -> void:
	_guard_unsaved(func(): _dialog(FileDialog.FILE_MODE_OPEN_FILE, "Open Toolkit project", ["*.usd,*.usda,*.usdc ; USD projects"], _open_project))

func _open_project(path: String) -> void:
	last_scene = {}
	selection = ""
	_command({"op": "open", "path": path})

func _new_capture() -> void:
	_guard_unsaved(func(): _dialog(FileDialog.FILE_MODE_OPEN_FILE, "Select Remix capture", ["*.usd,*.usda,*.usdc ; Remix captures"], func(path: String):
		pending_capture = path
		_dialog(FileDialog.FILE_MODE_SAVE_FILE, "Create project in a new directory", ["*.usda ; USD project"], func(project: String):
			last_scene = {}; selection = ""
			_command({"op": "create", "capture": pending_capture, "path": project}))))

func _choose_package() -> void:
	_dialog(FileDialog.FILE_MODE_OPEN_DIR, "Select parent folder for packaged mod", [], func(path: String):
		_command({"op": "package", "path": path.path_join("remix_mod_" + str(Time.get_unix_time_from_system()).replace(".", "_"))}))

func _choose_ingest() -> void:
	if not state.get("open", false) or import_running:
		_log("Open a project and finish any running import first.")
		return
	_dialog(FileDialog.FILE_MODE_OPEN_FILE, "Ingest model or material", ["*.usd,*.usda,*.usdc,*.gltf,*.glb,*.fbx,*.obj,*.png,*.jpg,*.jpeg,*.tga,*.exr,*.hdr,*.dds ; Assets"], func(path: String):
		_import_options(path))

func _import_options(path: String) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "Ingest " + path.get_file()
	dialog.ok_button_text = "Ingest"
	var fields := VBoxContainer.new()
	dialog.add_child(fields)
	_label("Asset name", fields)
	var asset_name := LineEdit.new()
	asset_name.text = path.get_file().get_basename()
	fields.add_child(asset_name)
	var is_material := path.get_extension().to_lower() in ["png", "jpg", "jpeg", "tga", "exr", "hdr", "dds"]
	var scale_field := SpinBox.new()
	scale_field.min_value = 0.0001; scale_field.max_value = 100000; scale_field.step = 0.01; scale_field.value = 1
	if not is_material:
		_label("Scale multiplier (after source unit conversion)", fields)
		fields.add_child(scale_field)
	var material_kind := OptionButton.new()
	var texture_role := OptionButton.new()
	if is_material:
		_label("Material", fields)
		for name in ["Opaque", "Cutout", "Glass"]:
			material_kind.add_item(name)
		fields.add_child(material_kind)
		_label("Texture role", fields)
		for name in ["Base color", "Normal", "Roughness", "Metallic", "Emissive"]:
			texture_role.add_item(name)
		fields.add_child(texture_role)
	_label("Normal map convention", fields)
	var normal := OptionButton.new()
	normal.add_item("OpenGL (+Y)")
	normal.add_item("DirectX (-Y)")
	fields.add_child(normal)
	dialog.confirmed.connect(func():
		var request := {"source": path, "name": asset_name.text, "scale": scale_field.value, "material": is_material,
			"normal_encoding": "normal_ogl" if normal.selected == 0 else "normal_dx", "mdl_directory": root_directory.path_join("app/materials")}
		if is_material:
			request["texture_role"] = ["albedo", "normal", "roughness", "metallic", "emissive"][texture_role.selected]
			request["properties"] = {"kind": "translucent" if material_kind.selected == 2 else "opaque", "alpha_test": 6 if material_kind.selected == 1 else 7}
		var response = JSON.parse_string(document.start_ingestion(JSON.stringify(request)))
		if response.get("ok", false):
			import_running = true
			_log("Ingesting " + path.get_file() + "…")
		else:
			_log(response.get("error", "Could not start ingestion"))
		dialog.queue_free())
	dialog.canceled.connect(dialog.queue_free)
	# Keep all controls owned, including those hidden for this asset type.
	if is_material:
		dialog.add_child(scale_field); scale_field.hide()
	else:
		dialog.add_child(material_kind); material_kind.hide()
		dialog.add_child(texture_role); texture_role.hide()
	add_child(dialog)
	dialog.popup_centered(Vector2i(420, 340))

func _refresh_assets() -> void:
	assets.clear()
	if not state.get("open", false):
		return
	var directory := String(state.path).get_base_dir().path_join("assets")
	if not DirAccess.dir_exists_absolute(directory):
		return
	for name in DirAccess.get_directories_at(directory):
		var path := directory.path_join(name).path_join("asset.usda")
		if name.begins_with(".") or not FileAccess.file_exists(path):
			continue
		assets.add_item(name)
		assets.set_item_metadata(assets.item_count - 1, path)

func _use_asset(op: String) -> void:
	var chosen := assets.get_selected_items()
	if chosen.is_empty() or selection.is_empty():
		_log("Select a captured object and an ingested asset first.")
		return
	_command({"op": op, "path": selection, "asset": assets.get_item_metadata(chosen[0])})

func _start_renderer() -> void:
	if not state.get("open", false):
		_log("Open a scene before starting the renderer.")
		return
	var configured := OS.get_environment("REMIX_RUNTIME_PATH")
	if not configured.is_empty():
		_launch_renderer(configured)
	elif not runtime_path.is_empty():
		_launch_renderer(runtime_path)
	elif FileAccess.file_exists(root_directory.path_join(".work/build/remix/src/linux/libremix.so")):
		_launch_renderer(root_directory.path_join(".work/build/remix/src/linux/libremix.so"))
	else:
		_dialog(FileDialog.FILE_MODE_OPEN_FILE, "Select Remix runtime library", [], _launch_renderer)

func _launch_renderer(library: String) -> void:
	runtime_path = library
	var worker := OS.get_environment("REMIX_RENDERER_WORKER")
	if worker.is_empty():
		worker = root_directory.path_join("build/remix-renderer" + (".exe" if OS.get_name() == "Windows" else ""))
	renderer.start_worker(worker, library)

func _renderer_response(response: Dictionary) -> void:
	if response.get("ok", false) and response.get("request_op") == "start":
		renderer.send({"op": "scene", "scene": last_scene})
		renderer.send({"op": "camera", "camera": viewport.camera()})

func _process(_delta: float) -> void:
	if renderer != null and renderer.is_ready:
		viewport.queue_redraw()
	if import_running and document != null:
		var response: String = document.poll_ingestion()
		if not response.is_empty():
			import_running = false
			var result = JSON.parse_string(response)
			if result.get("ok", false):
				_log("Asset ingested: " + result.result.asset)
				for warning in result.result.get("warnings", []):
					_log(warning)
				_refresh_assets()
			else:
				_log(result.get("error", "Ingestion failed"))

func _unhandled_key_input(event: InputEvent) -> void:
	if not event.is_pressed() or event.is_echo() or get_viewport().gui_get_focus_owner() is LineEdit:
		return
	if event is InputEventKey:
		if event.is_command_or_control_pressed():
			if event.keycode == KEY_S:
				_command({"op": "save"})
			elif event.keycode == KEY_Z:
				_command({"op": "redo" if event.shift_pressed else "undo"})
		elif event.keycode == KEY_F:
			viewport.frame_selection()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_guard_unsaved(func(): get_tree().quit())
