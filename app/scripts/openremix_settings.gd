extends RefCounted

static var options: Array = JSON.parse_string(FileAccess.get_file_as_string("res://scripts/openremix_settings.json"))

static func defaults() -> Dictionary:
	var result := {}
	for option in options:
		var value = option.default
		if value is float and (option.get("step") == 1 or option.has("choices")): value = int(value)
		result[option.key] = value
	return result

static func sanitized(data: Variant) -> Dictionary:
	var result := defaults()
	if not data is Dictionary: return result
	for option in options:
		var value = data.get(option.key)
		if option.has("choices"):
			if option.default is String:
				if value is String and option.choices.has(value): result[option.key] = value
			elif (value is int or value is float) and is_finite(value) and value == floor(value) and option.choices.has(str(int(value))):
				result[option.key] = int(value)
		elif option.default is bool:
			if value is bool: result[option.key] = value
		elif (value is int or value is float) and is_finite(value) and value >= option.min and value <= option.max:
			if option.step != 1 or value == floor(value):
				result[option.key] = int(value) if option.step == 1 else float(value)
	return result
