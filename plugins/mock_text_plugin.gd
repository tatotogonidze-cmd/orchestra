# mock_text_plugin.gd
# Stress-test plugin for the text category (Phase 42 / ADR 042).
#
# Closes the 4×2 plugin grid: every asset category now has both a
# real provider (Claude) and a mock for stress / retry / no-network
# tests.
#
# Behaviour:
#   - First request fires RATE_LIMIT (retryable=true) — same pattern
#     as mock_audio / mock_image. Drives PluginManager retry coverage
#     against text-typed responses.
#   - Subsequent requests echo the prompt with a "[mock] " prefix.
#     Deterministic content lets tests assert on the body without
#     prompt-engineering Claude.
#   - Optional `max_words` param clamps the echo (useful when
#     downstream wants to flex truncation paths).
#
# Result shape matches claude_plugin's so consumers (asset_preview,
# task_list, generate_form) treat the two interchangeably:
#   {asset_type: "text", format: "plain", text: <body>, ...}

extends BasePlugin
class_name MockTextPlugin

var _tasks: Dictionary = {}
var _request_count: int = 0

# Match the mock_audio / mock_image toggle so happy-path tests can
# bypass the first-request retry gate.
var fail_first_request: bool = true


# ---------- Lifecycle ----------

func initialize(_config: Dictionary) -> Dictionary:
	_request_count = 0
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
	var validation: Dictionary = _validate_params(prompt, params)
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
	return 0.001  # flat mock cost — small enough to not dominate cost-tracker tests.


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
		"plugin_name": "mock_text",
		"version": "0.1.0",
		"category": "text",
		"supported_formats": ["plain"],
		"capabilities": {
			"parallel": true,
			"streaming": false,
			"cancel": true,
		},
		"cost_unit": "USD",
		"limits": {
			"max_prompt_length": 4000,
			"requests_per_minute": 60,
		},
	}

func get_param_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"max_words": {
				"type": "integer",
				"minimum": 1,
				"maximum": 1000,
				"default": 0,
				"description": "Clamp the echo to this many words. 0 = no clamp."
			},
		},
		"required": []
	}


# ---------- Internals ----------

func _validate_params(prompt: String, params: Dictionary) -> Dictionary:
	if prompt.is_empty():
		return {"valid": false, "error": "prompt must not be empty"}
	if params.has("max_words"):
		var n = params["max_words"]
		if not (n is int) or n < 0 or n > 1000:
			return {"valid": false, "error": "max_words must be in [0..1000]"}
	return {"valid": true, "error": ""}

func _emit_invalid_params(task_id: String, msg: String) -> void:
	emit_signal("task_failed", task_id, _make_error(ERR_INVALID_PARAMS, msg, false))

# Build the deterministic echo body. Caller's responsibility to
# clamp via _maybe_clamp_words.
func _make_echo(prompt: String) -> String:
	return "[mock] %s" % prompt

func _maybe_clamp_words(text: String, max_words: int) -> String:
	if max_words <= 0:
		return text
	var words: PackedStringArray = text.split(" ", false)
	if words.size() <= max_words:
		return text
	var kept: Array = []
	for i in range(max_words):
		kept.append(words[i])
	return " ".join(kept)

func _run_mock_task(task_id: String, prompt: String, params: Dictionary) -> void:
	var tree: SceneTree = get_tree()
	if tree == null:
		emit_signal("task_failed", task_id, _make_error(ERR_UNKNOWN, "plugin not in scene tree", false))
		_tasks.erase(task_id)
		return

	await tree.create_timer(0.05).timeout

	# First request fails RATE_LIMIT (retryable). Same shape as the
	# audio / image mocks so retry coverage is uniform across
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

	var max_words: int = int(params.get("max_words", 0))
	var body: String = _maybe_clamp_words(_make_echo(prompt), max_words)

	var result: Dictionary = {
		"asset_type": "text",
		"format":     "plain",
		"text":       body,
		"path":       "",  # text plugins don't write a file (matches claude_plugin)
		"cost":       0.001,
		"plugin":     "mock_text",
	}
	_tasks.erase(task_id)
	emit_signal("task_completed", task_id, result)
