# elevenlabs_plugin.gd
# ElevenLabs Text-to-Speech.
#
# API:
#   POST https://api.elevenlabs.io/v1/text-to-speech/{voice_id}
#     body: {"text": "...", "model_id": "...", "voice_settings": {...}}
#     response: audio/mpeg bytes (mp3)
#   GET  https://api.elevenlabs.io/v1/voices
#     response: {"voices": [...]}
#
# Auth: "xi-api-key: <api_key>"
#
# Unlike Tripo, ElevenLabs is SINGLE-SHOT: one POST returns the audio directly.
# We write bytes to user://assets/audio/<task_id>.<ext> and return that path.
#
# Cost model: ElevenLabs bills by character. We use $0.000165/char as a rough
# estimate for the standard plan — override via `per_char_cost_usd` config.

extends HttpPluginBase
class_name ElevenLabsPlugin

const BASE_URL: String = "https://api.elevenlabs.io/v1"
const DEFAULT_VOICE_ID: String = "21m00Tcm4TlvDq8ikWAM"  # "Rachel" — public sample voice
const DEFAULT_MODEL: String = "eleven_multilingual_v2"
# ElevenLabs `output_format` values (we keep the short label as the param face;
# the label is what we use for the file extension too).
#   mp3 -> mp3_44100_128
#   pcm -> pcm_44100  (raw 16-bit PCM, 44.1 kHz; writable as .pcm)
const _FORMAT_TO_OUTPUT_FORMAT: Dictionary = {
	"mp3": "mp3_44100_128",
	"pcm": "pcm_44100",
}
const _VALID_FORMATS: Array = ["mp3", "pcm"]
const OUTPUT_DIR: String = "user://assets/audio"

var api_key: String = ""
var per_char_cost_usd: float = 0.000165

# task_id -> {state, progress, cancelled, message}
var _tasks: Dictionary = {}


# ---------- Lifecycle ----------

func initialize(config: Dictionary) -> Dictionary:
	var key: String = str(config.get("api_key", ""))
	if key.is_empty():
		return {"success": false, "error": "api_key required"}
	api_key = key
	if config.has("per_char_cost_usd"):
		per_char_cost_usd = float(config["per_char_cost_usd"])
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIR))
	return {"success": true}

func health_check() -> Dictionary:
	if api_key.is_empty():
		return {"healthy": false, "message": "api_key not configured"}
	# Same deferred-check policy as Tripo — avoid spending traffic on startup.
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
	_run_tts(tid, prompt, params)
	return tid

func cancel(task_id: String) -> bool:
	if not _tasks.has(task_id):
		return false
	_tasks[task_id]["cancelled"] = true
	return true

func estimate_cost(prompt: String, _params: Dictionary) -> float:
	return per_char_cost_usd * float(prompt.length())


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
		"plugin_name": "elevenlabs",
		"version": "0.1.0",
		"category": "audio",
		"supported_formats": _VALID_FORMATS,
		"capabilities": {
			"parallel": true,
			"streaming": false,   # provider supports it; not wired up in this MVP
			"cancel": true,
		},
		"cost_unit": "USD",
		"limits": {
			"max_prompt_length": 5000,
			"requests_per_minute": 120,
		},
	}

func get_param_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"voice_id": {
				"type": "string",
				"default": DEFAULT_VOICE_ID,
				"description": "ElevenLabs voice id (see /v1/voices)."
			},
			"model_id": {
				"type": "string",
				"default": DEFAULT_MODEL,
				"description": "Synthesis model, e.g. eleven_multilingual_v2."
			},
			"stability": {
				"type": "number",
				"minimum": 0.0,
				"maximum": 1.0,
				"default": 0.5,
				"description": "Lower = more expressive; higher = more consistent."
			},
			"similarity_boost": {
				"type": "number",
				"minimum": 0.0,
				"maximum": 1.0,
				"default": 0.5,
				"description": "How closely to mimic the reference voice."
			},
			"format": {
				"type": "string",
				"enum": _VALID_FORMATS,
				"default": "mp3",
				"description": "Output container."
			}
		},
		"required": []
	}


# ---------- Internals ----------

func _validate_params(prompt: String, params: Dictionary) -> Dictionary:
	if prompt.is_empty():
		return {"valid": false, "error": "prompt (text) must not be empty"}
	if prompt.length() > 5000:
		return {"valid": false, "error": "prompt exceeds 5000 characters"}
	for k in ["stability", "similarity_boost"]:
		if params.has(k):
			var v: float = float(params[k])
			if v < 0.0 or v > 1.0:
				return {"valid": false, "error": "%s must be in [0,1]" % k}
	if params.has("format") and not _VALID_FORMATS.has(str(params["format"])):
		return {"valid": false, "error": "format must be one of %s" % str(_VALID_FORMATS)}
	return {"valid": true, "error": ""}

func _emit_param_error(task_id: String, message: String) -> void:
	emit_signal("task_failed", task_id, _make_error(ERR_INVALID_PARAMS, message, false))

func _run_tts(task_id: String, prompt: String, params: Dictionary) -> void:
	if api_key.is_empty():
		_fail(task_id, _make_error(ERR_AUTH_FAILED, "api_key not configured", false))
		return

	var voice_id: String = str(params.get("voice_id", DEFAULT_VOICE_ID))
	var model_id: String = str(params.get("model_id", DEFAULT_MODEL))
	var stability: float = float(params.get("stability", 0.5))
	var similarity: float = float(params.get("similarity_boost", 0.5))
	var fmt: String = str(params.get("format", "mp3"))
	var output_format: String = str(_FORMAT_TO_OUTPUT_FORMAT.get(fmt, "mp3_44100_128"))

	var body: Dictionary = {
		"text": prompt,
		"model_id": model_id,
		"voice_settings": {
			"stability": stability,
			"similarity_boost": similarity,
		},
	}

	emit_signal("task_progress", task_id, 0.05, "submitting")

	var url: String = "%s/text-to-speech/%s?output_format=%s" % [BASE_URL, voice_id, output_format]
	var resp: Dictionary = await _http_request(
		url,
		_auth_headers(fmt),
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

	var audio_bytes: PackedByteArray = resp["body"]
	if audio_bytes.size() == 0:
		_fail(task_id, _make_error(ERR_PROVIDER_ERROR, "empty audio response", false))
		return

	# Persist bytes to user:// so callers have a stable file path.
	var out_path: String = "%s/%s.%s" % [OUTPUT_DIR, task_id, fmt]
	var f: FileAccess = FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		_fail(task_id, _make_error(ERR_UNKNOWN, "cannot write audio file: %s" % out_path, false))
		return
	f.store_buffer(audio_bytes)
	f.close()

	var result: Dictionary = {
		"asset_type": "audio",
		"format": fmt,
		"path": out_path,
		"voice_id": voice_id,
		"model_id": model_id,
		"char_count": prompt.length(),
		"cost": estimate_cost(prompt, params),
		"plugin": "elevenlabs",
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

func _auth_headers(fmt: String) -> PackedStringArray:
	var accept: String = "audio/mpeg"
	match fmt:
		"wav": accept = "audio/wav"
		"pcm": accept = "audio/pcm"
		_:     accept = "audio/mpeg"
	return PackedStringArray([
		"xi-api-key: %s" % api_key,
		"Content-Type: application/json",
		"Accept: %s" % accept,
	])
