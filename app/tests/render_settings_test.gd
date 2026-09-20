extends SceneTree
const Settings = preload("res://scripts/render_settings.gd")
const Dialog = preload("res://scripts/render_settings_dialog.gd")
var failures := 0

func check(condition: bool, message: String) -> void:
	if not condition:
		push_error(message); failures += 1

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var path := ProjectSettings.globalize_path("res://../.work/render-settings/%d/preferences.json" % Time.get_ticks_usec())
	var settings := Settings.new(path); settings.load_settings()
	check(settings.values == Settings.DEFAULTS, "Missing preferences use defaults")
	var desired := {"upscaler": "dlss", "quality": "quality", "ray_reconstruction": false, "width": 1536, "height": 864}
	check(settings.save_settings(desired), "Persist render preferences")
	var reopened := Settings.new(path); reopened.load_settings()
	check(reopened.values == desired, "All settings survive a new session")
	var invalid := {"upscaler": "broken", "quality": [], "ray_reconstruction": "false", "width": -1, "height": 8193}
	check(Settings.sanitized(invalid) == Settings.DEFAULTS, "Reject malformed values")
	for value in [null, true, "1280", INF, 16.5, -4294966336.0]:
		check(Settings.sanitized({"width": value}).width == 960, "Invalid resolution must fall back safely")
	var file := FileAccess.open(path, FileAccess.WRITE); file.store_string("{broken"); file.close()
	reopened.load_settings()
	check(reopened.values == Settings.DEFAULTS, "Corrupt preferences recover")
	settings.path = path.path_join("blocked.json")
	check(not settings.save_settings(Settings.DEFAULTS) and settings.values == desired, "Failed save preserves active preferences")
	var dialog := Dialog.new(); root.add_child(dialog)
	dialog.show_settings(desired, {})
	await process_frame; await process_frame
	check(not dialog.reconstruction.visible and dialog.selected_settings() == desired, "Unknown GPU hides RR without discarding saved settings")
	dialog.set_capabilities({"dlss": false, "ray_reconstruction": false, "nis": false})
	check(dialog.upscaler.is_item_disabled(1) and not dialog.reconstruction.visible, "Unsupported GPU cannot enable DLSS or RR")
	dialog.set_capabilities({"dlss": true, "ray_reconstruction": true})
	check(not dialog.upscaler.is_item_disabled(1) and dialog.reconstruction.visible and not dialog.reconstruction.disabled, "Capable GPU exposes RR")
	dialog.reconstruction.button_pressed = true
	dialog._select(dialog.upscaler, "taau"); dialog.upscaler.item_selected.emit(dialog.upscaler.selected)
	check(dialog.reconstruction.disabled and not dialog.reconstruction.button_pressed, "RR requires DLSS")
	dialog._select(dialog.upscaler, "dlss"); dialog.upscaler.item_selected.emit(dialog.upscaler.selected)
	check(dialog.reconstruction.button_pressed, "Switching upscalers retains the RR preference")
	dialog._select(dialog.upscaler, "none"); dialog.upscaler.item_selected.emit(dialog.upscaler.selected)
	check(dialog.quality.disabled and dialog.quality.get_selected_metadata() == "native", "Native output has no upscaler quality choices")
	dialog.width.get_line_edit().text = "1600"; dialog.height.get_line_edit().text = "900"
	var pending := dialog.selected_settings()
	check(pending.width == 1600 and pending.height == 900 and dialog.resolution.selected == 2, "Apply commits typed dimensions and matches the resolution preset")
	dialog.hide(); dialog.show_settings(desired, {})
	await process_frame; await process_frame
	check(dialog.selected_settings() == desired, "Reopening discards uncommitted dialog edits")
	dialog.queue_free()
	print("Render settings: %d failures" % failures)
	quit(1 if failures else 0)
