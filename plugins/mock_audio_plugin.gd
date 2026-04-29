# mock_audio_plugin.gd
# Stress-test plugin for audio category. First request ALWAYS fails with RATE_LIMIT
# (retryable=true) to exercise PluginManager's retry/backoff layer. Subsequent
# requests succeed normally.

extends BasePlugin
class_name MockAudioPlugin

const _VALID_GENRES: Array = ["ambient", "rock", "orchestral", "electronic"]

var _tasks: Dictionary = {}
var _request_count: int = 0

# Toggle for tests that don't want the first-request-fails behavior.
var fail_first_request: bool = true

# -- Lifecycle --

func initialize(_config: Dictionary) -> Dictionary:
	_request_count = 0
	return {"success": true}

func health_check() -> Dictionary:
	return {"healthy": true, "message": "ok"}

func test_connection() -> Dictionary:
	# Mock plugin: no real backend. Always reports OK so the
	# credential editor's Test button has something deterministic to
	# verify against in dev / test runs.
	return {"success": true, "message": "mock — no real backend"}

func shutdown() -> void:
	for tid in _tasks.keys():
		_tasks[tid]["cancelled"] = true
	_tasks.clear()

# -- Generation --

func generate(prompt: String, params: Dictionary) -> String:
	var tid: String = _make_task_id()
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

func estimate_cost(_prompt: String, params: Dictionary) -> float:
	var duration: int = int(params.get("duration", 30))
	return 0.002 * float(duration)

# -- Introspection --

func get_status(task_id: String) -> Dictionary:
	if not _tasks.has(task_id):
		return {"state": "Unknown", "progress": 0.0, "message": "no such task"}
	var t: Dictionary = _tasks[task_id]
	return {"state": t["state"], "progress": t["progress"], "message": ""}

func get_all_tasks() -> Array:
	return _tasks.keys()

func get_metadata() -> Dictionary:
	return {
		"plugin_name": "mock_audio",
		"version": "0.1.0",
		"category": "audio",
		"supported_formats": ["mp3", "wav"],
		"capabilities": {
			"parallel": true,
			"streaming": false,
			"cancel": true,
		},
		"cost_unit": "USD",
		"limits": {
			"max_prompt_length": 1000,
			"requests_per_minute": 30,
		},
	}

func get_param_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"duration": {
				"type": "integer",
				"minimum": 5,
				"maximum": 300,
				"default": 30,
				"description": "Length in seconds."
			},
			"genre": {
				"type": "string",
				"enum": _VALID_GENRES,
				"default": "ambient"
			}
		},
		"required": []
	}

# -- Internals --

func _run_mock_task(task_id: String, _prompt: String, params: Dictionary) -> void:
	var tree: SceneTree = get_tree()
	if tree == null:
		emit_signal("task_failed", task_id, _make_error(ERR_UNKNOWN, "plugin not in scene tree", false))
		_tasks.erase(task_id)
		return

	await tree.create_timer(0.05).timeout

	# First request fails with RATE_LIMIT (retryable) by default — drives retry tests.
	if fail_first_request and _tasks[task_id]["request_index"] == 1:
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

	var duration: int = int(params.get("duration", 30))
	var result: Dictionary = {
		"asset_type": "audio",
		"format": "mp3",
		"path": "mock://audio/%s.mp3" % task_id,
		"duration": duration,
		"cost": 0.002 * float(duration),
		"plugin": "mock_audio",
	}
	_tasks.erase(task_id)
	emit_signal("task_completed", task_id, result)
