# mock_image_plugin.gd
# Stress-test plugin for the image category (Phase 37 / ADR 037).
#
# Mirrors mock_audio_plugin's "first request fails with RATE_LIMIT"
# pattern so PluginManager's retry/backoff layer gets exercised on
# the image path too.
#
# Unlike mock_audio / mock_3d which emit fake `mock://...` paths, this
# plugin writes a REAL synthetic PNG to user://assets/image_mock/ so
# asset_preview's image branch can render it end-to-end without
# burning OpenAI quota. Image content is a 64×64 colored square
# whose hue is derived from the prompt's hash — visually distinct
# per prompt, useful as a smoke-test diagnostic.

extends BasePlugin
class_name MockImagePlugin

const _VALID_SIZES: Array = [64, 128, 256]
const OUTPUT_DIR: String = "user://assets/image_mock"

var _tasks: Dictionary = {}
var _request_count: int = 0

# Same toggle as mock_audio. Tests that don't want first-request-
# fails behaviour set this false.
var fail_first_request: bool = true


# ---------- Lifecycle ----------

func initialize(_config: Dictionary) -> Dictionary:
	_request_count = 0
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIR))
	return {"success": true}

func health_check() -> Dictionary:
	return {"healthy": true, "message": "ok"}

func test_connection() -> Dictionary:
	return {"success": true, "message": "mock — no real backend"}

func shutdown() -> void:
	for tid in _tasks.keys():
		_tasks[tid]["cancelled"] = true
	_tasks.clear()


# ---------- Generation ----------

func generate(prompt: String, params: Dictionary) -> String:
	var tid: String = _make_task_id()
	var validation: Dictionary = _validate_params(params)
	if not validation["valid"]:
		call_deferred("_emit_invalid_params", tid, validation["error"])
		return tid
	_request_count += 1
	_tasks[tid] = {
		"state": "Running",
		"progress": 0.0,
		"cancelled": false,
		"request_index": _request_count,
	}
	_run_mock_task(tid, prompt, params)
	return tid

func cancel(task_id: String) -> bool:
	if not _tasks.has(task_id):
		return false
	_tasks[task_id]["cancelled"] = true
	return true

func estimate_cost(_prompt: String, _params: Dictionary) -> float:
	return 0.01  # flat mock cost


# ---------- Introspection ----------

func get_status(task_id: String) -> Dictionary:
	if not _tasks.has(task_id):
		return {"state": "Unknown", "progress": 0.0, "message": "no such task"}
	var t: Dictionary = _tasks[task_id]
	return {"state": t["state"], "progress": t["progress"], "message": ""}

func get_all_tasks() -> Array:
	return _tasks.keys()

func get_metadata() -> Dictionary:
	return {
		"plugin_name": "mock_image",
		"version": "0.1.0",
		"category": "image",
		"supported_formats": ["png"],
		"capabilities": {
			"parallel": true,
			"streaming": false,
			"cancel": true,
		},
		"cost_unit": "USD",
		"limits": {
			"max_prompt_length": 2000,
			"requests_per_minute": 60,
		},
	}

func get_param_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"size": {
				"type": "integer",
				"enum": _VALID_SIZES,
				"default": 64,
				"description": "Side length in pixels (square output)."
			},
		},
		"required": []
	}


# ---------- Internals ----------

func _validate_params(params: Dictionary) -> Dictionary:
	if params.has("size"):
		var s = params["size"]
		if not (s is int) or not _VALID_SIZES.has(s):
			return {"valid": false, "error": "size must be one of %s" % str(_VALID_SIZES)}
	return {"valid": true, "error": ""}

func _emit_invalid_params(task_id: String, msg: String) -> void:
	emit_signal("task_failed", task_id, _make_error(ERR_INVALID_PARAMS, msg, false))

# Generate a deterministic color from the prompt's content. Same prompt
# → same color across runs, useful for tests that snapshot output.
func _color_for_prompt(prompt: String) -> Color:
	var h: int = hash(prompt)
	# Map to a stable HSV — high saturation/value so the output is visually obvious.
	var hue: float = fmod(float(h & 0xFFFF) / 65535.0, 1.0)
	return Color.from_hsv(hue, 0.7, 0.9)

# Write a small synthetic PNG so asset_preview can render it. Returns
# the on-disk path. Caller's responsibility to surface errors via
# task_failed.
func _write_synthetic_png(task_id: String, prompt: String, size: int) -> String:
	var img: Image = Image.create(size, size, false, Image.FORMAT_RGB8)
	img.fill(_color_for_prompt(prompt))
	var path: String = "%s/%s.png" % [OUTPUT_DIR, task_id]
	var err: Error = img.save_png(path)
	if err != OK:
		return ""
	return path

func _run_mock_task(task_id: String, prompt: String, params: Dictionary) -> void:
	var tree: SceneTree = get_tree()
	if tree == null:
		emit_signal("task_failed", task_id, _make_error(ERR_UNKNOWN, "plugin not in scene tree", false))
		_tasks.erase(task_id)
		return

	await tree.create_timer(0.05).timeout

	# First request fails with RATE_LIMIT (retryable). Mirrors
	# mock_audio_plugin so retry coverage is symmetric across
	# categories.
	if fail_first_request and _tasks.has(task_id) \
			and _tasks[task_id]["request_index"] == 1:
		_tasks.erase(task_id)
		emit_signal("task_failed", task_id, _make_error(
			ERR_RATE_LIMIT,
			"mock rate limit on first request",
			true,
			100
		))
		return

	for i in range(1, 3):
		await tree.create_timer(0.05).timeout
		if not _tasks.has(task_id) or _tasks[task_id]["cancelled"]:
			emit_signal("task_failed", task_id, _make_error(ERR_CANCELLED, "cancelled", false))
			_tasks.erase(task_id)
			return
		var p: float = float(i) / 2.0
		_tasks[task_id]["progress"] = p
		emit_signal("task_progress", task_id, p, "")

	var size: int = int(params.get("size", 64))
	var path: String = _write_synthetic_png(task_id, prompt, size)
	if path.is_empty():
		_tasks.erase(task_id)
		emit_signal("task_failed", task_id, _make_error(
			ERR_UNKNOWN, "cannot write synthetic PNG", false))
		return

	var result: Dictionary = {
		"asset_type": "image",
		"format":     "png",
		"path":       path,
		"size":       "%dx%d" % [size, size],
		"cost":       0.01,
		"plugin":     "mock_image",
	}
	_tasks.erase(task_id)
	emit_signal("task_completed", task_id, result)
