# orchestrator.gd
# App-level bootstrap. Autoloaded as /root/Orchestrator.
#
# What it does:
#   - Owns a PluginManager, CredentialStore, and AssetManager as child nodes.
#   - On `unlock(master_password)`, auto-registers every plugin in PluginRegistry
#     whose config is obtainable (credential-store > env-var fallback).
#   - Wires PluginManager.plugin_task_completed → AssetManager.ingest so every
#     successful generation produces a managed, content-hashed asset on disk.
#   - Exposes a small, stable facade — `generate()`, `cancel()`, `plugin_names()`,
#     and the child nodes themselves for advanced callers.
#
# Why an autoload: the UI layer, background workers, and scheduled tasks all
# need the same PluginManager instance. An autoload makes that trivial; no
# dependency injection plumbing, no parent-walking.
#
# Env-var fallback: for smoke tests and CI we often don't want to go through
# the encrypted credential store. If `env_var` is defined in the registry entry
# and set in the process environment, it becomes the `api_key`. Credential
# store wins if both are present — unlocked credentials are more deliberate
# than ambient env-vars.
#
# Tests: Orchestrator doesn't hit the network itself. It just wires things up.
# The unit tests in tests/test_orchestrator.gd verify the registration / env
# fallback / cleanup flows with no real API keys.
#
# See docs/adrs/007-app-bootstrap.md for the full design rationale.

extends Node

# Explicit preloads rather than bare class_name references. The class_name
# cache is refreshed by the editor; headless runs against a fresh checkout
# (or a stale cache) can fail to resolve a class as a bare identifier at
# autoload parse time — which cascade-fails this whole autoload. Preloads
# make this script parse-safe regardless of cache state.
const PluginRegistry = preload("res://scripts/plugin_registry.gd")
const PluginManagerScript = preload("res://scripts/plugin_manager.gd")
const CredentialStoreScript = preload("res://scripts/credential_store.gd")
const AssetManagerScript = preload("res://scripts/asset_manager.gd")
const CostTrackerScript = preload("res://scripts/cost_tracker.gd")
const GDDManagerScript = preload("res://scripts/gdd_manager.gd")
const BasePluginScript = preload("res://scripts/base_plugin.gd")

signal ready_for_work()
signal plugin_registration_failed(plugin_name: String, error: String)

# Children — created in _ready and held here for the app's lifetime.
# Typed loosely (Node) because the preloaded scripts above don't expose a
# static type to the type system; runtime behavior is identical.
var plugin_manager: Node
var credential_store: Node
var asset_manager: Node
var cost_tracker: Node
var gdd_manager: Node

# Set of plugin names successfully registered so far. A plugin shows up here
# only after register_plugin returned success AND enable_plugin returned success.
var _registered: Dictionary = {}

# namespaced_task_id -> prompt. Populated by the generate() facade so that,
# when plugin_task_completed fires, we can attach the prompt as provenance on
# the ingested asset. PluginManager clears its own active_tasks entry before
# emitting the signal, so the prompt isn't retrievable from there.
var _prompts_by_task: Dictionary = {}


func _ready() -> void:
	plugin_manager = PluginManagerScript.new()
	plugin_manager.name = "PluginManager"
	add_child(plugin_manager)

	credential_store = CredentialStoreScript.new()
	credential_store.name = "CredentialStore"
	add_child(credential_store)

	asset_manager = AssetManagerScript.new()
	asset_manager.name = "AssetManager"
	add_child(asset_manager)

	cost_tracker = CostTrackerScript.new()
	cost_tracker.name = "CostTracker"
	# Added as a child so the tracker's _ready (which subscribes to
	# EventBus.cost_incurred) runs in the right tree. shutdown() resets
	# it; the node lifetime matches the orchestrator.
	add_child(cost_tracker)

	gdd_manager = GDDManagerScript.new()
	gdd_manager.name = "GDDManager"
	# GDDManager is stateless beyond schema/snapshot config; nothing to
	# tear down on shutdown. The node lives for the orchestrator's
	# lifetime and posts EventBus events on save / snapshot / rollback.
	add_child(gdd_manager)

	# Wire plugin completions into the asset pipeline. We also hook failures
	# so we can clear the prompt cache — otherwise it would leak on any task
	# that never reaches completion.
	plugin_manager.plugin_task_completed.connect(_on_plugin_task_completed)
	plugin_manager.plugin_task_failed.connect(_on_plugin_task_failed)


# ---------- Public API ----------

# Unlock the credential store and register every plugin we can get credentials for.
# Returns {success: bool, error?: String, registered: Array}.
func unlock_and_register(master_password: String) -> Dictionary:
	var unlock_result: Dictionary = credential_store.unlock(master_password)
	if not bool(unlock_result.get("success", false)):
		return {"success": false, "error": str(unlock_result.get("error", "unlock failed")),
				"registered": []}
	var registered: Array = register_all_available()
	emit_signal("ready_for_work")
	return {"success": true, "registered": registered}

# Register every plugin in PluginRegistry whose config can be resolved.
# Call this after unlock, or from test code that supplies env-vars directly.
# Returns the list of plugin names that were successfully enabled.
func register_all_available() -> Array:
	var enabled: Array = []
	for plugin_name in PluginRegistry.names():
		if _registered.has(plugin_name):
			enabled.append(plugin_name)
			continue
		var cfg: Dictionary = _resolve_config(plugin_name)
		if cfg.is_empty():
			# No credentials available — skip silently. Not an error; the user just
			# hasn't set this provider up yet.
			continue
		var outcome: Dictionary = _register_and_enable(plugin_name, cfg)
		if bool(outcome.get("success", false)):
			enabled.append(plugin_name)
		else:
			emit_signal("plugin_registration_failed", plugin_name, str(outcome.get("error", "")))
	return enabled

# Force-register one plugin with an explicit config (bypasses credential lookup).
# Useful for tests and tools that ship their own key.
func register_plugin_with_config(plugin_name: String, config: Dictionary) -> Dictionary:
	return _register_and_enable(plugin_name, config)

# Convenience passthrough so UI code can call Orchestrator.generate(...) instead
# of reaching into plugin_manager. We also record the prompt here so that when
# the task completes we can tag the resulting asset with provenance.
func generate(plugin_name: String, prompt: String, params: Dictionary = {}) -> String:
	var tid: String = plugin_manager.generate(plugin_name, prompt, params)
	if tid != "":
		_prompts_by_task[tid] = prompt
	return tid

func parallel_generate(plugin_names: Array, prompt: String, params: Dictionary = {}) -> Array:
	var ids: Array = plugin_manager.parallel_generate(plugin_names, prompt, params)
	for tid in ids:
		_prompts_by_task[tid] = prompt
	return ids

func parallel_generate_by_category(category: String, prompt: String, params: Dictionary = {}) -> Array:
	var ids: Array = plugin_manager.parallel_generate_by_category(category, prompt, params)
	for tid in ids:
		_prompts_by_task[tid] = prompt
	return ids

func cancel(namespaced_task_id: String) -> bool:
	_prompts_by_task.erase(namespaced_task_id)
	return plugin_manager.cancel(namespaced_task_id)

# Names of plugins that are currently registered AND enabled.
func plugin_names() -> Array:
	return _registered.keys()

func is_registered(plugin_name: String) -> bool:
	return _registered.has(plugin_name)

# Graceful teardown — shut down plugins, lock the store. Called at app exit.
# AssetManager doesn't need explicit teardown; its on-disk index is durable
# and the node gets freed with us.
func shutdown() -> void:
	if plugin_manager != null:
		plugin_manager.shutdown()
	if credential_store != null:
		credential_store.lock()
	if cost_tracker != null and cost_tracker.has_method("reset"):
		cost_tracker.reset()
	_registered.clear()
	_prompts_by_task.clear()


# ---------- Asset ingestion ----------

# Called when a plugin reports a successful task. We ingest only if the result
# carries an asset_type — some plugins (e.g. a future stateless "ping") might
# complete without producing a managed asset. Tripo's 3D ingest is async
# (HTTP fetch of the remote URL), so we await it; for text/audio/image it
# resolves synchronously but the await is harmless.
func _on_plugin_task_completed(plugin_name: String, task_id: String, result: Dictionary) -> void:
	var prompt: String = str(_prompts_by_task.get(task_id, ""))
	_prompts_by_task.erase(task_id)
	if not result.has("asset_type"):
		return
	if asset_manager == null:
		return
	await asset_manager.ingest(plugin_name, task_id, result, prompt)

# On failure just drop the cached prompt. The task will never produce an asset,
# and we don't want _prompts_by_task to grow unboundedly across retries that
# ultimately give up.
func _on_plugin_task_failed(_plugin_name: String, task_id: String, _error: Dictionary) -> void:
	_prompts_by_task.erase(task_id)


# ---------- Internals ----------

# Resolve a config dictionary for one plugin by trying, in order:
#   1. CredentialStore, if unlocked and the plugin has entries there.
#   2. The env_var declared in PluginRegistry, if the shell exports it.
# Returns {} if neither source yields an api_key.
func _resolve_config(plugin_name: String) -> Dictionary:
	var entry: Dictionary = PluginRegistry.get_entry(plugin_name)
	if entry.is_empty():
		return {}
	var cfg: Dictionary = {}

	# 1. Credential store — deliberate, unlocked input wins.
	if credential_store != null and credential_store.is_unlocked():
		var store_cfg: Dictionary = credential_store.get_plugin_config(plugin_name)
		if not store_cfg.is_empty():
			cfg = store_cfg.duplicate(true)

	# 2. Env-var fallback for api_key only. Pricing / per_char_cost_usd / etc
	# are not expected to live in env because they're tuning knobs, not secrets.
	if not cfg.has("api_key"):
		var env_var: String = str(entry.get("env_var", ""))
		if not env_var.is_empty():
			var env_val: String = OS.get_environment(env_var)
			if not env_val.is_empty():
				cfg["api_key"] = env_val

	if not cfg.has("api_key") or str(cfg["api_key"]).is_empty():
		return {}
	return cfg

# Instantiate, register, and enable one plugin. Plugin node is added as a child
# of the PluginManager so it lives in the scene tree (required for HTTPRequest).
func _register_and_enable(plugin_name: String, config: Dictionary) -> Dictionary:
	var node: Node = PluginRegistry.instantiate(plugin_name)
	if node == null:
		return {"success": false, "error": "cannot instantiate plugin"}
	plugin_manager.add_child(node)
	# Safe cast — PluginRegistry entries all point at BasePlugin subclasses.
	var plugin = node as BasePluginScript
	if plugin == null:
		node.queue_free()
		return {"success": false, "error": "plugin did not extend BasePlugin"}

	var reg: Dictionary = plugin_manager.register_plugin(plugin_name, plugin, config)
	if not bool(reg.get("success", false)):
		node.queue_free()
		return {"success": false, "error": str(reg.get("error", "register failed"))}

	var en: Dictionary = plugin_manager.enable_plugin(plugin_name)
	if not bool(en.get("success", false)):
		plugin_manager.unregister_plugin(plugin_name)
		return {"success": false, "error": str(en.get("error", "enable failed"))}

	_registered[plugin_name] = true
	return {"success": true}
