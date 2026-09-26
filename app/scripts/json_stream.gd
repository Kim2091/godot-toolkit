extends RefCounted

# Write one JSON message as continuation frames without making a String for
# the whole scene. Godot String/JSON lengths are signed 32-bit, even though the
# renderer protocol and PackedByteArray support larger aggregate transfers.
const MORE_FRAMES := 0x80000000
const ARRAY_BATCH := 4096
var _pipe: FileAccess
var _limit := 64 * 1024 * 1024
var _buffer := PackedByteArray()
var _canceled: Callable
var _failed := false

func write(pipe: FileAccess, message: Dictionary, frame_limit: int, canceled := Callable()) -> bool:
	_pipe = pipe; _limit = frame_limit; _canceled = canceled
	_buffer = PackedByteArray(); _failed = false
	if _limit < 1 or _limit > 64 * 1024 * 1024:
		return false
	_value(message)
	if not _failed: _flush(false)
	_buffer = PackedByteArray()
	_pipe = null; _canceled = Callable()
	return not _failed

func _flush(more: bool) -> void:
	if _failed: return
	if _canceled.is_valid() and _canceled.call():
		_failed = true
		return
	var flags := _buffer.size() | (MORE_FRAMES if more else 0)
	if not _pipe.store_32(flags) or not _pipe.store_buffer(_buffer): _failed = true
	_buffer = PackedByteArray()

func _append(text: String) -> void:
	if _failed: return
	var bytes := text.to_utf8_buffer()
	var offset := 0
	while offset < bytes.size() and not _failed:
		# Flush only when another byte follows, so the last frame is nonempty
		# even when total payload length is an exact multiple of the limit.
		if _buffer.size() == _limit: _flush(true)
		if _failed: return
		var count := mini(_limit - _buffer.size(), bytes.size() - offset)
		_buffer.append_array(bytes if offset == 0 and count == bytes.size() else bytes.slice(offset, offset + count))
		offset += count

func _value(value: Variant) -> void:
	if _failed: return
	if value is Dictionary:
		_append("{")
		var first := true
		for key in value:
			if _failed: return
			if not first: _append(",")
			first = false
			_append(JSON.stringify(String(key)) + ":")
			if key in ["vertices", "indices", "colors"] and value[key] is Array:
				_numeric_array(value[key])
			else:
				_value(value[key])
		_append("}")
	elif value is Array:
		# Short scalar vectors/matrices can use the built-in formatter directly.
		if value.size() <= 64 and value.all(func(item: Variant): return not item is Array and not item is Dictionary):
			_append(JSON.stringify(value))
			return
		_append("[")
		for i in value.size():
			if _failed: return
			if i: _append(",")
			_value(value[i])
		_append("]")
	else:
		_append(JSON.stringify(value))

func _numeric_array(values: Array) -> void:
	_append("[")
	for start in range(0, values.size(), ARRAY_BATCH):
		if _failed: return
		if start: _append(",")
		# Vertex tuples and numeric indices are bounded independently of scene
		# size. Slice strings only while they are small, never at a 2 GiB boundary.
		var batch := JSON.stringify(values.slice(start, mini(start + ARRAY_BATCH, values.size())))
		_append(batch.substr(1, batch.length() - 2))
	_append("]")
