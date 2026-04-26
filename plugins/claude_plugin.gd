# claude_plugin.gd
# Anthropic Claude Messages API.
#
# API:
#   POST https://api.anthropic.com/v1/messages
#     headers: x-api-key, anthropic-version, content-type
#     body: {
#       "model": "claude-sonnet-4-6" (default),
#       "max_tokens": 1024,
#       "system": "...",
#       "messages": [{"role": "user", "content": "..."}],
#       "temperature": 1.0
#     }
#     response: {
#       "content": [{"type": "text", "text": "..."}, ...],
#       "usage": {"input_tokens": N, "output_tokens": M}
#     }
#
# This plugin is intentionally general-purpose: the caller can feed it
# dialogue prompts, code prompts, worldbuilding prompts — whatever. The
# `system` param shapes it. A dedicated DialoguePlugin / CodePlugin can
# wrap this later with specialized prompt scaffolding.
#
# Cost: token-based. Prices are per million tokens and vary by model. We
# default to Sonnet rates and let `pricing` be overridden via config.

extends HttpPluginBase
class_name ClaudePlugin

const BASE_URL: String = "https://api.anthropic.com/v1"
const ANTHROPIC_VERSION: String = "2023-06-01"
const DEFAULT_MODEL: String = "claude-sonnet-4-6"
const DEFAULT_MAX_TOKENS: int = 1024

# USD per million tokens. Overrideable via initialize(config.pricing = {...}).
const DEFAULT_PRICING_USD_PER_MTOK: Dictionary = {
	"claude-opus-4-6":    {"input": 15.0, "output": 75.0},
	"claude-sonnet-4-6":  {"input": 3.0,  "output": 15.0},
	"claude-haiku-4-5":   {"input": 0.80, "output": 4.0},
}

var api_key: String = ""
var pricing: Dictionary = DEFAULT_PRICING_USD_PER_MTOK.duplicate(true)

# task_id -> {state, progress, cancelled, message}
var _tasks: Dictionary = {}


# ---------- Lifecycle ----------

func initialize(config: Dictionary) -> Dictionary:
	var key: String = str(config.get("api_key", ""))
	if key.is_empty():
		return {"success": false, "error": "api_key required"}
	api_key = key
	if config.has("pricing") and config["pricing"] is Dictionary:
		var override: Dictionary = config["pricing"]
		for model_key in override.keys():
			pricing[model_key] = override[model_key]
	return {"success": true}

func health_check() -> Dictionary:
	if api_key.is_empty():
		return {"healthy": false, "message": "api_key not configured"}
	return {"healthy": true, "message": "ok (deferred check)"}

func shutdown() -> void:
	for tid in _tasks.keys():
		_tasks[tid]["cancelled"] = true
	_tasks.clear()


# ---------- Generation ----------

func generate(prompt: String, params: Dictionary) -> String:
	var validation: Dictionary = _validate_params(prompt, params)
	if not validation["valid"]:
		var dummy_id: String = _make_task_id()
		call_deferred("_emit_param_error", dummy_id, validation["error"])
		return dummy_id

	var tid: String = _make_task_id()
	_tasks[tid] = {
		"state": "Running",
		"progress": 0.0,
		"cancelled": false,
		"message": "starting",
	}
	_run_completion(tid, prompt, params)
	return tid

func cancel(task_id: String) -> bool:
	if not _tasks.has(task_id):
		return false
	_tasks[task_id]["cancelled"] = true
	return true

# Rough estimate — we don't know output length in advance, so assume output
# == max_tokens. After completion the `cost` on the result dict uses the
# actual usage block from the API response and is authoritative.
func estimate_cost(prompt: String, params: Dictionary) -> float:
	var model: String = str(params.get("model", DEFAULT_MODEL))
	var max_tokens: int = int(params.get("max_tokens", DEFAULT_MAX_TOKENS))
	var price: Dictionary = pricing.get(model, pricing[DEFAULT_MODEL])
	# ~4 chars per token is the usual English approximation.
	var input_tokens: float = float(prompt.length()) / 4.0
	var input_cost: float = (input_tokens / 1_000_000.0) * float(price["input"])
	var output_cost: float = (float(max_tokens) / 1_000_000.0) * float(price["output"])
	return input_cost + output_cost


# ---------- Introspection ----------

func get_status(task_id: String) -> Dictionary:
	if not _tasks.has(task_id):
		return {"state": "Unknown", "progress": 0.0, "message": "no such task"}
	var t: Dictionary = _tasks[task_id]
	return {"state": t["state"], "progress": t["progress"], "message": t["message"]}

func get_all_tasks() -> Array:
	return _tasks.keys()

func get_metadata() -> Dictionary:
	return {
		"plugin_name": "claude",
		"version": "0.1.0",
		"category": "text",
		"supported_formats": ["plain", "markdown", "json"],
		"capabilities": {
			"parallel": true,
			"streaming": false,  # provider supports SSE; not wired up in this MVP
			"cancel": true,
		},
		"cost_unit": "USD",
		"limits": {
			"max_prompt_length": 200000,   # the real model window is much higher
			"requests_per_minute": 50,
		},
	}

func get_param_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"model": {
				"type": "string",
				"enum": pricing.keys(),
				"default": DEFAULT_MODEL,
				"description": "Model id (determines pricing and capability)."
			},
			"max_tokens": {
				"type": "integer",
				"minimum": 1,
				"maximum": 8192,
				"default": DEFAULT_MAX_TOKENS,
				"description": "Upper bound on generated tokens."
			},
			"system": {
				"type": "string",
				"default": "",
				"description": "System prompt — shapes the assistant's behavior."
			},
			"temperature": {
				"type": "number",
				"minimum": 0.0,
				"maximum": 1.0,
				"default": 1.0,
				"description": "Sampling temperature."
			}
		},
		"required": []
	}


# ---------- Internals ----------

func _validate_params(prompt: String, params: Dictionary) -> Dictionary:
	if prompt.is_empty():
		return {"valid": false, "error": "prompt must not be empty"}
	if params.has("max_tokens"):
		var mt: int = int(params["max_tokens"])
		if mt < 1 or mt > 8192:
			return {"valid": false, "error": "max_tokens must be in [1, 8192]"}
	if params.has("temperature"):
		var t: float = float(params["temperature"])
		if t < 0.0 or t > 1.0:
			return {"valid": false, "error": "temperature must be in [0, 1]"}
	if params.has("model") and not pricing.has(str(params["model"])):
		return {"valid": false, "error": "unknown model: %s" % str(params["model"])}
	return {"valid": true, "error": ""}

func _emit_param_error(task_id: String, message: String) -> void:
	emit_signal("task_failed", task_id, _make_error(ERR_INVALID_PARAMS, message, false))

func _run_completion(task_id: String, prompt: String, params: Dictionary) -> void:
	if api_key.is_empty():
		_fail(task_id, _make_error(ERR_AUTH_FAILED, "api_key not configured", false))
		return

	var model: String = str(params.get("model", DEFAULT_MODEL))
	var max_tokens: int = int(params.get("max_tokens", DEFAULT_MAX_TOKENS))

	var body: Dictionary = {
		"model": model,
		"max_tokens": max_tokens,
		"messages": [{"role": "user", "content": prompt}],
	}
	if params.has("system") and not str(params["system"]).is_empty():
		body["system"] = str(params["system"])
	if params.has("temperature"):
		body["temperature"] = float(params["temperature"])

	emit_signal("task_progress", task_id, 0.05, "submitting")

	var resp: Dictionary = await _http_request(
		"%s/messages" % BASE_URL,
		_auth_headers(),
		HTTPClient.METHOD_POST,
		JSON.stringify(body)
	)

	if _task_aborted(task_id):
		return
	if not resp["success"]:
		_fail(task_id, _make_error(ERR_NETWORK, resp.get("error", "request failed"), true))
		return
	var status: int = resp["response_code"]
	if status >= 400:
		_fail(task_id, _make_http_error(status, resp["headers"], _body_as_text(resp["body"])))
		return

	var parsed: Dictionary = _body_as_json(resp["body"])
	if parsed["parsed"] == null:
		_fail(task_id, _make_error(ERR_PROVIDER_ERROR, "could not parse response: %s" % parsed["error"], false))
		return
	var envelope: Dictionary = parsed["parsed"]
	var text: String = _extract_text(envelope)
	var usage: Dictionary = envelope.get("usage", {}) if envelope.get("usage") is Dictionary else {}
	var actual_cost: float = _compute_actual_cost(model, usage)

	var result: Dictionary = {
		"asset_type": "text",
		"format": "plain",
		"text": text,
		"model": model,
		"usage": usage,
		"cost": actual_cost,
		"plugin": "claude",
		"raw": envelope,
	}
	_tasks.erase(task_id)
	emit_signal("task_completed", task_id, result)

func _extract_text(envelope: Dictionary) -> String:
	var content = envelope.get("content", [])
	if not (content is Array):
		return ""
	var parts: Array = []
	for block in content:
		if block is Dictionary and str(block.get("type", "")) == "text":
			parts.append(str(block.get("text", "")))
	return "\n".join(parts)

func _compute_actual_cost(model: String, usage: Dictionary) -> float:
	var price: Dictionary = pricing.get(model, pricing[DEFAULT_MODEL])
	var input_tokens: float = float(usage.get("input_tokens", 0))
	var output_tokens: float = float(usage.get("output_tokens", 0))
	return (input_tokens / 1_000_000.0) * float(price["input"]) \
		+ (output_tokens / 1_000_000.0) * float(price["output"])

func _task_aborted(task_id: String) -> bool:
	if not _tasks.has(task_id):
		return true
	if bool(_tasks[task_id]["cancelled"]):
		emit_signal("task_failed", task_id, _make_error(ERR_CANCELLED, "cancelled", false))
		_tasks.erase(task_id)
		return true
	return false

func _fail(task_id: String, error: Dictionary) -> void:
	emit_signal("task_failed", task_id, error)
	_tasks.erase(task_id)

func _auth_headers() -> PackedStringArray:
	return PackedStringArray([
		"x-api-key: %s" % api_key,
		"anthropic-version: %s" % ANTHROPIC_VERSION,
		"Content-Type: application/json",
		"Accept: application/json",
	])
