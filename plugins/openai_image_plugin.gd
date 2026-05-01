# openai_image_plugin.gd
# OpenAI text-to-image plugin (Phase 36 / ADR 036).
#
# API:
#   POST https://api.openai.com/v1/images/generations
#     body: {"model": "...", "prompt": "...", "size": "...",
#            "quality": "...", "n": 1, "response_format": "b64_json"}
#     response: {"data": [{"b64_json": "...", "revised_prompt": "..."}]}
#   GET  https://api.openai.com/v1/models
#     response: {"data": [{"id": "...", ...}]} — used for test_connection()
#
# Auth: "Authorization: Bearer <api_key>"
#
# Sync (no polling): single POST returns the image bytes inline as
# base64 once the model finishes. We decode and persist to
# user://assets/image/<task_id>.png so callers have a stable file
# path — same convention as ElevenLabs uses for audio.
#
# Cost model: OpenAI bills per image, with a per-image price that
# varies by model + size + quality. We use a single
# `per_image_cost_usd` config (default $0.040 = gpt-image-1 standard
# 1024×1024) — override in the credential store / settings to
# match your actual rate card.

extends HttpPluginBase
class_name OpenAIImagePlugin

const BASE_URL: String = "https://api.openai.com/v1"
const DEFAULT_MODEL: String = "gpt-image-1"
const DEFAULT_SIZE: String = "1024x1024"
const DEFAULT_QUALITY: String = "standard"
const _VALID_SIZES: Array = ["1024x1024", "1024x1792", "1792x1024"]
const _VALID_QUALITIES: Array = ["standard", "hd"]
const OUTPUT_DIR: String = "user://assets/image"

var api_key: String = ""
var per_image_cost_usd: float = 0.040

# task_id -> {state, progress, cancelled, message}
var _tasks: Dictionary = {}


# ---------- Lifecycle ----------

func initialize(config: Dictionary) -> Dictionary:
	var key: String = str(config.get("api_key", ""))
	if key.is_empty():
		return {"success": false, "error": "api_key required"}
	api_key = key
	if config.has("per_image_cost_usd"):
		per_image_cost_usd = float(config["per_image_cost_usd"])
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIR))
	return {"success": true}

func health_check() -> Dictionary:
	if api_key.is_empty():
		return {"healthy": false, "message": "api_key not configured"}
	# Same deferred-check policy as Tripo / ElevenLabs — startup probes
	# burn quota for no real signal. The Test button (ADR 022) is the
	# active probe surface.
	return {"healthy": true, "message": "ok (deferred check)"}

func shutdown() -> void:
	for tid in _tasks.keys():
		_tasks[tid]["cancelled"] = true
	_tasks.clear()

# Cheap probe: GET /v1/models. Returns 200 + a model list when the
# api_key is valid, 401 when not. Free in OpenAI's billing — same
# pattern as ElevenLabs's /v1/user.
func test_connection() -> Dictionary:
	if api_key.is_empty():
		return {"success": false, "error": "api_key not configured"}
	var headers: PackedStringArray = PackedStringArray([
		"Authorization: Bearer " + api_key,
	])
	var resp: Dictionary = await _http_request(
		BASE_URL + "/models", headers, HTTPClient.METHOD_GET, "")
	if not bool(resp.get("success", false)):
		return {"success": false,
				"error": "transport: %s" % str(resp.get("error", "unknown"))}
	var status: int = int(resp.get("response_code", 0))
	if status >= 200 and status < 300:
		return {"success": true, "message": "OK (HTTP %d)" % status}
	if status == 401 or status == 403:
		return {"success": false, "error": "auth failed (HTTP %d)" % status}
	return {"success": false, "error": "HTTP %d" % status}


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
	_run_image_gen(tid, prompt, params)
	return tid

func cancel(task_id: String) -> bool:
	if not _tasks.has(task_id):
		return false
	_tasks[task_id]["cancelled"] = true
	return true

func estimate_cost(_prompt: String, _params: Dictionary) -> float:
	# Per-image, prompt length doesn't enter the bill.
	return per_image_cost_usd


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
		"plugin_name": "openai_image",
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
			"max_prompt_length": 4000,  # OpenAI's documented prompt limit
			"requests_per_minute": 50,
		},
	}

func get_param_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"model": {
				"type": "string",
				"default": DEFAULT_MODEL,
				"description": "OpenAI image model (gpt-image-1, dall-e-3, ...)."
			},
			"size": {
				"type": "string",
				"enum": _VALID_SIZES,
				"default": DEFAULT_SIZE,
				"description": "Image dimensions. Square = 1024×1024."
			},
			"quality": {
				"type": "string",
				"enum": _VALID_QUALITIES,
				"default": DEFAULT_QUALITY,
				"description": "standard (faster, cheaper) or hd."
			},
		},
		"required": []
	}


# ---------- Internals ----------

func _validate_params(prompt: String, params: Dictionary) -> Dictionary:
	if prompt.is_empty():
		return {"valid": false, "error": "prompt must not be empty"}
	if prompt.length() > 4000:
		return {"valid": false, "error": "prompt exceeds 4000 characters"}
	if params.has("size") and not _VALID_SIZES.has(str(params["size"])):
		return {"valid": false, "error": "size must be one of %s" % str(_VALID_SIZES)}
	if params.has("quality") and not _VALID_QUALITIES.has(str(params["quality"])):
		return {"valid": false, "error": "quality must be one of %s" % str(_VALID_QUALITIES)}
	return {"valid": true, "error": ""}

func _emit_param_error(task_id: String, message: String) -> void:
	emit_signal("task_failed", task_id, _make_error(ERR_INVALID_PARAMS, message, false))

func _run_image_gen(task_id: String, prompt: String, params: Dictionary) -> void:
	if api_key.is_empty():
		_fail(task_id, _make_error(ERR_AUTH_FAILED, "api_key not configured", false))
		return

	var model: String = str(params.get("model", DEFAULT_MODEL))
	var size: String = str(params.get("size", DEFAULT_SIZE))
	var quality: String = str(params.get("quality", DEFAULT_QUALITY))

	var body: Dictionary = {
		"model":           model,
		"prompt":          prompt,
		"size":            size,
		"quality":         quality,
		"n":               1,
		"response_format": "b64_json",
	}

	emit_signal("task_progress", task_id, 0.05, "submitting")

	var url: String = BASE_URL + "/images/generations"
	var resp: Dictionary = await _http_request(
		url,
		_auth_headers(),
		HTTPClient.METHOD_POST,
		JSON.stringify(body)
	)

	if _task_aborted(task_id):
		return
	if not resp["success"]:
		_fail(task_id, _make_error(ERR_NETWORK, resp.get("error", "request failed"), true))
		return
	var status: int = int(resp["response_code"])
	if status >= 400:
		_fail(task_id, _make_http_error(status, resp["headers"], _body_as_text(resp["body"])))
		return

	# Body is JSON; parse out data[0].b64_json. Use the JSON instance API
	# so a malformed body returns an error code instead of an engine
	# push_error (same idiom as settings_manager._load).
	var parser: JSON = JSON.new()
	var err: Error = parser.parse(_body_as_text(resp["body"]))
	if err != OK:
		_fail(task_id, _make_error(ERR_PROVIDER_ERROR,
			"malformed JSON: %s" % parser.get_error_message(), false))
		return
	var parsed = parser.data
	if not (parsed is Dictionary):
		_fail(task_id, _make_error(ERR_PROVIDER_ERROR, "response was not a JSON object", false))
		return
	var data_arr = (parsed as Dictionary).get("data", [])
	if not (data_arr is Array) or (data_arr as Array).is_empty():
		_fail(task_id, _make_error(ERR_PROVIDER_ERROR, "no images in response", false))
		return
	var first = (data_arr as Array)[0]
	if not (first is Dictionary):
		_fail(task_id, _make_error(ERR_PROVIDER_ERROR, "data[0] was not an object", false))
		return
	var b64: String = str((first as Dictionary).get("b64_json", ""))
	if b64.is_empty():
		_fail(task_id, _make_error(ERR_PROVIDER_ERROR, "no b64_json in data[0]", false))
		return
	# OpenAI may return a revised_prompt — echo it on the result so the
	# UI can show what the model actually rendered.
	var revised: String = str((first as Dictionary).get("revised_prompt", ""))

	var image_bytes: PackedByteArray = Marshalls.base64_to_raw(b64)
	if image_bytes.size() == 0:
		_fail(task_id, _make_error(ERR_PROVIDER_ERROR, "base64 decode produced no bytes", false))
		return

	var out_path: String = "%s/%s.png" % [OUTPUT_DIR, task_id]
	var f: FileAccess = FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		_fail(task_id, _make_error(ERR_UNKNOWN, "cannot write image file: %s" % out_path, false))
		return
	f.store_buffer(image_bytes)
	f.close()

	var result: Dictionary = {
		"asset_type":     "image",
		"format":         "png",
		"path":           out_path,
		"model":          model,
		"size":           size,
		"quality":        quality,
		"revised_prompt": revised,
		"cost":           estimate_cost(prompt, params),
		"plugin":         "openai_image",
	}
	_tasks.erase(task_id)
	emit_signal("task_completed", task_id, result)

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
		"Authorization: Bearer %s" % api_key,
		"Content-Type: application/json",
	])
