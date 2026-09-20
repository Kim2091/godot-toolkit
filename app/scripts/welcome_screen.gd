extends MarginContainer

signal open_project(path: String)
signal browse
signal create_project
signal return_to_editor
signal remove_recent(path: String)
var cards: HFlowContainer
var back: Button
var notice: Label
var empty: Label

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		add_theme_constant_override("margin_" + side, 24)
	var column := VBoxContainer.new(); add_child(column)
	var heading := Label.new(); heading.text = "REMIX STUDIO"
	heading.add_theme_font_size_override("font_size", 24); heading.modulate = Color("70d9c0"); column.add_child(heading)
	var actions := HFlowContainer.new(); column.add_child(actions)
	_button("Open project…", func(): browse.emit(), actions)
	_button("New from capture…", func(): create_project.emit(), actions)
	back = _button("Return to project", func(): return_to_editor.emit(), actions)
	var title := Label.new(); title.text = "Recent projects"; title.add_theme_font_size_override("font_size", 18); column.add_child(title)
	var scroll := ScrollContainer.new(); scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED; column.add_child(scroll)
	cards = HFlowContainer.new(); cards.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cards.add_theme_constant_override("h_separation", 12); cards.add_theme_constant_override("v_separation", 12); scroll.add_child(cards)
	empty = Label.new(); empty.text = "Open a project or create one from a Remix capture to get started."; column.add_child(empty)
	notice = Label.new(); notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; column.add_child(notice)

func _button(text: String, action: Callable, parent: Node) -> Button:
	var button := Button.new(); button.text = text; button.pressed.connect(action); parent.add_child(button)
	return button

func _text(text: String, parent: Node) -> Label:
	var label := Label.new(); label.text = text; label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.tooltip_text = text; parent.add_child(label); return label

func refresh(sessions: RefCounted, has_project: bool) -> void:
	for child in cards.get_children():
		child.free()
	back.visible = has_project
	empty.visible = sessions.recent.is_empty()
	for entry in sessions.recent:
		var path: String = entry.path
		var available := FileAccess.file_exists(path)
		var panel := PanelContainer.new(); panel.custom_minimum_size.x = 256; cards.add_child(panel)
		var body := VBoxContainer.new(); panel.add_child(body)
		var preview := TextureRect.new(); preview.custom_minimum_size = Vector2(256, 144)
		preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE; preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		body.add_child(preview)
		var image := Image.new()
		var thumbnail := path + ".studio.png"
		if FileAccess.file_exists(thumbnail) and image.load(thumbnail) == OK:
			preview.texture = ImageTexture.create_from_image(image)
		else:
			var placeholder := Label.new(); placeholder.text = "No saved preview"
			placeholder.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; placeholder.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			placeholder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); preview.add_child(placeholder)
		_text(path.get_file(), body).add_theme_font_size_override("font_size", 14)
		_text(path.get_base_dir(), body)
		var metadata: Dictionary = sessions.read_view(path)
		var saved = metadata.get("preview_saved_at", metadata.get("last_saved", 0))
		var saved_label := "Save to capture a preview"
		if (saved is float or saved is int) and is_finite(saved) and saved > 0:
			saved_label = "Saved " + Time.get_datetime_string_from_unix_time(int(saved)).replace("T", " ") + " UTC"
		_text(saved_label if available else "Project file is missing", body)
		var actions := HBoxContainer.new(); body.add_child(actions)
		var open := _button("Open", func(): open_project.emit(path), actions)
		open.disabled = not available; open.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_button("Remove", func(): remove_recent.emit(path), actions).tooltip_text = "Remove from recents; keep all project files"
		preview.gui_input.connect(func(event: InputEvent):
			if available and event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
				open_project.emit(path))
