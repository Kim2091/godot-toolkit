extends ConfirmationDialog

signal settings_applied(settings: Dictionary)
const Settings = preload("res://scripts/render_settings.gd")
const RESOLUTIONS := [Vector2i(960, 540), Vector2i(1280, 720), Vector2i(1600, 900), Vector2i(1920, 1080), Vector2i(2560, 1440), Vector2i(3840, 2160)]
var upscaler := OptionButton.new()
var quality := OptionButton.new()
var reconstruction := CheckButton.new()
var reconstruction_label := Label.new()
var resolution := OptionButton.new()
var width := SpinBox.new()
var height := SpinBox.new()
var notice := Label.new()
var capabilities: Dictionary = {}
var remembered_rr := true

func _ready() -> void:
	title = "Remix render settings"
	ok_button_text = "Apply"
	dialog_hide_on_ok = false
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	add_child(column)
	var intro := Label.new()
	intro.text = "Saved for all projects on this computer."
	column.add_child(intro)
	var grid := GridContainer.new(); grid.columns = 2
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 8)
	column.add_child(grid)
	_row(grid, "Upscaler", upscaler)
	for key in Settings.UPSCALERS:
		upscaler.add_item(Settings.UPSCALERS[key])
		upscaler.set_item_metadata(upscaler.item_count - 1, key)
	_row(grid, "Quality preset", quality)
	reconstruction_label.text = "Ray Reconstruction"
	grid.add_child(reconstruction_label); grid.add_child(reconstruction)
	reconstruction.tooltip_text = "DLSS AI denoising. Requires a supported NVIDIA GPU and DLSS upscaling."
	_row(grid, "Viewport resolution", resolution)
	for pixels in RESOLUTIONS: resolution.add_item("%d × %d" % [pixels.x, pixels.y])
	resolution.add_item("Custom")
	var dimensions := HBoxContainer.new()
	_row(grid, "Width × height (pixels)", dimensions)
	for box in [width, height]:
		box.min_value = 16; box.max_value = 8192; box.step = 1
		box.custom_minimum_size.x = 100
		dimensions.add_child(box)
		box.value_changed.connect(func(_value: float): _match_resolution())
	var hint := Label.new()
	hint.text = "Resolution changes restart the viewport."
	column.add_child(hint)
	notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	notice.custom_minimum_size.x = 430
	column.add_child(notice)
	upscaler.item_selected.connect(func(_index: int): _refresh_quality(); _refresh_capabilities())
	resolution.item_selected.connect(func(index: int):
		if index < RESOLUTIONS.size():
			width.set_value_no_signal(RESOLUTIONS[index].x)
			height.set_value_no_signal(RESOLUTIONS[index].y))
	reconstruction.toggled.connect(func(enabled: bool): remembered_rr = enabled)
	confirmed.connect(func(): settings_applied.emit(selected_settings()))

func _row(grid: GridContainer, text: String, control: Control) -> void:
	var label := Label.new(); label.text = text; grid.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(control)

func show_settings(values: Dictionary, support: Dictionary) -> void:
	capabilities = support.duplicate()
	_select(upscaler, values.upscaler)
	_refresh_quality(values.quality)
	remembered_rr = values.ray_reconstruction
	width.set_value_no_signal(values.width); height.set_value_no_signal(values.height)
	_match_resolution()
	_refresh_capabilities()
	popup_centered()

func set_capabilities(support: Dictionary) -> void:
	capabilities = support.duplicate()
	_refresh_capabilities()

func _select(control: OptionButton, key: String) -> bool:
	for i in control.item_count:
		if control.get_item_metadata(i) == key:
			control.select(i); return true
	return false

func _refresh_quality(preferred := "") -> void:
	if preferred.is_empty() and quality.selected >= 0:
		preferred = quality.get_selected_metadata()
	quality.clear()
	for key in Settings.qualities_for(upscaler.get_selected_metadata()):
		quality.add_item(Settings.QUALITIES[key])
		quality.set_item_metadata(quality.item_count - 1, key)
	if not _select(quality, preferred): _select(quality, "balanced")
	quality.disabled = quality.item_count <= 1

func _refresh_capabilities() -> void:
	var choice: String = upscaler.get_selected_metadata()
	var dlss: bool = capabilities.get("dlss", false)
	for i in upscaler.item_count:
		var key: String = upscaler.get_item_metadata(i)
		var unavailable: bool = (key == "dlss" and not dlss) or (key == "nis" and not capabilities.get("nis", false))
		upscaler.set_item_disabled(i, unavailable)
		upscaler.set_item_tooltip(i, "Unavailable on the active GPU/runtime" if unavailable else "")
	var rr: bool = capabilities.get("ray_reconstruction", false)
	reconstruction.visible = rr; reconstruction_label.visible = rr
	reconstruction.disabled = choice not in ["auto", "dlss"]
	reconstruction.set_pressed_no_signal(remembered_rr and not reconstruction.disabled)
	if capabilities.is_empty():
		notice.text = "GPU options become available when Remix starts."
	elif not dlss:
		notice.text = "DLSS is unavailable on the active GPU/runtime. Automatic and saved DLSS settings use TAAU."
	else:
		notice.text = "DLSS and Ray Reconstruction are available." if rr else "DLSS is available. Ray Reconstruction is unavailable."
	if choice == "nis" and not capabilities.is_empty() and not capabilities.get("nis", false):
		notice.text = "NIS is unavailable in this runtime. The saved selection uses TAAU."

func _match_resolution() -> void:
	var index := RESOLUTIONS.find(Vector2i(int(width.value), int(height.value)))
	resolution.select(index if index >= 0 else RESOLUTIONS.size())

func selected_settings() -> Dictionary:
	# Commit a SpinBox's pending text even if Apply is clicked before focus leaves it.
	width.apply(); height.apply()
	return {"upscaler": upscaler.get_selected_metadata(), "quality": quality.get_selected_metadata(),
		"ray_reconstruction": remembered_rr, "width": int(width.value), "height": int(height.value)}
