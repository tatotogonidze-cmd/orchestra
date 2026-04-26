# http_plugin_base.gd
# Convenience base for plugins that talk to an HTTP/JSON provider.
#
# Extends BasePlugin. Provides:
#   - await-friendly _http_request() that returns {success, result, response_code, headers, body, error?}
#   - HTTP status -> standard ERR_* code mapping
#   - Retry-After header parsing (seconds -> ms, also handles HTTP-date fallback)
#   - _make_http_error() convenience for surfacing failed responses as standard errors
#
# Does NOT prescribe how a plugin polls, streams, or saves bytes — those choices
# are provider-specific. Stays out of the way.
#
# IMPORTANT: this file assumes plugins are in the scene tree. PluginManager
# guarantees that by reparenting / adding children before calling generate().

extends BasePlugin
class_name HttpPluginBase

# Default connection and total timeouts per request. Providers can override.
var http_connect_timeout_s: float = 10.0
var http_total_timeout_s: float = 120.0


# ---------- Core request helper ----------

# Perform one HTTP request and await its completion.
#
# Returns a Dictionary:
#   success        : bool      — did the HTTPRequest itself dispatch and complete
#   result         : int       — HTTPRequest.RESULT_*   (0 == SUCCESS)
#   response_code  : int       — HTTP status (0 if request failed before a response)
#   headers        : PackedStringArray
#   body           : PackedByteArray
#   error          : String    — populated on dispatch/transport errors
#
# On transport-level failure (DNS, TLS, timeout) success=false and error is set;
# response_code will be 0.
func _http_request(
	url: String,
	headers: PackedStringArray,
	method: int,
	body: String = ""
) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = http_total_timeout_s
	add_child(http)
	var err: int = http.request(url, headers, method, body)
	if err != OK:
		http.queue_free()
		return {
			"success": false,
			"result": -1,
			"response_code": 0,
			"headers": PackedStringArray(),
			"body": PackedByteArray(),
			"error": "HTTPRequest.request() returned %d" % err,
		}
	var out: Array = await http.request_completed
	http.queue_free()
	var result_code: int = int(out[0])
	var resp: int = int(out[1])
	var hdrs: PackedStringArray = out[2]
	var payload: PackedByteArray = out[3]
	var ok: bool = (result_code == HTTPRequest.RESULT_SUCCESS)
	return {
		"success": ok,
		"result": result_code,
		"response_code": resp,
		"headers": hdrs,
		"body": payload,
		"error": "" if ok else _describe_result_code(result_code),
	}


# ---------- Response-level helpers ----------

# Map an HTTP status code to a BasePlugin.ERR_* constant.
func _status_to_error_code(status: int) -> String:
	if status == 401 or status == 403:
		return ERR_AUTH_FAILED
	if status == 408 or status == 504:
		return ERR_TIMEOUT
	if status == 429:
		return ERR_RATE_LIMIT
	if status >= 500:
		return ERR_PROVIDER_ERROR
	if status >= 400:
		return ERR_INVALID_PARAMS
	return ERR_UNKNOWN

# Build a standard error dict from an HTTP response. Retryable for 429 and 5xx.
func _make_http_error(status: int, headers: PackedStringArray, body_text: String) -> Dictionary:
	var code: String = _status_to_error_code(status)
	var retryable: bool = (status == 429 or status >= 500)
	var retry_after_ms: int = _parse_retry_after(headers)
	var msg: String = "HTTP %d" % status
	if not body_text.is_empty():
		# Truncate long bodies so error messages stay scannable.
		var trimmed: String = body_text.substr(0, 500)
		msg += ": %s" % trimmed
	return _make_error(code, msg, retryable, retry_after_ms, {
		"http_status": status,
		"response_body": body_text,
	})

# Retry-After per RFC 7231: either a non-negative integer (seconds) or an HTTP-date.
# Returns milliseconds, or 0 if header absent/unparseable.
func _parse_retry_after(headers: PackedStringArray) -> int:
	for h in headers:
		var idx: int = h.find(":")
		if idx < 0:
			continue
		var name: String = h.substr(0, idx).strip_edges().to_lower()
		if name != "retry-after":
			continue
		var val: String = h.substr(idx + 1).strip_edges()
		if val.is_valid_int():
			return max(0, int(val)) * 1000
		# HTTP-date parsing is deliberately out of scope — fall back to 0.
		return 0
	return 0

# Decode body bytes as UTF-8 text. Convenience for JSON providers.
func _body_as_text(body: PackedByteArray) -> String:
	return body.get_string_from_utf8()

# Decode body bytes as JSON. Returns {parsed: Variant, error: String}.
#
# We use JSON.new().parse() rather than JSON.parse_string() because the latter
# emits an engine-level push_error on malformed input, which GUT flags as an
# unexpected error during test runs. The instance-based API returns an Error
# code and keeps failures quiet.
func _body_as_json(body: PackedByteArray) -> Dictionary:
	var text: String = _body_as_text(body)
	if text.is_empty():
		return {"parsed": null, "error": "empty body"}
	var json := JSON.new()
	var err: int = json.parse(text)
	if err != OK:
		return {"parsed": null, "error": "invalid JSON: %s" % text.substr(0, 200)}
	return {"parsed": json.data, "error": ""}


# ---------- Internals ----------

func _describe_result_code(code: int) -> String:
	match code:
		HTTPRequest.RESULT_CHUNKED_BODY_SIZE_MISMATCH: return "chunked body size mismatch"
		HTTPRequest.RESULT_CANT_CONNECT:               return "cannot connect"
		HTTPRequest.RESULT_CANT_RESOLVE:               return "cannot resolve host"
		HTTPRequest.RESULT_CONNECTION_ERROR:           return "connection error"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:        return "TLS handshake error"
		HTTPRequest.RESULT_NO_RESPONSE:                return "no response"
		HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED:   return "body too large"
		HTTPRequest.RESULT_REQUEST_FAILED:             return "request failed"
		HTTPRequest.RESULT_DOWNLOAD_FILE_CANT_OPEN:    return "cannot open download file"
		HTTPRequest.RESULT_DOWNLOAD_FILE_WRITE_ERROR:  return "download write error"
		HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED:     return "redirect limit reached"
		HTTPRequest.RESULT_TIMEOUT:                    return "timeout"
		_:                                             return "unknown (%d)" % code
