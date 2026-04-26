# Tests for TripoPlugin: metadata, param schema, param validation,
# auth failure without api_key. NO network calls are made.

extends GutTest

const TripoPluginScript = preload("res://plugins/tripo_plugin.gd")
const BasePluginScript = preload("res://scripts/base_plugin.gd")

var plugin

func before_each():
	plugin = TripoPluginScript.new()
	add_child_autofree(plugin)

# ---------- Metadata / schema ----------

func test_metadata_shape():
	var m: Dictionary = plugin.get_metadata()
	assert_eq(m["plugin_name"], "tripo")
	assert_eq(m["category"], "3d")
	assert_true(m["capabilities"]["parallel"])
	assert_true(m["capabilities"]["cancel"])
	assert_eq(m["cost_unit"], "USD")
	assert_true(m["supported_formats"].has("glb"))

func test_param_schema_has_style_and_texture():
	var s: Dictionary = plugin.get_param_schema()
	assert_eq(s["type"], "object")
	assert_true(s["properties"].has("style"))
	assert_true(s["properties"].has("texture"))
	assert_true(s["properties"].has("pbr"))
	# "style" must be an enum with the known buckets.
	assert_true(s["properties"]["style"]["enum"].has("realistic"))
	assert_true(s["properties"]["style"]["enum"].has("lowpoly"))

func test_estimate_cost_non_negative():
	assert_gte(plugin.estimate_cost("a dragon", {}), 0.0)

# ---------- Lifecycle ----------

func test_initialize_rejects_empty_key():
	var r: Dictionary = plugin.initialize({})
	assert_false(bool(r["success"]))

func test_initialize_accepts_key():
	var r: Dictionary = plugin.initialize({"api_key": "tripo_test_123"})
	assert_true(bool(r["success"]))

func test_health_check_unhealthy_without_key():
	var h: Dictionary = plugin.health_check()
	assert_false(bool(h["healthy"]))

func test_health_check_healthy_with_key():
	plugin.initialize({"api_key": "tripo_test_123"})
	var h: Dictionary = plugin.health_check()
	assert_true(bool(h["healthy"]))

# ---------- Param validation (no network) ----------

func test_generate_without_api_key_emits_auth_failed():
	watch_signals(plugin)
	var tid: String = plugin.generate("a dragon", {"style": "lowpoly"})
	assert_ne(tid, "")
	await wait_for_signal(plugin.task_failed, 1.0)
	var params = get_signal_parameters(plugin, "task_failed", 0)
	assert_eq(params[0], tid)
	assert_eq(params[1]["code"], BasePluginScript.ERR_AUTH_FAILED)
	assert_false(bool(params[1]["retryable"]))

func test_generate_empty_prompt_is_invalid_params():
	plugin.initialize({"api_key": "tripo_test_123"})
	watch_signals(plugin)
	var tid: String = plugin.generate("", {})
	assert_ne(tid, "")
	await wait_for_signal(plugin.task_failed, 1.0)
	var params = get_signal_parameters(plugin, "task_failed", 0)
	assert_eq(params[1]["code"], BasePluginScript.ERR_INVALID_PARAMS)
	assert_false(bool(params[1]["retryable"]))

func test_generate_bad_style_is_invalid_params():
	plugin.initialize({"api_key": "tripo_test_123"})
	watch_signals(plugin)
	plugin.generate("a dragon", {"style": "unknown_style"})
	await wait_for_signal(plugin.task_failed, 1.0)
	var params = get_signal_parameters(plugin, "task_failed", 0)
	assert_eq(params[1]["code"], BasePluginScript.ERR_INVALID_PARAMS)

func test_generate_very_long_prompt_rejected():
	plugin.initialize({"api_key": "tripo_test_123"})
	watch_signals(plugin)
	var long_prompt: String = "a ".repeat(400)  # ~800 chars > 500 limit
	plugin.generate(long_prompt, {})
	await wait_for_signal(plugin.task_failed, 1.0)
	var params = get_signal_parameters(plugin, "task_failed", 0)
	assert_eq(params[1]["code"], BasePluginScript.ERR_INVALID_PARAMS)
