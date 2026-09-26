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
	check(settings.select_renderer("openremix"), "Select OpenRemix")
	check(settings.values == Settings.OPENREMIX_DEFAULTS, "OpenRemix defaults to path tracing")
	check(settings.save_settings({"backend": "raster", "upscaler": "fsr31", "width": 640, "height": 360}), "Save independent OpenRemix settings")
	reopened.load_settings()
	check(reopened.renderer == "openremix" and reopened.values.backend == "raster", "Persist renderer selection")
	var app: Control = load("res://main.tscn").instantiate()
	app.render_settings = Settings.new(path)
	root.add_child(app)
	check(app.renderer_select.selected == 1 and app.render_settings.renderer == "openremix", "Cold startup dropdown matches persisted renderer")
	app.queue_free(); await process_frame
	check(settings.select_renderer("remix") and settings.values == desired, "Switching restores Remix preferences")
	var legacy := FileAccess.open(path, FileAccess.WRITE)
	legacy.store_string(JSON.stringify({"version": 1, "settings": desired})); legacy.close()
	reopened.load_settings()
	check(reopened.renderer == "remix" and reopened.values == desired, "Migrate legacy preferences to Remix")
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
	dialog.hide(); dialog.show_settings(Settings.OPENREMIX_DEFAULTS, {"pathtrace": false, "dlss": false, "fsr31": false}, "openremix")
	await process_frame; await process_frame
	check(dialog.notice.text.contains("raster") and dialog.selected_settings() == Settings.OPENREMIX_DEFAULTS, "OpenRemix fallbacks preserve saved preferences")
	var advanced := Settings.OPENREMIX_DEFAULTS.duplicate(true)
	advanced.upscaler = "none"; advanced.quality = "native"; advanced.ray_reconstruction = false
	advanced.pathtrace.localFireflyFilter = true; advanced.pathtrace.sharcDownscale = 3
	settings.path = path
	check(settings.select_renderer("openremix"), "Select renderer for advanced persistence")
	check(settings.save_settings(advanced), "Save advanced tracing preferences")
	reopened.load_settings()
	check(reopened.values == advanced, "Advanced preferences persist without sharing the defaults dictionary")
	check(Settings.OPENREMIX_DEFAULTS.pathtrace.sharcDownscale == 5, "Editing preferences cannot mutate defaults")
	var sanitized := Settings.sanitized({"pathtrace": {"samples": 1.5, "localFireflyFilter": "true", "sharcCapacityLog2": 23, "sharcReset": true}}, "openremix")
	check(sanitized == Settings.OPENREMIX_DEFAULTS, "Invalid advanced settings and runtime actions do not enter saved preferences")
	dialog.hide(); dialog.show_settings(advanced, {"pathtrace": true, "dlss": true, "ray_reconstruction": true, "nrd": true}, "openremix")
	await process_frame
	check(dialog.selected_settings() == advanced, "Unopened advanced tabs preserve every value on Apply")
	check(not dialog.advanced_controls.localFireflyFilter.disabled, "REBLUR without RR exposes the firefly filter")
	dialog._select(dialog.upscaler, "dlss"); dialog.upscaler.item_selected.emit(dialog.upscaler.selected)
	dialog.reconstruction.button_pressed = true
	check(dialog.advanced_controls.localFireflyFilter.disabled and dialog.advanced_controls.denoiser.disabled, "RR bypasses the saved NRD controls")
	check(dialog.selected_settings().pathtrace.localFireflyFilter, "RR does not clear the saved firefly preference")
	dialog.reconstruction.button_pressed = false
	check(not dialog.advanced_controls.localFireflyFilter.disabled, "Disabling RR restores NRD controls")
	dialog.advanced_controls.sharc.button_pressed = false
	check(not dialog.advanced_controls.sharcDownscale.editable, "Disabled SHARC retains but disables cache tuning")
	dialog.advanced_controls.sharcDownscale.get_line_edit().text = "7"
	check(dialog.selected_settings().pathtrace.sharcDownscale == 7, "Apply commits advanced numeric text")
	dialog.set_effective_settings({"backend": "pathtrace", "upscaler": "none", "runtime": {"nrd": true, "sharc": true, "sharc_caching": false}})
	check(dialog.runtime_notice.text.contains("Enabled (idle)") and dialog.runtime_notice.text.contains("NRD On"), "Live runtime status distinguishes enabled idle cache from filtering")
	check(not dialog.advanced_controls.sharc.button_pressed, "Live status must not overwrite unapplied edits")
	dialog.hide(); dialog.show_settings(desired, {}, "remix")
	check(not dialog.tabs.tabs_visible and not dialog.runtime_notice.visible and not dialog.selected_settings().has("pathtrace"), "Remix retains its own settings UI")
	dialog.queue_free()
	print("Render settings: %d failures" % failures)
	quit(1 if failures else 0)
