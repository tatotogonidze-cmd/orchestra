# plugin_manager.gd
# Central orchestrator for all plugins.
#
# Responsibilities:
#   - Registration + lifecycle (initialize, enable/health_check, disable, shutdown)
#   - Dispatch (generate, cancel, parallel_generate*)
#   - Signal aggregation with namespaced task ids (plugin_name:inner_id)
#   - Active task registry (prompt, params, started_at, attempt #)
#   - Retry/backoff for retryable failures
#   - Cost aggregation hook (cost_incurred signal forwarded to EventBus if present)
#
# IMPORTANT: signal plumbing uses LAMBDA CLOSURES, not Callable.bind(), to avoid
# the well-known Godot 4 bug where bind() appends bound args (producing wrong
# argument order in handlers that expect bound args first). See
# docs/adrs/003-godot-version.md for context.

extends Node
class_name PluginManager

# -- Re-emitted signals, plugin-namespaced --
signal plugin_task_progress(plugin_name: String, task_id: String, progress: float, message: String)
signal plugin_task_completed(plugin_name: String, task_id: String, result: Dictionary)
signal plugin_task_failed(plugin_name: String, task_id: String, error: Dictionary)

# -- Cost event (forwarded to EventBus.cost_incurred when available) --
signal cost_incurred(plugin_name: String, amount: float, cost_unit: String)

# -- Retry lifecycle signal (observable for tests/UIs) --
signal retry_scheduled(task_id: String, attempt: int, delay_ms: int)

const NAMESPACE_SEP: String = ":"

# -- Registries --
var plugins: Dictionary = {}            # plugin_name -> BasePlugin
var active_plugins: Dictionary = {}     # subset of plugins currently enabled
# namespaced_task_id -> {plugin_name, inner_task_id, prompt, params, started_at, status, attempt, original_task_id}
var active_tasks: Dictionary = {}

# -- Retry config (per-instance; can be overridden) --
var retry_config: Dictionary = {
	"max_retries": 3,
	"base_delay_ms": 100,
	"max_delay_ms": 5000,
	"backoff_multiplier": 2.0,
}

# retry_state[original_ns] = {attempts, plugin_name, prompt, params}
var _retry_state: Dictionary = {}
# retry_alias[current_ns] = original_ns
var _retry_alias: Dictionary = {}


# ---------- Registration ----------

# Register and initialize a plugin.
# Returns {success: bool, error: String?}.
func register_plugin(plugin_name: String, plugin: BasePlugin, config: Dictionary = {}) -> Dictionary:
	if plugin_name.is_empty():
		return {"success": false, "error": "plugin_name must not be empty"}
	if plugins.has(plugin_name):
		return {"success": false, "error": "already registered: %s" % plugin_name}
	var init_result: Dictionary = plugin.initialize(config)
	if not init_result.get("success", false):
		return {"success": false, "error": init_result.get("error", "initialize failed")}
	plugins[plugin_name] = plugin
	_connect_plugin_signals(plugin_name, plugin)
	_post_event("plugin_registered", [plugin_name])
	return {"success": true}

# Reverse of register; also disables, cancels in-flight, and calls shutdown().
func unregister_plugin(plugin_name: String) -> void:
	if not plugins.has(plugin_name):
		return
	disable_plugin(plugin_name)
	var plugin: BasePlugin = plugins[plugin_name]
	plugin.shutdown()
	plugins.erase(plugin_name)


# ---------- Lifecycle: enable/disable/shutdown ----------

# Enable runs health_check first.
func enable_plugin(plugin_name: String) -> Dictionary:
	if not plugins.has(plugin_name):
		return {"success": false, "error": "not registered"}
	var plugin: BasePlugin = plugins[plugin_name]
	var health: Dictionary = plugin.health_check()
	if not health.get("healthy", false):
		return {"success": false, "error": health.get("message", "unhealthy")}
	active_plugins[plugin_name] = plugin
	_post_event("plugin_enabled", [plugin_name])
	return {"success": true}

# Disable cancels all in-flight tasks for this plugin.
func disable_plugin(plugin_name: String) -> void:
	if not active_plugins.has(plugin_name):
		return
	for namespaced_id in _task_ids_for_plugin(plugin_name):
		cancel(namespaced_id)
	active_plugins.erase(plugin_name)
	_post_event("plugin_disabled", [plugin_name])

# Shutdown all plugins (typically at app exit).
func shutdown() -> void:
	for name in plugins.keys():
		var p: BasePlugin = plugins[name]
		p.shutdown()
	plugins.clear()
	active_plugins.clear()
	active_tasks.clear()
	_retry_state.clear()
	_retry_alias.clear()


# ---------- Generation ----------

# Returns namespaced_task_id ("plugin_name:inner") or "" if not dispatched.
func generate(plugin_name: String, prompt: String, params: Dictionary) -> String:
	var ns: String = _do_generate(plugin_name, prompt, params)
	if ns != "":
		# Initialize retry tracking (retry only happens on retryable failure).
		_retry_state[ns] = {
			"attempts": 0,
			"plugin_name": plugin_name,
			"prompt": prompt,
			"params": params.duplicate(true),
		}
	return ns

# Dispatch the same prompt to a list of plugins.
func parallel_generate(plugin_names: Array, prompt: String, params: Dictionary) -> Array:
	var ids: Array = []
	for name in plugin_names:
		var tid: String = generate(name, prompt, params)
		if tid != "":
			ids.append(tid)
	return ids

# Dispatch to all active plugins of a given category.
func parallel_generate_by_category(category: String, prompt: String, params: Dictionary) -> Array:
	return parallel_generate(get_active_plugins_by_category(category), prompt, params)

# Cancel by namespaced id.
func cancel(namespaced_task_id: String) -> bool:
	var parts: Array = _parse_ns(namespaced_task_id)
	if parts.is_empty():
		return false
	var plugin_name: String = parts[0]
	var inner_id: String = parts[1]
	if not plugins.has(plugin_name):
		return false
	# Clear retry state first so we don't re-submit a cancelled task.
	_retry_state.erase(namespaced_task_id)
	return plugins[plugin_name].cancel(inner_id)


# ---------- Queries ----------

func get_active_plugins_by_category(category: String) -> Array:
	var result: Array = []
	for name in active_plugins.keys():
		var meta: Dictionary = active_plugins[name].get_metadata()
		if str(meta.get("category", "")) == category:
			result.append(name)
	return result

func get_active_task(namespaced_task_id: String) -> Dictionary:
	return active_tasks.get(namespaced_task_id, {})

func get_all_active_tasks() -> Array:
	return active_tasks.keys()

func is_plugin_registered(plugin_name: String) -> bool:
	return plugins.has(plugin_name)

func is_plugin_active(plugin_name: String) -> bool:
	return active_plugins.has(plugin_name)


# ---------- Internals ----------

func _do_generate(plugin_name: String, prompt: String, params: Dictionary) -> String:
	if not active_plugins.has(plugin_name):
		push_error("Plugin not active: %s" % plugin_name)
		return ""
	var plugin: BasePlugin = active_plugins[plugin_name]
	var inner_id: String = plugin.generate(prompt, params)
	if inner_id.is_empty():
		return ""
	var namespaced: String = _ns(plugin_name, inner_id)
	if active_tasks.has(namespaced):
		push_error("task_id collision: %s" % namespaced)
		return ""
	active_tasks[namespaced] = {
		"plugin_name": plugin_name,
		"inner_task_id": inner_id,
		"prompt": prompt,
		"params": params,
		"started_at": Time.get_unix_time_from_system(),
		"status": "Running",
		"attempt": 0,
	}
	return namespaced

# Connect plugin signals using lambda closures (fixes the .bind() arg-order bug).
func _connect_plugin_signals(plugin_name: String, plugin: BasePlugin) -> void:
	plugin.task_progress.connect(
		func(task_id: String, progress: float, message: String) -> void:
			_on_task_progress(plugin_name, task_id, progress, message))
	plugin.task_completed.connect(
		func(task_id: String, result: Dictionary) -> void:
			_on_task_completed(plugin_name, task_id, result))
	plugin.task_failed.connect(
		func(task_id: String, error: Dictionary) -> void:
			_on_task_failed(plugin_name, task_id, error))

func _on_task_progress(plugin_name: String, inner_task_id: String, progress: float, message: String) -> void:
	var current_ns: String = _ns(plugin_name, inner_task_id)
	var reported_ns: String = _retry_alias.get(current_ns, current_ns)
	emit_signal("plugin_task_progress", plugin_name, reported_ns, progress, message)

func _on_task_completed(plugin_name: String, inner_task_id: String, result: Dictionary) -> void:
	var current_ns: String = _ns(plugin_name, inner_task_id)
	var reported_ns: String = _retry_alias.get(current_ns, current_ns)
	_retry_alias.erase(current_ns)
	_retry_state.erase(reported_ns)
	active_tasks.erase(current_ns)
	emit_signal("plugin_task_completed", plugin_name, reported_ns, result)
	var cost: float = float(result.get("cost", 0.0))
	if cost > 0.0 and plugins.has(plugin_name):
		var unit: String = str(plugins[plugin_name].get_metadata().get("cost_unit", "USD"))
		emit_signal("cost_incurred", plugin_name, cost, unit)
		_post_event("cost_incurred", [plugin_name, cost, unit])

func _on_task_failed(plugin_name: String, inner_task_id: String, error: Dictionary) -> void:
	var current_ns: String = _ns(plugin_name, inner_task_id)
	var reported_ns: String = _retry_alias.get(current_ns, current_ns)

	# Attempt retry if the error is retryable and we still have a slot.
	if bool(error.get("retryable", false)) and _retry_state.has(reported_ns):
		var state: Dictionary = _retry_state[reported_ns]
		if int(state["attempts"]) < int(retry_config["max_retries"]):
			_retry_alias.erase(current_ns)
			active_tasks.erase(current_ns)
			_schedule_retry(reported_ns, error)
			return

	# Final failure: clean up and propagate.
	_retry_alias.erase(current_ns)
	_retry_state.erase(reported_ns)
	active_tasks.erase(current_ns)
	emit_signal("plugin_task_failed", plugin_name, reported_ns, error)

func _schedule_retry(original_ns: String, error: Dictionary) -> void:
	if not _retry_state.has(original_ns):
		return
	var state: Dictionary = _retry_state[original_ns]
	var attempt: int = int(state["attempts"])
	var base: int = int(retry_config["base_delay_ms"])
	var mult: float = float(retry_config["backoff_multiplier"])
	var cap: int = int(retry_config["max_delay_ms"])
	var delay_ms: int = int(min(float(base) * pow(mult, float(attempt)), float(cap)))
	var retry_after: int = int(error.get("retry_after_ms", 0))
	if retry_after > delay_ms:
		delay_ms = retry_after
	state["attempts"] = attempt + 1
	emit_signal("retry_scheduled", original_ns, state["attempts"], delay_ms)

	var tree: SceneTree = get_tree()
	if tree == null:
		push_error("cannot retry: plugin_manager not in scene tree")
		emit_signal("plugin_task_failed", state["plugin_name"], original_ns,
			{"code": "PROVIDER_ERROR", "message": "retry unavailable: no tree", "retryable": false})
		_retry_state.erase(original_ns)
		return

	await tree.create_timer(float(delay_ms) / 1000.0).timeout

	# Plugin may have been disabled while we waited.
	if not active_plugins.has(state["plugin_name"]):
		emit_signal("plugin_task_failed", state["plugin_name"], original_ns,
			{"code": "PROVIDER_ERROR", "message": "plugin no longer active", "retryable": false})
		_retry_state.erase(original_ns)
		return

	var plugin: BasePlugin = active_plugins[state["plugin_name"]]
	var new_inner: String = plugin.generate(state["prompt"], state["params"])
	if new_inner.is_empty():
		emit_signal("plugin_task_failed", state["plugin_name"], original_ns,
			{"code": "PROVIDER_ERROR", "message": "retry submission failed", "retryable": false})
		_retry_state.erase(original_ns)
		return

	var new_ns: String = _ns(state["plugin_name"], new_inner)
	_retry_alias[new_ns] = original_ns
	active_tasks[new_ns] = {
		"plugin_name": state["plugin_name"],
		"inner_task_id": new_inner,
		"prompt": state["prompt"],
		"params": state["params"],
		"started_at": Time.get_unix_time_from_system(),
		"status": "Retrying",
		"attempt": state["attempts"],
		"original_task_id": original_ns,
	}

# ---------- Helpers ----------

func _ns(plugin_name: String, task_id: String) -> String:
	return "%s%s%s" % [plugin_name, NAMESPACE_SEP, task_id]

func _parse_ns(namespaced_task_id: String) -> Array:
	var idx: int = namespaced_task_id.find(NAMESPACE_SEP)
	if idx <= 0:
		return []
	return [namespaced_task_id.substr(0, idx), namespaced_task_id.substr(idx + 1)]

func _task_ids_for_plugin(plugin_name: String) -> Array:
	var ids: Array = []
	for namespaced_id in active_tasks.keys():
		if active_tasks[namespaced_id]["plugin_name"] == plugin_name:
			ids.append(namespaced_id)
	return ids

# Safe EventBus post. No-op if EventBus autoload is not present (e.g. in bare unit tests).
func _post_event(event_name: String, args: Array) -> void:
	var loop = Engine.get_main_loop()
	if loop == null or not (loop is SceneTree):
		return
	var tree := loop as SceneTree
	if tree.root == null or not tree.root.has_node("EventBus"):
		return
	var bus: Node = tree.root.get_node("EventBus")
	if bus.has_method("post"):
		bus.call("post", event_name, args)
