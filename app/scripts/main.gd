extends Control

const LayoutView = preload("res://scripts/layout_view.gd")
const RendererClient = preload("res://scripts/renderer_client.gd")
const AssetBrowser = preload("res://scripts/asset_browser.gd")
const AuthoringInspector = preload("res://scripts/authoring_inspector.gd")
const ProjectSessions = preload("res://scripts/project_sessions.gd")
const WelcomeScreen = preload("res://scripts/welcome_screen.gd")
const StudioTheme = preload("res://scripts/studio_theme.gd")
var sessions := ProjectSessions.new()
var welcome: Control
var editor_page: Control
var camera_mode: OptionButton
var render_toggle: CheckButton
var dpi_timer: Timer
var restoring_view := false
var save_pending := false
var close_pending := false
var preview_jobs := 0
var save_serials: Dictionary = {}
var document: Object
var state: Dictionary = {}
var selection := ""
var tree: Tree
var assets: Control
var inspector: VBoxContainer
var layer_picker: OptionButton
var capture_picker: OptionButton
var add_capture_button: Button
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
var runtime_dialog: FileDialog
var root_directory := ""
var library_selection := ""
var import_folder := ""
var import_project := ""

func _ready() -> void:
	root_directory = ProjectSettings.globalize_path("res://").get_base_dir().get_base_dir()
	if ClassDB.class_exists("RemixDocument"):
		document = ClassDB.instantiate("RemixDocument")
	theme = StudioTheme.create()
	_update_dpi()
	_build_ui()
	sessions.warning.connect(_log)
	sessions.load_history()
	dpi_timer = Timer.new(); dpi_timer.wait_time = 1.0
	dpi_timer.timeout.connect(_update_dpi); add_child(dpi_timer); dpi_timer.start()
	get_window().dpi_changed.connect(_update_dpi)
	renderer = RendererClient.new()
	add_child(renderer)
	renderer.status_changed.connect(_log)
	renderer.response_received.connect(_renderer_response)
	renderer.texture_ready.connect(func(texture: Texture2D):
		if texture == null:
			viewport.rendered_texture = null)
	renderer.frame_presented.connect(func(context: Dictionary):
		if context.get("revision", -1) == state.get("revision", -2):
			viewport.rendered_texture = renderer.frame_texture)
	_show_welcome()
	get_tree().auto_accept_quit = false
	if document == null:
		_log("Native USD extension is unavailable. Build the project with scripts/bootstrap.py first.")
	else:
		_log("Ready. Open a Toolkit workfile or create a project from a Remix capture.")
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--project="):
			_open_project(argument.trim_prefix("--project="))

func _update_dpi() -> void:
	var factor := DisplayServer.screen_get_scale()
	if not is_finite(factor) or factor <= 0:
		factor = 1
	if dpi_timer == null and factor != 1.0 and DisplayServer.get_name() != "headless" and get_window().mode == Window.MODE_WINDOWED:
		var available := DisplayServer.screen_get_usable_rect()
		get_window().size = Vector2i(Vector2(get_window().size) * factor).min(available.size)
		get_window().position = available.position + (available.size - get_window().size) / 2
	if get_window().content_scale_mode != Window.CONTENT_SCALE_MODE_DISABLED or not is_equal_approx(get_window().content_scale_factor, factor):
		StudioTheme.apply_scale(get_window(), factor)
		if viewport != null:
			viewport._sync_view()

func _button(text: String, action: Callable, parent: Node) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(action)
	parent.add_child(button)
	return button

func _label(text: String, parent: Node, font_size := 13) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	parent.add_child(label)
	return label

func _build_ui() -> void:
	var margin := MarginContainer.new()
	editor_page = margin
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	add_child(margin)
	var column := VBoxContainer.new()
	margin.add_child(column)
	var header := HBoxContainer.new()
	column.add_child(header)
	_label("REMIX STUDIO", header, 16).modulate = Color("70d9c0")
	project_label = _label("No project", header)
	project_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	project_label.custom_minimum_size.x = 80
	project_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_button("Recent projects", _show_welcome, header)
	_button("New from capture", _new_capture, header)
	_button("Open", _choose_open, header)
	_button("Save", _save_from_ui, header)
	_button("Package mod", _choose_package, header)
	var toolbar := HFlowContainer.new()
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
	lights.get_popup().id_pressed.connect(func(id: int): _spawn_light(types[id]))
	_button("Duplicate", func(): _command({"op": "duplicate", "path": selection}), toolbar)
	_button("Delete", func(): _command({"op": "delete", "path": selection}), toolbar)
	var authoring_area := VSplitContainer.new()
	authoring_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	authoring_area.split_offset = 110
	column.add_child(authoring_area)
	var workspace := HSplitContainer.new()
	workspace.size_flags_vertical = Control.SIZE_EXPAND_FILL
	authoring_area.add_child(workspace)
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 210
	workspace.add_child(left)
	var capture_tools := HBoxContainer.new()
	left.add_child(capture_tools)
	_label("CAPTURE", capture_tools, 12).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_capture_button = _button("Add capture", _choose_add_capture, capture_tools)
	add_capture_button.disabled = true
	capture_picker = OptionButton.new()
	capture_picker.fit_to_longest_item = false
	capture_picker.clip_text = true
	capture_picker.disabled = true
	capture_picker.item_selected.connect(func(index: int):
		if not refreshing:
			_change_capture(capture_picker.get_item_metadata(index)))
	left.add_child(capture_picker)
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
	var center_right := HSplitContainer.new()
	center_right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	workspace.add_child(center_right)
	var center_panel := VBoxContainer.new()
	center_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center_right.add_child(center_panel)
	var view_tools := HFlowContainer.new()
	center_panel.add_child(view_tools)
	_label("Viewport", view_tools).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	render_toggle = CheckButton.new()
	render_toggle.text = "Remix"
	render_toggle.button_pressed = true
	render_toggle.toggled.connect(func(value: bool):
		viewport.show_render = value
		_sync_renderer())
	view_tools.add_child(render_toggle)
	camera_mode = OptionButton.new()
	camera_mode.add_item("Drone", LayoutView.CameraMode.DRONE)
	camera_mode.add_item("Orbit", LayoutView.CameraMode.ORBIT)
	camera_mode.tooltip_text = "Drone: press Z over the viewport for WASD movement and mouse look. Press Z or Escape to release."
	camera_mode.item_selected.connect(func(index: int): viewport.camera_mode = camera_mode.get_item_id(index))
	view_tools.add_child(camera_mode)
	var transform_tool := OptionButton.new()
	transform_tool.add_item("Move", 0); transform_tool.add_item("Rotate", 1)
	transform_tool.tooltip_text = "Drag the colored axes or rings. Snap uses 1 unit / 15°. Escape cancels a drag."
	transform_tool.item_selected.connect(func(index: int): viewport.gizmo.set_mode(index))
	view_tools.add_child(transform_tool)
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
		if renderer != null and renderer.is_ready and not restoring_view:
			renderer.send({"op": "camera", "camera": camera}))
	viewport.translation_requested.connect(_translate)
	viewport.transform_committed.connect(func(path: String, matrix: Array): _command({"op": "transform", "path": path, "world_matrix": matrix}))
	viewport.transform_preview_requested.connect(func(path: String, delta: Array):
		if renderer != null and renderer.is_ready:
			renderer.send({"op": "preview_transform", "path": path, "delta": delta, "revision": state.revision}))
	center_panel.add_child(viewport)
	_label("Drag axes to move or rings to rotate. Ctrl+T: place at cursor. Escape cancels. Captured attachments affect every instance.", center_panel, 11).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var right := VBoxContainer.new()
	right.custom_minimum_size.x = 260
	center_right.add_child(right)
	_label("PROPERTIES", right)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(scroll)
	inspector = AuthoringInspector.new()
	inspector.request = _request
	inspector.command_requested.connect(func(command: Dictionary): _command.call_deferred(command))
	inspector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(inspector)
	assets = AssetBrowser.new()
	authoring_area.add_child(assets)
	assets.message.connect(_log)
	assets.asset_selected.connect(func(id: String, details: Dictionary):
		library_selection = id
		inspector.show_asset(id, details))
	assets.asset_details_changed.connect(func(id: String, details: Dictionary):
		if library_selection == id:
			inspector.show_asset(id, details))
	assets.thumbnail_changed.connect(func(id: String, texture: Texture2D):
		if library_selection == id and inspector.library_image != null:
			inspector.library_image.texture = texture)
	assets.asset_activated.connect(func(kind: String): _use_asset("replace_material" if kind == "material" else "add_mesh"))
	var output_toggle := Button.new()
	output_toggle.text = "Show output"
	output_toggle.toggle_mode = true
	output_toggle.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	column.add_child(output_toggle)
	var output_panel := VBoxContainer.new()
	output_panel.visible = false
	column.add_child(output_panel)
	output_toggle.toggled.connect(func(expanded: bool):
		output_panel.visible = expanded
		output_toggle.text = "Hide output" if expanded else "Show output")
	output = RichTextLabel.new()
	output.custom_minimum_size.y = 56
	output.scroll_following = true
	output_panel.add_child(output)
	status = _label("", output_panel, 11)
	status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	welcome = WelcomeScreen.new(); add_child(welcome)
	welcome.browse.connect(_choose_open)
	welcome.create_project.connect(_new_capture)
	welcome.return_to_editor.connect(_show_editor)
	welcome.open_project.connect(func(path: String): _guard_unsaved(func(): _open_project(path)))
	welcome.remove_recent.connect(func(path: String): sessions.forget(path); welcome.refresh(sessions, state.get("open", false)))

func _log(message: String) -> void:
	status.text = message
	output.append_text(message + "\n")
	if welcome != null:
		welcome.notice.text = message

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
	if data.op == "open" and not FileAccess.file_exists(data.path):
		_log("Project file is missing: " + data.path)
		return
	if data.op in ["open", "create"]:
		_persist_camera()
	var previous_revision: int = state.get("revision", -1)
	var result := _request(data)
	if result.is_empty():
		if data.op in ["add_capture", "select_capture"]:
			_refresh_captures()
		if data.op in ["set_authoring_property", "reset_authoring_property", "set_light_type", "transform", "set_parent"] and library_selection.is_empty():
			_select(selection)
		return
	if result.has("selection"):
		selection = result.selection
	if result.has("document"):
		var capture_changed: bool = result.document.get("active_capture", "") != state.get("active_capture", "")
		if capture_changed and data.op not in ["open", "create"]:
			_persist_camera()
		if data.op in ["open", "create"] or capture_changed:
			inspector._clear(); inspector.schema_key = ""
			library_selection = ""; selection = ""; last_scene = {}
			viewport.set_mouse_capture(false); viewport.rendered_texture = null
		state = result.document
		_refresh(state.get("revision", -1) != previous_revision, result.get("scene_update") == "lights")
		if capture_changed:
			_sync_renderer()
	if data.op in ["open", "create"]:
		sessions.opened(state.path)
		_show_editor()
	if data.op == "save":
		_log("Project saved.")
		_save_view_and_preview()
	elif data.op == "package":
		_log("Mod packaged at " + data.path)

func _refresh(scene_changed := true, lights_only := false) -> void:
	refreshing = true
	_refresh_captures()
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
	# Inactive USD prims can still resolve by path, but are absent from the tree.
	if not selection.is_empty() and not entries.has(selection):
		selection = ""; library_selection = ""
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
	if library_selection.is_empty():
		_select(selection)
	if scene_changed and state.get("open", false):
		var first := last_scene.is_empty()
		lights_only = lights_only and not first
		if lights_only:
			var changes := _request({"op": "lights"})
			# Queued scene messages may still hold the old dictionary on the writer
			# thread. Share immutable geometry, but never mutate that dictionary.
			last_scene = last_scene.duplicate()
			last_scene["lights"] = changes.lights
			last_scene["revision"] = changes.revision
			for warning in changes.get("warnings", []): _log(warning)
		else:
			last_scene = _request({"op": "scene"})
			last_scene["geometry_revision"] = last_scene.revision
		restoring_view = first
		viewport.set_scene(last_scene, false, lights_only)
		if first:
			var camera = sessions.camera_for(state.path, state.get("active_capture", ""))
			if not viewport.restore_view_state(camera, false):
				viewport.reset_view()
			camera_mode.select(viewport.camera_mode)
		restoring_view = false
		if renderer.is_ready:
			if lights_only:
				renderer.send({"op": "lights", "lights": last_scene.lights, "revision": last_scene.revision, "geometry_revision": last_scene.geometry_revision})
			else:
				renderer.send({"op": "scene", "scene": last_scene})
				renderer.send({"op": "camera", "camera": viewport.camera()})
		if not lights_only:
			for warning in state.get("warnings", []) + last_scene.get("warnings", []): _log(warning)

func _tree_selected() -> void:
	if refreshing:
		return
	var item := tree.get_selected()
	if item:
		_select(item.get_metadata(0))

func _select(path: String) -> void:
	var details := _request({"op": "inspect", "path": path}) if not path.is_empty() else {}
	if details.is_empty(): path = ""
	selection = path
	library_selection = ""
	viewport.selected_path = path
	viewport.queue_redraw()
	inspector.project_directory = String(state.get("path", "")).get_base_dir()
	inspector.show_selection(details)
	viewport.gizmo.set_target(details)

func _spawn_light(type: String) -> void:
	var defaults := _request({"op": "light_defaults", "type": type})
	if defaults.is_empty(): return
	var pose: Transform3D = viewport.light_spawn_transform(type, defaults.properties)
	library_selection = ""
	_command({"op": "add_light", "type": type, "world_matrix": viewport.TransformGizmo.to_array(pose)})

func _place_selection_at_cursor() -> void:
	if selection.is_empty() or not state.get("open", false): return
	var position: Vector2 = viewport._view_rect().get_center() if viewport.mouse_captured else viewport.get_local_mouse_position()
	if not viewport._view_rect().has_point(position): return
	var details := _request({"op": "inspect", "path": selection})
	if not details.has("world_transform") or not details.get("authoring", {}).get("editable", false): return
	var hit: Dictionary = viewport.surface_at(position, selection)
	if hit.is_empty():
		_log("No surface under the cursor.")
		return
	viewport.gizmo.cancel()
	var pose: Transform3D = viewport.placement_transform(viewport.TransformGizmo.from_array(details.world_transform), hit, details)
	library_selection = ""
	_command({"op": "transform", "path": selection, "world_matrix": viewport.TransformGizmo.to_array(pose)})

func _translate(delta: Vector3) -> void:
	_command({"op": "transform", "path": selection, "world_delta": [delta.x, delta.y, delta.z]})

func _dialog(mode: FileDialog.FileMode, title: String, filters: PackedStringArray, callback: Callable) -> FileDialog:
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
	return dialog

func _guard_unsaved(action: Callable, canceled := Callable()) -> void:
	inspector._finish_editing()
	await get_tree().process_frame
	if not state.get("dirty", false):
		action.call()
		return
	var dialog := ConfirmationDialog.new()
	dialog.dialog_text = "This project has unsaved edits. Discard them?"
	dialog.ok_button_text = "Discard edits"
	add_child(dialog)
	dialog.confirmed.connect(func(): dialog.queue_free(); action.call())
	dialog.canceled.connect(func():
		dialog.queue_free()
		if canceled.is_valid(): canceled.call())
	dialog.popup_centered()

func _choose_open() -> void:
	_guard_unsaved(func(): _dialog(FileDialog.FILE_MODE_OPEN_FILE, "Open Toolkit project", ["*.usd,*.usda,*.usdc ; USD projects"], _open_project))

func _open_project(path: String) -> void:
	_command({"op": "open", "path": path})

func _refresh_captures() -> void:
	capture_picker.clear()
	add_capture_button.disabled = not state.get("open", false)
	for capture in state.get("captures", []):
		capture_picker.add_item(capture.name + (" (missing)" if capture.missing else ""))
		var index := capture_picker.item_count - 1
		capture_picker.set_item_metadata(index, capture.id)
		capture_picker.get_popup().set_item_tooltip(index, capture.path)
		capture_picker.set_item_disabled(index, capture.missing)
		if capture.active:
			capture_picker.select(index)
			capture_picker.tooltip_text = capture.path
	capture_picker.disabled = capture_picker.item_count == 0

func _choose_add_capture() -> void:
	if not state.get("open", false):
		return
	inspector._finish_editing()
	await get_tree().process_frame
	_dialog(FileDialog.FILE_MODE_OPEN_FILE, "Add capture to project", ["*.usd,*.usda,*.usdc ; Remix captures"], func(path: String): _change_capture(path, true))

func _change_capture(path: String, add := false) -> void:
	inspector._finish_editing()
	await get_tree().process_frame
	_command({"op": "add_capture" if add else "select_capture", "path": path})

func _new_capture() -> void:
	_guard_unsaved(func(): _dialog(FileDialog.FILE_MODE_OPEN_FILE, "Select Remix capture", ["*.usd,*.usda,*.usdc ; Remix captures"], func(path: String):
		pending_capture = path
		_dialog(FileDialog.FILE_MODE_SAVE_FILE, "Create project in a new directory", ["*.usda ; USD project"], func(project: String):
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
			import_folder = assets.current_folder
			import_project = String(state.path).get_base_dir()
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
	if not state.get("open", false):
		return
	var directory := String(state.path).get_base_dir()
	if assets.project_directory != directory:
		assets.open_project(directory)

func _use_asset(op: String) -> void:
	var ids: Array = assets.selected_ids()
	if ids.is_empty() or (op != "add_mesh" and selection.is_empty()):
		_log("Select a mesh asset first." if op == "add_mesh" else "Select a scene object and an asset first.")
		return
	var id: String = ids[0]
	var kind: String = assets.catalog.entries[id].get("kind", "unknown")
	if kind == "unknown":
		_log("Wait for the asset preview to finish identifying this asset.")
		return
	if (op == "replace_material") != (kind == "material"):
		_log("Choose a material for Replace material, or a mesh for Add / Replace mesh.")
		return
	if not assets.catalog.available(id):
		_log("This asset's files are missing.")
		return
	var target := selection
	if op == "replace_material" and not inspector.selected_material.is_empty():
		target = inspector.selected_material
	library_selection = ""
	var command := {"op": op, "asset": assets.catalog.absolute_path(id)}
	if op == "add_mesh":
		command["translation"] = viewport._array(viewport.center)
	else:
		command["path"] = target
	_command(command)

func _sync_renderer() -> void:
	if renderer == null:
		return
	var active: bool = editor_page.visible and viewport.show_render and state.get("open", false)
	renderer.set_process(active)
	if active and DisplayServer.get_name() != "headless":
		_start_renderer()

func _start_renderer() -> void:
	if renderer.is_ready or renderer.is_starting or is_instance_valid(runtime_dialog):
		return
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
		runtime_dialog = _dialog(FileDialog.FILE_MODE_OPEN_FILE, "Select Remix runtime library", [], _launch_renderer)

func _launch_renderer(library: String) -> void:
	runtime_path = library
	if not state.get("open", false) or not viewport.show_render or not editor_page.visible:
		return
	var worker := OS.get_environment("REMIX_RENDERER_WORKER")
	if worker.is_empty():
		worker = root_directory.path_join("build/remix-renderer" + (".exe" if OS.get_name() == "Windows" else ""))
	renderer.start_worker(worker, library)

func _renderer_response(response: Dictionary) -> void:
	if response.get("ok", false) and response.get("request_op") == "start":
		renderer.send({"op": "scene", "scene": last_scene})
		renderer.send({"op": "camera", "camera": viewport.camera()})

func _process(_delta: float) -> void:
	if import_running and document != null:
		var response: String = document.poll_ingestion()
		if not response.is_empty():
			import_running = false
			var result = JSON.parse_string(response)
			if result.get("ok", false):
				_log("Asset ingested: " + result.result.asset)
				for warning in result.result.get("warnings", []):
					_log(warning)
				if assets.project_directory == import_project:
					assets.register_ingestion(result.result.asset, import_folder)
			else:
				_log(result.get("error", "Ingestion failed"))

func _unhandled_key_input(event: InputEvent) -> void:
	if welcome.visible:
		return
	if not event.is_pressed() or event.is_echo() or get_viewport().gui_get_focus_owner() is LineEdit or get_viewport().gui_get_focus_owner() is TextEdit:
		return
	if event is InputEventKey:
		if event.is_command_or_control_pressed():
			if event.keycode == KEY_T and not event.alt_pressed and not event.shift_pressed:
				_place_selection_at_cursor()
				get_viewport().set_input_as_handled()
			elif event.keycode == KEY_S:
				_save_from_ui()
			elif event.keycode == KEY_Z:
				_command({"op": "redo" if event.shift_pressed else "undo"})
		elif event.keycode == KEY_F:
			viewport.frame_selection()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and not close_pending:
		close_pending = true
		viewport.set_mouse_capture(false)
		_guard_unsaved(_finish_close, func(): close_pending = false)

func _show_welcome() -> void:
	viewport.set_mouse_capture(false)
	editor_page.hide(); welcome.show()
	welcome.refresh(sessions, state.get("open", false))
	if renderer != null:
		renderer.set_process(false)

func _show_editor() -> void:
	welcome.hide(); editor_page.show()
	viewport._sync_view()
	_sync_renderer()

func _save_from_ui() -> void:
	if save_pending:
		return
	save_pending = true
	inspector._finish_editing()
	await get_tree().process_frame
	_command({"op": "save"})
	save_pending = false

func _persist_camera(saved_at := 0.0) -> bool:
	if state.get("open", false):
		return sessions.save_view(state.path, viewport.view_state(), saved_at, state.get("active_capture", ""))
	return true

func _save_view_and_preview() -> void:
	var saved_at := Time.get_unix_time_from_system()
	if not _persist_camera(saved_at):
		return
	if DisplayServer.get_name() == "headless":
		return
	var path: String = state.path
	var serial: int = save_serials.get(path, 0) + 1
	save_serials[path] = serial
	var image: Image
	if viewport.show_render and renderer.is_ready and renderer.presented_context.get("revision", -1) == state.revision and renderer.presented_context.get("camera", {}) == viewport.camera() and viewport.rendered_texture != null:
		image = viewport.rendered_texture.get_image()
	var thumbnail_view: SubViewport
	if image == null or image.is_empty():
		thumbnail_view = viewport.create_thumbnail_view()
		add_child(thumbnail_view)
	preview_jobs += 1
	_complete_preview(path, saved_at, serial, image, thumbnail_view)

func _complete_preview(path: String, saved_at: float, serial: int, image: Image, thumbnail_view: SubViewport) -> void:
	if thumbnail_view != null:
		for i in range(2):
			await RenderingServer.frame_post_draw
		image = thumbnail_view.get_texture().get_image()
		thumbnail_view.queue_free()
	if save_serials.get(path) == serial and image != null and not image.is_empty():
		var factor := minf(384.0 / image.get_width(), 216.0 / image.get_height())
		image.convert(Image.FORMAT_RGBA8)
		image.resize(maxi(1, int(image.get_width() * factor)), maxi(1, int(image.get_height() * factor)))
		var fitted := Image.create(384, 216, false, Image.FORMAT_RGBA8)
		fitted.fill(Color("111820"))
		fitted.blend_rect(image, Rect2i(Vector2i.ZERO, image.get_size()), (fitted.get_size() - image.get_size()) / 2)
		sessions.save_thumbnail(path, fitted, saved_at)
	preview_jobs -= 1
	if welcome.visible:
		welcome.refresh(sessions, state.get("open", false))

func _prepare_close() -> void:
	_persist_camera()
	var deadline := Time.get_ticks_msec() + 2000
	while preview_jobs > 0 and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame

func _finish_close() -> void:
	await _prepare_close()
	get_tree().quit()
