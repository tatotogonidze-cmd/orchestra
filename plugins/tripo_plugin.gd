# tripo_plugin.gd
# Tripo AI text-to-3D (v2 OpenAPI).
#
# API surface used here:
#   POST https://api.tripo3d.ai/v2/openapi/task          -> submit a task
#   GET  https://api.tripo3d.ai/v2/openapi/task/{id}     -> poll status/output
#
# Auth: "Authorization: Bearer <api_key>"
#
# Lifecycle of one generate() call:
#   1. POST task -> inner_task_id (Tripo's)
#   2. GET poll loop every `poll_interval_s` until status in {success, failed, banned, expired}
#      emitting task_progress each tick
#   3. Emit task_completed (with the glb/obj URL) or task_failed
#
# Cost: Tripo's pricing is per task; we surface an estimate of $0.20 USD as a
# rough average. Real billing comes from the provider. See `estimate_cost`.
#
# This plugin does NOT download the asset bytes — it returns the URL in
# `result.path`. The Asset Manager is responsible for downloading, caching,
# and importing into the project.

extends HttpPluginBase
class_name TripoPlugin

const BASE_URL: String = "https://api.tripo3d.ai/v2/openapi"
const _VALID_STYLES: Array = ["realistic", "lowpoly", "voxel", "cartoon", "anime"]
const _TERMINAL_STATUSES: Array = ["success", "failed", "banned", "expired"]

var api_key: String = ""
var poll_interval_s: float = 2.0
var max_poll_attempts: int = 60  # 60 * 2s = 2 minutes

# inner_task_id (ours, NOT tripo's) -> {
#   state, progress, cancelled, tripo_task_id, message
# }
var _tasks: Dictionary = {}


# ---------- Lifecycle ----------

func initialize(config: Dictionary) -> Dictionary:
	var key: String = str(config.get("api_key", ""))
	if key.is_empty():
		return {"success": false, "error": "api_key required"}
	api_key = key
	return {"success": true}

func health_check() -> Dictionary:
	if api_key.is_empty():
		return {"healthy": false, "message": "api_key not configured"}
	# Tripo exposes no dedicated /ping endpoint; a cheap way to verify the key is
	# to hit /task/00000000-0000-0000-0000-000000000000 and treat 401 -> unhealthy,
	# 404/400 -> healthy (key worked, task doesn't exist). To avoid spending on
	# real traffic during startup, we consider a non-empty key "healthy" here and
	# let the first real generate() surface auth errors.
	return {"healthy": true, "message": "ok (deferred check)"}

func shutdown() -> void:
	for tid in _tasks.keys():
		_tasks[tid]["cancelled"] = true
	_tasks.clear()

# Cheap probe: GET /v2/openapi/user/balance. Free, returns 200 + the
# account's balance when the api_key is valid, 401 otherwise. Used by
# the credential editor's Test button (ADR 022).
func test_connection() -> Dictionary:
	if api_key.is_empty():
		return {"success": false, "error": "api_key not configured"}
	var headers: PackedStringArray = PackedStringArray([
		"Authorization: Bearer " + api_key,
	])
	var resp: Dictionary = await _http_request(
		BASE_URL + "/user/balance", headers, HTTPClient.METHOD_GET, "")
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
		# Can't issue a task id — signal an immediate failure via deferred call so
		# callers that subscribe after generate() still see the event.
		var dummy_id: String = _make_task_id()
		call_deferred("_emit_param_error", dummy_id, validation["error"])
		return dummy_id

	var tid: String = _make_task_id()
	_tasks[tid] = {
		"state": "Queued",
		"progress": 0.0,
		"cancelled": false,
		"tripo_task_id": "",
		"message": "submitting",
	}
	_run_tripo_task(tid, prompt, params)
	return tid

func cancel(task_id: String) -> bool:
	if not _tasks.has(task_id):
		return false
	_tasks[task_id]["cancelled"] = true
	return true

# Tripo pricing varies; we surface a flat rough estimate. Override by config if you prefer.
func estimate_cost(_prompt: String, _params: Dictionary) -> float:
	return 0.20


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
		"plugin_name": "tripo",
		"version": "0.1.0",
		"category": "3d",
		"supported_formats": ["glb", "fbx", "obj"],
		"capabilities": {
			"parallel": true,
			"streaming": false,
			"cancel": true,
		},
		"cost_unit": "USD",
		"limits": {
			"max_prompt_length": 500,
			"requests_per_minute": 30,
		},
	}

func get_param_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"style": {
				"type": "string",
				"enum": _VALID_STYLES,
				"default": "realistic",
				"description": "Mesh style bucket."
			},
			"texture": {
				"type": "boolean",
				"default": true,
				"description": "Generate a base color texture."
			},
			"pbr": {
				"type": "boolean",
				"default": true,
				"description": "Generate full PBR maps (requires texture=true)."
			},
			"negative_prompt": {
				"type": "string",
				"default": "",
				"description": "Optional content to avoid."
			}
		},
		"required": []
	}


# ---------- Internals ----------

func _validate_params(prompt: String, params: Dictionary) -> Dictionary:
	if prompt.is_empty():
		return {"valid": false, "error": "prompt must not be empty"}
	if prompt.length() > 500:
		return {"valid": false, "error": "prompt exceeds 500 characters"}
	if params.has("style") and not _VALID_STYLES.has(str(params["style"])):
		return {"valid": false, "error": "style must be one of %s" % str(_VALID_STYLES)}
	return {"valid": true, "error": ""}

func _emit_param_error(task_id: String, message: String) -> void:
	emit_signal("task_failed", task_id, _make_error(ERR_INVALID_PARAMS, message, false))

func _run_tripo_task(task_id: String, prompt: String, params: Dictionary) -> void:
	if api_key.is_empty():
		_fail(task_id, _make_error(ERR_AUTH_FAILED, "api_key not configured", false))
		return

	var tree: SceneTree = get_tree()
	if tree == null:
		_fail(task_id, _make_error(ERR_UNKNOWN, "plugin not in scene tree", false))
		return

	# 1. Submit.
	var submit_body: Dictionary = {
		"type": "text_to_model",
		"prompt": prompt,
		"style": str(params.get("style", "realistic")),
		"texture": bool(params.get("texture", true)),
		"pbr": bool(params.get("pbr", true)),
	}
	if params.has("negative_prompt") and not str(params["negative_prompt"]).is_empty():
		submit_body["negative_prompt"] = str(params["negative_prompt"])

	_tasks[task_id]["state"] = "Running"
	_tasks[task_id]["message"] = "submitting"
	emit_signal("task_progress", task_id, 0.05, "submitting")

	var submit_resp: Dictionary = await _http_request(
		"%s/task" % BASE_URL,
		_auth_headers(),
		HTTPClient.METHOD_POST,
		JSON.stringify(submit_body)
	)

	if _task_aborted(task_id):
		return
	if not submit_resp["success"]:
		_fail(task_id, _make_error(ERR_NETWORK, submit_resp.get("error", "submit failed"), true))
		return
	var status: int = submit_resp["response_code"]
	if status >= 400:
		_fail(task_id, _make_http_error(status, submit_resp["headers"], _body_as_text(submit_resp["body"])))
		return

	var parsed: Dictionary = _body_as_json(submit_resp["body"])
	if parsed["parsed"] == null:
		_fail(task_id, _make_error(ERR_PROVIDER_ERROR, "could not parse submit response: %s" % parsed["error"], false))
		return
	var envelope: Dictionary = parsed["parsed"]
	if int(envelope.get("code", -1)) != 0 or not (envelope.get("data") is Dictionary):
		_fail(task_id, _make_error(ERR_PROVIDER_ERROR, "bad submit envelope: %s" % str(envelope), false))
		return

	var tripo_id: String = str(envelope["data"].get("task_id", ""))
	if tripo_id.is_empty():
		_fail(task_id, _make_error(ERR_PROVIDER_ERROR, "submit response missing task_id", false))
		return
	_tasks[task_id]["tripo_task_id"] = tripo_id
	_tasks[task_id]["message"] = "queued"
	emit_signal("task_progress", task_id, 0.10, "submitted (tripo id: %s)" % tripo_id)

	# 2. Poll.
	var attempt: int = 0
	while attempt < max_poll_attempts:
		attempt += 1
		await tree.create_timer(poll_interval_s).timeout
		if _task_aborted(task_id):
			return

		var poll_resp: Dictionary = await _http_request(
			"%s/task/%s" % [BASE_URL, tripo_id],
			_auth_headers(),
			HTTPClient.METHOD_GET
		)
		if _task_aborted(task_id):
			return
		if not poll_resp["success"]:
			# Network blip — keep trying; will hit max_poll_attempts if persistent.
			continue
		var poll_status: int = poll_resp["response_code"]
		if poll_status >= 400:
			_fail(task_id, _make_http_error(poll_status, poll_resp["headers"], _body_as_text(poll_resp["body"])))
			return
		var poll_parsed: Dictionary = _body_as_json(poll_resp["body"])
		if poll_parsed["parsed"] == null:
			continue
		var envelope2: Dictionary = poll_parsed["parsed"]
		var data: Dictionary = envelope2.get("data", {}) if envelope2.get("data") is Dictionary else {}
		var state: String = str(data.get("status", "")).to_lower()
		var progress_pct: float = float(data.get("progress", 0)) / 100.0
		if progress_pct > 0.0:
			_tasks[task_id]["progress"] = progress_pct
			emit_signal("task_progress", task_id, progress_pct, state)

		if _TERMINAL_STATUSES.has(state):
			if state == "success":
				var output: Dictionary = data.get("output", {}) if data.get("output") is Dictionary else {}
				var model_url: String = str(output.get("model", ""))
				if model_url.is_empty():
					_fail(task_id, _make_error(ERR_PROVIDER_ERROR, "success status but no model url", false))
					return
				var result: Dictionary = {
					"asset_type": "3d",
					"format": _infer_format(model_url),
					"path": model_url,
					"style": str(params.get("style", "realistic")),
					"cost": estimate_cost(prompt, params),
					"plugin": "tripo",
					"raw": envelope2,
				}
				_tasks.erase(task_id)
				emit_signal("task_completed", task_id, result)
				return
			# failed / banned / expired
			var msg: String = str(data.get("message", state))
			var code: String = ERR_PROVIDER_ERROR
			if state == "banned":
				code = ERR_INVALID_PARAMS
			_fail(task_id, _make_error(code, "tripo reports '%s': %s" % [state, msg], false))
			return

	# Loop exhausted.
	_fail(task_id, _make_error(ERR_TIMEOUT, "poll timeout after %d attempts" % max_poll_attempts, true, int(poll_interval_s * 1000)))

# True if the task has been cancelled or erased since dispatch.
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
		"Accept: application/json",
	])

func _infer_format(url: String) -> String:
	var lower: String = url.to_lower()
	for ext in ["glb", "fbx", "obj", "usdz", "ply"]:
		if lower.find("." + ext) >= 0:
			return ext
	return "unknown"
