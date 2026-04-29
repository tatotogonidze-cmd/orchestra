# mock_3d_plugin.gd
# Stress-test plugin for the BasePlugin contract. 3D category.
# Async simulation via SceneTreeTimer. No external dependencies.
#
# Requires the plugin Node to be inside the scene tree (add_child before use).

extends BasePlugin
class_name Mock3DPlugin

const _VALID_STYLES: Array = ["realistic", "lowpoly", "voxel"]

# inner_task_id -> {state, progress, cancelled}
var _tasks: Dictionary = {}

# -- Lifecycle --

func initialize(_config: Dictionary) -> Dictionary:
	return {"success": true}

func health_check() -> Dictionary:
	return {"healthy": true, "message": "mock plugin always healthy"}

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
	var validation: Dictionary = _validate_params(params)
	if not validation["valid"]:
		# Emit failure AFTER returning, so caller has the id first.
		call_deferred("_emit_invalid_params", tid, validation["error"])
		return tid
	_tasks[tid] = {"state": "Running", "progress": 0.0, "cancelled": false}
	_run_mock_task(tid, prompt, params)
	return tid

func cancel(task_id: String) -> bool:
	if not _tasks.has(task_id):
		return false
	_tasks[task_id]["cancelled"] = true
	return true

func estimate_cost(_prompt: String, _params: Dictionary) -> float:
	return 0.05  # flat mock cost

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
		"plugin_name": "mock_3d",
		"version": "0.1.0",
		"category": "3d",
		"supported_formats": ["glb"],
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
			"style": {
				"type": "string",
				"enum": _VALID_STYLES,
				"default": "lowpoly",
				"description": "Visual style of the generated mesh."
			},
			"polycount": {
				"type": "integer",
				"minimum": 100,
				"maximum": 100000,
				"default": 5000,
				"description": "Target polygon count."
			}
		},
		"required": []
	}

# -- Internals --

func _validate_params(params: Dictionary) -> Dictionary:
	if params.has("style"):
		var s = params["style"]
		if not (s is String) or not _VALID_STYLES.has(s):
			return {"valid": false, "error": "style must be one of %s" % str(_VALID_STYLES)}
	if params.has("polycount"):
		var p = params["polycount"]
		if not (p is int) or p < 100 or p > 100000:
			return {"valid": false, "error": "polycount out of range [100..100000]"}
	return {"valid": true, "error": ""}

func _emit_invalid_params(task_id: String, msg: String) -> void:
	emit_signal("task_failed", task_id, _make_error(ERR_INVALID_PARAMS, msg, false))

# Simulate 3 progress ticks (~300ms total) then completion.
func _run_mock_task(task_id: String, _prompt: String, params: Dictionary) -> void:
	var tree: SceneTree = get_tree()
	if tree == null:
		emit_signal("task_failed", task_id, _make_error(ERR_UNKNOWN, "plugin not in scene tree", false))
		_tasks.erase(task_id)
		return

	for i in range(1, 4):
		await tree.create_timer(0.1).timeout
		if not _tasks.has(task_id) or _tasks[task_id]["cancelled"]:
			emit_signal("task_failed", task_id, _make_error(ERR_CANCELLED, "cancelled by user", false))
			_tasks.erase(task_id)
			return
		var progress: float = float(i) / 3.0
		_tasks[task_id]["progress"] = progress
		emit_signal("task_progress", task_id, progress, "step %d/3" % i)

	var style: String = params.get("style", "lowpoly")
	var result: Dictionary = {
		"asset_type": "3d",
		"format": "glb",
		"path": "mock://3d/%s.glb" % task_id,
		"style": style,
		"cost": 0.05,
		"plugin": "mock_3d",
	}
	_tasks.erase(task_id)
	emit_signal("task_completed", task_id, result)
