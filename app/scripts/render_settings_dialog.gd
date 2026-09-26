extends ConfirmationDialog

signal settings_applied(settings: Dictionary)
const Settings = preload("res://scripts/render_settings.gd")
const RESOLUTIONS := [Vector2i(960, 540), Vector2i(1280, 720), Vector2i(1600, 900), Vector2i(1920, 1080), Vector2i(2560, 1440), Vector2i(3840, 2160)]
var renderer_id := "remix"
var backend := OptionButton.new()
var backend_label := Label.new()
var upscaler := OptionButton.new()
var quality := OptionButton.new()
var reconstruction := CheckButton.new()
var reconstruction_label := Label.new()
var resolution := OptionButton.new()
var width := SpinBox.new()
var height := SpinBox.new()
var notice := Label.new()
var tabs := TabContainer.new()
var advanced_controls: Dictionary = {}
var runtime_notice := Label.new()
var effective: Dictionary = {}
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
	column.add_child(tabs)
	var output := VBoxContainer.new(); output.name = "Output"
	tabs.add_child(output)
	var grid := GridContainer.new(); grid.columns = 2
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 8)
	output.add_child(grid)
	backend_label.text = "Mode"; grid.add_child(backend_label); grid.add_child(backend)
	backend.add_item("Path tracing"); backend.set_item_metadata(0, "pathtrace")
	backend.add_item("Raster (does not evaluate lights)"); backend.set_item_metadata(1, "raster")
	backend.item_selected.connect(func(_index: int): _refresh_capabilities())
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
	output.add_child(hint)
	_build_advanced_tabs()
	notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	notice.custom_minimum_size.x = 430
	column.add_child(notice)
	runtime_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	runtime_notice.custom_minimum_size.x = 430
	column.add_child(runtime_notice)
	upscaler.item_selected.connect(func(_index: int): _refresh_quality(); _refresh_capabilities())
	resolution.item_selected.connect(func(index: int):
		if index < RESOLUTIONS.size():
			width.set_value_no_signal(RESOLUTIONS[index].x)
			height.set_value_no_signal(RESOLUTIONS[index].y))
	reconstruction.toggled.connect(func(enabled: bool): remembered_rr = enabled; _refresh_advanced())
	confirmed.connect(func(): settings_applied.emit(selected_settings()))

func _build_advanced_tabs() -> void:
	var grids := {}
	for option in Settings.OpenRemix.options:
		if not grids.has(option.group):
			var scroll := ScrollContainer.new(); scroll.name = option.group
			scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
			tabs.add_child(scroll)
			var grid := GridContainer.new(); grid.columns = 2
			grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			grid.add_theme_constant_override("h_separation", 16)
			grid.add_theme_constant_override("v_separation", 8)
			scroll.add_child(grid); grids[option.group] = grid
		var control: Control
		if option.has("choices"):
			var choices := OptionButton.new()
			for key in option.choices:
				choices.add_item(option.choices[key]); choices.set_item_metadata(choices.item_count - 1, key)
			choices.item_selected.connect(func(_index: int): _refresh_advanced())
			control = choices
		elif option.default is bool:
			var toggle := CheckButton.new()
			toggle.toggled.connect(func(_enabled: bool): _refresh_advanced())
			control = toggle
		else:
			var number := SpinBox.new()
			number.min_value = option.min; number.max_value = option.max; number.step = option.step
			number.value_changed.connect(func(_value: float): _refresh_advanced())
			control = number
		control.tooltip_text = option.hint
		_row(grids[option.group], option.label, control)
		advanced_controls[option.key] = control
	var reset := Button.new(); reset.text = "Reset advanced settings"
	grids.Display.add_child(reset)
	reset.pressed.connect(func(): _set_advanced(Settings.OpenRemix.defaults()); _refresh_advanced())

func _set_advanced(values: Dictionary) -> void:
	for option in Settings.OpenRemix.options:
		var control: Control = advanced_controls[option.key]
		var value = values.get(option.key, option.default)
		if control is OptionButton: _select(control, str(value))
		elif control is CheckButton: control.set_pressed_no_signal(value)
		else:
			control.set_value_no_signal(value)
			# Hidden tabs do not redraw their line edits until first displayed.
			# Apply must not read the old minimum from an unopened tab.
			control.get_line_edit().text = str(value)

func _advanced_values() -> Dictionary:
	var result := {}
	for option in Settings.OpenRemix.options:
		var control: Control = advanced_controls[option.key]
		if control is OptionButton:
			var value = control.get_selected_metadata()
			result[option.key] = value if option.default is String else int(value)
		elif control is CheckButton: result[option.key] = control.button_pressed
		else: result[option.key] = int(control.value) if option.step == 1 else control.value
	return result

func _refresh_advanced() -> void:
	if renderer_id != "openremix": return
	var values := _advanced_values()
	var raster: bool = backend.get_selected_metadata() == "raster"
	var rr: bool = remembered_rr and capabilities.get("ray_reconstruction", false) and upscaler.get_selected_metadata() in ["auto", "dlss"] and not values.accumulate
	for key in advanced_controls:
		var disabled: bool = raster
		if key in ["denoiser", "localDenoiser", "sigma", "blueNoiseShadows", "blueNoiseLocalLights", "localFireflyFilter"]:
			disabled = disabled or rr or values.accumulate
		if key in ["localDenoiser", "localFireflyFilter"]: disabled = disabled or values.denoiser == "off"
		if key == "taa": disabled = disabled or values.accumulate or upscaler.get_selected_metadata() != "none"
		if key == "sharc" or key.begins_with("sharc"): disabled = disabled or values.accumulate or values.bounces == 0
		if key != "sharc" and key.begins_with("sharc"): disabled = disabled or not values.sharc
		if key == "rouletteMinBounces": disabled = disabled or not values.russianRoulette
		if key == "waterIndirectReuse": disabled = disabled or rr or values.accumulate or values.indirectClamp > 0
		if key == "pbrLocalReuse": disabled = disabled or rr or values.accumulate or values.indirectClamp > 0 or values.localDirectClamp > 0
		if key == "fsrSharpness": disabled = disabled or upscaler.get_selected_metadata() not in ["auto", "fsr31"]
		var control: Control = advanced_controls[key]
		if control is SpinBox: control.editable = not disabled
		else: control.disabled = disabled
	_refresh_runtime()

func set_effective_settings(settings: Dictionary) -> void:
	effective = settings.duplicate(true)
	_refresh_runtime()

func _refresh_runtime() -> void:
	runtime_notice.visible = renderer_id == "openremix"
	if not runtime_notice.visible: return
	var lines: Array[String] = []
	var values := _advanced_values()
	if backend.get_selected_metadata() == "raster":
		lines.append("Raster does not evaluate lighting or path tracing settings.")
	elif values.accumulate:
		lines.append("Progressive reference rendering bypasses NRD, reconstruction, TAA and SHARC.")
	elif remembered_rr and upscaler.get_selected_metadata() in ["auto", "dlss"]:
		lines.append("When RR is active it replaces NRD/SIGMA. Saved filter settings resume without RR.")
	else:
		lines.append("REBLUR includes anti-firefly processing. The PBR firefly filter is an additional opt-in filter.")
	var state: Dictionary = effective.get("runtime", {})
	if state.is_empty():
		lines.append("Live filter and cache status appears after the viewport renders.")
	elif effective.get("backend") == "raster":
		lines.append("Live viewport: Raster — lighting and temporal filters inactive.")
	else:
		var cache := "Caching" if state.get("sharc_caching", false) else "Enabled (idle)" if state.get("sharc", false) else "Off"
		var filter := "On" if state.get("local_firefly_filter", false) else "Inactive" if effective.get("pathtrace", {}).get("localFireflyFilter", false) else "Off"
		var reconstruction_name: String = {"none": "Native", "fsr31": "FSR 3.1", "dlss": "DLSS SR"}.get(effective.get("upscaler", "none"), "Native")
		lines.append("Live viewport: %s · NRD %s · SIGMA %s · TAA %s\nPBR firefly filter: %s · SHARC: %s" % [
			"DLSS RR" if effective.get("ray_reconstruction", false) else reconstruction_name,
			"On" if state.get("nrd", false) else "Off", "On" if state.get("sigma", false) else "Off",
			"On" if state.get("taa", false) else "Off", filter, cache])
		for key in ["denoising_reason", "sigma_reason", "sharc_reason"]:
			var reason: String = state.get(key, "")
			if not reason.is_empty() and reason not in lines: lines.append(reason)
	var fallback: String = effective.get("fallback_reason", "")
	if not fallback.is_empty(): lines.append(fallback)
	runtime_notice.text = "\n".join(lines)

func _row(grid: GridContainer, text: String, control: Control) -> void:
	var label := Label.new(); label.text = text; grid.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(control)

func show_settings(values: Dictionary, support: Dictionary, selected_renderer := "remix", active_settings: Dictionary = {}) -> void:
	renderer_id = selected_renderer
	effective = active_settings.duplicate(true)
	tabs.current_tab = 0
	tabs.tabs_visible = renderer_id == "openremix"
	for i in range(1, tabs.get_tab_count()): tabs.set_tab_hidden(i, renderer_id != "openremix")
	tabs.custom_minimum_size = Vector2(700, 350) if renderer_id == "openremix" else Vector2.ZERO
	notice.custom_minimum_size.x = 700 if renderer_id == "openremix" else 430
	runtime_notice.custom_minimum_size.x = notice.custom_minimum_size.x
	_set_advanced(values.get("pathtrace", Settings.OpenRemix.defaults()))
	title = "%s render settings" % ("OpenRemix" if renderer_id == "openremix" else "Remix")
	backend.visible = renderer_id == "openremix"; backend_label.visible = backend.visible
	_select(backend, values.get("backend", "pathtrace"))
	upscaler.clear()
	var choices: Dictionary = Settings.OPENREMIX_UPSCALERS if renderer_id == "openremix" else Settings.UPSCALERS
	for key in choices:
		upscaler.add_item(choices[key]); upscaler.set_item_metadata(upscaler.item_count - 1, key)
	capabilities = support.duplicate()
	_select(upscaler, values.upscaler)
	_refresh_quality(values.quality)
	remembered_rr = values.ray_reconstruction
	width.set_value_no_signal(values.width); height.set_value_no_signal(values.height)
	_match_resolution()
	_refresh_capabilities()
	size = Vector2i.ZERO
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
		var unavailable: bool = (key == "dlss" and not dlss) or (key == "nis" and not capabilities.get("nis", false)) or (key == "fsr31" and not capabilities.get("fsr31", false))
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

	if renderer_id == "openremix":
		if capabilities.is_empty(): notice.text = "GPU options become available when OpenRemix starts."
		elif backend.get_selected_metadata() == "raster": notice.text = "Raster mode does not evaluate lights."
		elif not capabilities.get("pathtrace", false): notice.text = "Path tracing is unavailable. The viewport uses raster; your preference is retained."
		elif not dlss: notice.text = "DLSS is unavailable. Automatic and saved DLSS preferences use FSR when supported, otherwise native resolution."
		if choice == "fsr31" and not capabilities.is_empty() and not capabilities.get("fsr31", false): notice.text = "FSR is unavailable. The viewport uses native resolution."
	_refresh_advanced()
	_refresh_runtime()

func _match_resolution() -> void:
	var index := RESOLUTIONS.find(Vector2i(int(width.value), int(height.value)))
	resolution.select(index if index >= 0 else RESOLUTIONS.size())

func selected_settings() -> Dictionary:
	# Commit a SpinBox's pending text even if Apply is clicked before focus leaves it.
	width.apply(); height.apply()
	var result := {"upscaler": upscaler.get_selected_metadata(), "quality": quality.get_selected_metadata(),
		"ray_reconstruction": remembered_rr, "width": int(width.value), "height": int(height.value)}

	if renderer_id == "openremix":
		for control in advanced_controls.values():
			if control is SpinBox: control.apply()
		result.backend = backend.get_selected_metadata()
		result.pathtrace = _advanced_values()
	return result
