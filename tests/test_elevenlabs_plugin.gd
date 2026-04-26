# Tests for ElevenLabsPlugin: metadata, param schema, param validation,
# cost estimate, auth failure without api_key. No network calls.

extends GutTest

const ElevenLabsPluginScript = preload("res://plugins/elevenlabs_plugin.gd")
const BasePluginScript = preload("res://scripts/base_plugin.gd")

var plugin

func before_each():
	plugin = ElevenLabsPluginScript.new()
	add_child_autofree(plugin)

# ---------- Metadata / schema ----------

func test_metadata_shape():
	var m: Dictionary = plugin.get_metadata()
	assert_eq(m["plugin_name"], "elevenlabs")
	assert_eq(m["category"], "audio")
	assert_true(m["supported_formats"].has("mp3"))
	assert_true(m["capabilities"]["parallel"])
	assert_true(m["capabilities"]["cancel"])

func test_param_schema_has_voice_and_settings():
	var s: Dictionary = plugin.get_param_schema()
	for key in ["voice_id", "model_id", "stability", "similarity_boost", "format"]:
		assert_true(s["properties"].has(key), "expected param: %s" % key)

func test_estimate_cost_scales_with_length():
	var short_cost: float = plugin.estimate_cost("hi", {})
	var long_cost: float = plugin.estimate_cost("hello world, how are you today?", {})
	assert_gt(long_cost, short_cost)
	# A plain concatenation of a single char prompt should cost ~ per_char_cost_usd.
	assert_almost_eq(plugin.estimate_cost("a", {}), plugin.per_char_cost_usd, 1e-9)

# ---------- Lifecycle ----------

func test_initialize_rejects_empty_key():
	var r: Dictionary = plugin.initialize({})
	assert_false(bool(r["success"]))

func test_initialize_accepts_key_and_custom_rate():
	var r: Dictionary = plugin.initialize({
		"api_key": "xi-test-123",
		"per_char_cost_usd": 0.001,
	})
	assert_true(bool(r["success"]))
	assert_almost_eq(plugin.per_char_cost_usd, 0.001, 1e-9)

func test_health_check_gate_on_key():
	assert_false(bool(plugin.health_check()["healthy"]))
	plugin.initialize({"api_key": "xi-test-123"})
	assert_true(bool(plugin.health_check()["healthy"]))

# ---------- Param validation ----------

func test_generate_without_key_emits_auth_failed():
	watch_signals(plugin)
	var tid: String = plugin.generate("hello", {})
	assert_ne(tid, "")
	await wait_for_signal(plugin.task_failed, 1.0)
	var params = get_signal_parameters(plugin, "task_failed", 0)
	assert_eq(params[1]["code"], BasePluginScript.ERR_AUTH_FAILED)

func test_generate_empty_prompt_is_invalid_params():
	plugin.initialize({"api_key": "xi-test-123"})
	watch_signals(plugin)
	plugin.generate("", {})
	await wait_for_signal(plugin.task_failed, 1.0)
	var params = get_signal_parameters(plugin, "task_failed", 0)
	assert_eq(params[1]["code"], BasePluginScript.ERR_INVALID_PARAMS)

func test_generate_out_of_range_stability_rejected():
	plugin.initialize({"api_key": "xi-test-123"})
	watch_signals(plugin)
	plugin.generate("hi", {"stability": 1.5})
	await wait_for_signal(plugin.task_failed, 1.0)
	var params = get_signal_parameters(plugin, "task_failed", 0)
	assert_eq(params[1]["code"], BasePluginScript.ERR_INVALID_PARAMS)

func test_generate_bad_format_rejected():
	plugin.initialize({"api_key": "xi-test-123"})
	watch_signals(plugin)
	plugin.generate("hi", {"format": "ogg"})
	await wait_for_signal(plugin.task_failed, 1.0)
	var params = get_signal_parameters(plugin, "task_failed", 0)
	assert_eq(params[1]["code"], BasePluginScript.ERR_INVALID_PARAMS)
