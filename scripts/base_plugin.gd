# base_plugin.gd
# Contract for all generator plugins (Tripo, Meshy, Suno, ElevenLabs, DeepSeek, Tiled, Inworld, ...).
# See docs/adrs/004-plugin-process-model.md for the in-process design rationale.
#
# Lifecycle: register → initialize → enable (health_check) → generate* → cancel? → disable → shutdown
# Generation is fire-and-track: generate() returns a task_id immediately, results arrive via signals.
#
# Standard error payload (emitted on task_failed):
#   {
#     "code": String,           # one of the ERR_* constants below
#     "message": String,
#     "retryable": bool,
#     "retry_after_ms": int,    # optional, informs backoff
#     "raw": Variant            # optional, provider-specific details
#   }

extends Node
class_name BasePlugin

# -- Standard error codes --
const ERR_RATE_LIMIT: String = "RATE_LIMIT"
const ERR_AUTH_FAILED: String = "AUTH_FAILED"
const ERR_NETWORK: String = "NETWORK"
const ERR_INVALID_PARAMS: String = "INVALID_PARAMS"
const ERR_PROVIDER_ERROR: String = "PROVIDER_ERROR"
const ERR_TIMEOUT: String = "TIMEOUT"
const ERR_CANCELLED: String = "CANCELLED"
const ERR_INSUFFICIENT_BUDGET: String = "INSUFFICIENT_BUDGET"
const ERR_UNKNOWN: String = "UNKNOWN"

# -- Signals --
signal task_progress(task_id: String, progress: float, message: String)
signal task_completed(task_id: String, result: Dictionary)
signal task_failed(task_id: String, error: Dictionary)
# Only emitted by plugins declaring capabilities.streaming = true
signal task_stream_chunk(task_id: String, chunk: Dictionary)

# -- Lifecycle --

# Configure with credentials and settings. Called once by PluginManager.register_plugin.
# Returns {success: bool, error: String?}.
func initialize(config: Dictionary) -> Dictionary:
	push_error("initialize() not implemented in %s" % _debug_name())
	return {"success": false, "error": "not implemented"}

# Verify plugin is usable (API reachable, credentials valid).
# Called by PluginManager.enable_plugin before marking as active.
# Returns {healthy: bool, message: String}.
func health_check() -> Dictionary:
	return {"healthy": false, "message": "not implemented"}

# Called on disable or app shutdown: cancel in-flight, close connections, flush logs.
func shutdown() -> void:
	pass

# -- Generation --

# Fire-and-track. Returns a task_id immediately; results arrive through signals.
# Abstract — subclasses MUST override. Returns "" on BasePlugin to signal
# "request not accepted"; we deliberately do NOT push_error here because GUT
# treats any push_error during a test as a failure, and we need the base
# class usable from unit tests that exercise the default contract.
func generate(_prompt: String, _params: Dictionary) -> String:
	return ""

# Cancel a task by id. Returns true if cancellation was accepted.
# The plugin MUST eventually emit task_failed with code=CANCELLED for that id.
func cancel(_task_id: String) -> bool:
	push_error("cancel() not implemented in %s" % _debug_name())
	return false

# Cost in units declared by get_metadata().cost_unit. Return -1.0 if unknown.
# Synchronous; expensive lookups should be cached by the plugin.
func estimate_cost(_prompt: String, _params: Dictionary) -> float:
	return -1.0

# -- Introspection --

# Per-task state: {state, progress: float, message: String}.
# state ∈ {"Queued", "Running", "Completed", "Failed", "Cancelled", "Unknown"}
func get_status(_task_id: String) -> Dictionary:
	return {"state": "Unknown", "progress": 0.0, "message": "not implemented"}

# All task ids currently tracked (active + recently completed that haven't been GC'd).
func get_all_tasks() -> Array:
	return []

# Identity + declared capabilities. See format below.
func get_metadata() -> Dictionary:
	return {
		"plugin_name": "BasePlugin",
		"version": "0.0.0",
		"category": "",                      # "3d" | "audio" | "dialogue" | "code" | "image" | "texture"
		"supported_formats": [],
		"capabilities": {
			"parallel": false,
			"streaming": false,
			"cancel": false,
		},
		"cost_unit": "USD",
		"limits": {
			"max_prompt_length": 2000,
			"requests_per_minute": 60,
		},
	}

# JSON-Schema-like descriptor so Plugin Hub UI can render a per-plugin params form.
# Return shape: {"type": "object", "properties": {...}, "required": [...]}.
func get_param_schema() -> Dictionary:
	return {"type": "object", "properties": {}, "required": []}

# -- Helpers for subclasses --

# Generate a collision-resistant task id. Format: t_<unix_ms>_<rand>
func _make_task_id() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return "t_%d_%d" % [Time.get_ticks_msec(), rng.randi()]

# Construct a standard error dictionary.
func _make_error(code: String, message: String, retryable: bool = false, retry_after_ms: int = 0, raw: Variant = null) -> Dictionary:
	var err: Dictionary = {
		"code": code,
		"message": message,
		"retryable": retryable,
	}
	if retry_after_ms > 0:
		err["retry_after_ms"] = retry_after_ms
	if raw != null:
		err["raw"] = raw
	return err

func _debug_name() -> String:
	var meta: Dictionary = get_metadata()
	return str(meta.get("plugin_name", "BasePlugin"))
