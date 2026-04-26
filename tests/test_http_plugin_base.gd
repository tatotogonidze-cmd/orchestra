# Tests for HttpPluginBase utility functions (status mapping, Retry-After
# parsing, JSON body decoding). Does NOT exercise real HTTP.

extends GutTest

const HttpPluginBaseScript = preload("res://scripts/http_plugin_base.gd")
const BasePluginScript = preload("res://scripts/base_plugin.gd")

var plugin

func before_each():
	plugin = HttpPluginBaseScript.new()
	add_child_autofree(plugin)

# ---------- status -> error code ----------

func test_status_401_maps_to_auth_failed():
	assert_eq(plugin._status_to_error_code(401), BasePluginScript.ERR_AUTH_FAILED)
	assert_eq(plugin._status_to_error_code(403), BasePluginScript.ERR_AUTH_FAILED)

func test_status_429_maps_to_rate_limit():
	assert_eq(plugin._status_to_error_code(429), BasePluginScript.ERR_RATE_LIMIT)

func test_status_5xx_maps_to_provider_error():
	assert_eq(plugin._status_to_error_code(500), BasePluginScript.ERR_PROVIDER_ERROR)
	assert_eq(plugin._status_to_error_code(503), BasePluginScript.ERR_PROVIDER_ERROR)

func test_status_timeout_codes_map_to_timeout():
	assert_eq(plugin._status_to_error_code(408), BasePluginScript.ERR_TIMEOUT)
	assert_eq(plugin._status_to_error_code(504), BasePluginScript.ERR_TIMEOUT)

func test_status_other_4xx_maps_to_invalid_params():
	assert_eq(plugin._status_to_error_code(400), BasePluginScript.ERR_INVALID_PARAMS)
	assert_eq(plugin._status_to_error_code(422), BasePluginScript.ERR_INVALID_PARAMS)

func test_status_2xx_maps_to_unknown():
	# We don't expect _status_to_error_code to be called for 2xx, but the
	# mapping should still be defined — "UNKNOWN" is the sentinel.
	assert_eq(plugin._status_to_error_code(200), BasePluginScript.ERR_UNKNOWN)

# ---------- Retry-After parsing ----------

func test_retry_after_seconds():
	var headers: PackedStringArray = PackedStringArray([
		"Content-Type: application/json",
		"Retry-After: 7",
	])
	assert_eq(plugin._parse_retry_after(headers), 7000)

func test_retry_after_case_insensitive():
	var headers: PackedStringArray = PackedStringArray(["retry-after: 2"])
	assert_eq(plugin._parse_retry_after(headers), 2000)

func test_retry_after_absent_returns_zero():
	var headers: PackedStringArray = PackedStringArray(["Content-Type: text/html"])
	assert_eq(plugin._parse_retry_after(headers), 0)

func test_retry_after_http_date_returns_zero():
	# HTTP-date parsing is deliberately out of scope.
	var headers: PackedStringArray = PackedStringArray(["Retry-After: Wed, 21 Oct 2026 07:28:00 GMT"])
	assert_eq(plugin._parse_retry_after(headers), 0)

# ---------- body -> json ----------

func test_body_as_json_valid():
	var text: String = "{\"ok\": true, \"n\": 42}"
	var bytes: PackedByteArray = text.to_utf8_buffer()
	var r: Dictionary = plugin._body_as_json(bytes)
	assert_true(r["parsed"] is Dictionary)
	assert_eq(r["parsed"]["ok"], true)
	assert_eq(int(r["parsed"]["n"]), 42)

func test_body_as_json_empty():
	var r: Dictionary = plugin._body_as_json(PackedByteArray())
	assert_null(r["parsed"])
	assert_true(str(r["error"]).find("empty") >= 0)

func test_body_as_json_invalid():
	var bytes: PackedByteArray = "not json".to_utf8_buffer()
	var r: Dictionary = plugin._body_as_json(bytes)
	assert_null(r["parsed"])
	assert_true(str(r["error"]).find("invalid JSON") >= 0)

# ---------- _make_http_error ----------

func test_make_http_error_429_is_retryable():
	var err: Dictionary = plugin._make_http_error(429, PackedStringArray(["Retry-After: 3"]), "slow down")
	assert_eq(err["code"], BasePluginScript.ERR_RATE_LIMIT)
	assert_true(bool(err["retryable"]))
	assert_eq(int(err["retry_after_ms"]), 3000)

func test_make_http_error_401_not_retryable():
	var err: Dictionary = plugin._make_http_error(401, PackedStringArray(), "bad key")
	assert_eq(err["code"], BasePluginScript.ERR_AUTH_FAILED)
	assert_false(bool(err["retryable"]))

func test_make_http_error_500_is_retryable():
	var err: Dictionary = plugin._make_http_error(500, PackedStringArray(), "boom")
	assert_eq(err["code"], BasePluginScript.ERR_PROVIDER_ERROR)
	assert_true(bool(err["retryable"]))

func test_make_http_error_truncates_long_body():
	var big: String = ""
	for i in range(100):
		big += "0123456789"
	var err: Dictionary = plugin._make_http_error(400, PackedStringArray(), big)
	# Message should include a truncated body, not the whole 1000 chars.
	assert_true(str(err["message"]).length() < 700)
