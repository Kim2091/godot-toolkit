extends RefCounted

static func create() -> Theme:
	var skin := Theme.new()
	skin.default_font_size = 13
	var panel := StyleBoxFlat.new()
	panel.bg_color = Color("1b2530")
	panel.set_corner_radius_all(3)
	panel.content_margin_left = 6; panel.content_margin_right = 6
	panel.content_margin_top = 3; panel.content_margin_bottom = 3
	var hover := panel.duplicate(); hover.bg_color = Color("2c414e")
	var active := panel.duplicate(); active.bg_color = Color("236354")
	var focus := panel.duplicate(); focus.bg_color = Color.TRANSPARENT
	focus.set_border_width_all(1); focus.border_color = Color("70d9c0")
	for type in ["Button", "OptionButton", "MenuButton", "CheckButton", "CheckBox", "ColorPickerButton"]:
		skin.set_stylebox("normal", type, panel)
		skin.set_stylebox("hover", type, hover)
		skin.set_stylebox("pressed", type, active)
		skin.set_stylebox("hover_pressed", type, active)
		skin.set_stylebox("disabled", type, panel)
		skin.set_stylebox("focus", type, focus)
		skin.set_color("font_color", type, Color("deebf0"))
	var field := panel.duplicate(); field.bg_color = Color("11151a")
	for type in ["LineEdit", "SpinBox"]:
		skin.set_stylebox("normal", type, field)
		skin.set_stylebox("read_only", type, field)
	skin.set_color("font_color", "Label", Color("c3d1df"))
	for type in ["HBoxContainer", "VBoxContainer", "GridContainer", "HFlowContainer", "VFlowContainer"]:
		for constant in ["separation", "h_separation", "v_separation"]:
			skin.set_constant(constant, type, 4)
	skin.set_constant("v_separation", "Tree", 2)
	skin.set_constant("v_separation", "ItemList", 4)
	return skin

static func apply_scale(window: Window, factor: float) -> void:
	window.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	window.content_scale_size = Vector2i.ZERO
	window.content_scale_factor = factor if is_finite(factor) and factor > 0 else 1.0
