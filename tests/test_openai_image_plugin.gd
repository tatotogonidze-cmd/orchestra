# Tests for OpenAIImagePlugin: metadata, param schema, param validation,
# cost estimate, auth failure without api_key. No network calls — same
# shape as test_elevenlabs_plugin.gd.

extends GutTest

const OpenAIImagePluginScript = preload("res://plugins/openai_image_plugin.gd")
const BasePluginScript = preload("res://scripts/base_plugin.gd")

var plugin

func before_each():
	plugin = OpenAIImagePluginScript.new()
	add_child_autofree(plugin)

# ---------- Metadata / schema ----------

func test_metadata_shape():
	var m: Dictionary = plugin.get_metadata()
	assert_eq(m["plugin_name"], "openai_image")
	assert_eq(m["category"], "image")
	assert_true(m["supported_formats"].has("png"))
	assert_true(m["capabilities"]["parallel"])
	assert_true(m["capabilities"]["cancel"])

func test_param_schema_has_model_size_quality():
	var s: Dictionary = plugin.get_param_schema()
	for key in ["model", "size", "quality"]:
		assert_true(s["properties"].has(key), "expected param: %s" % key)
	# size + quality are enums.
	assert_true((s["properties"]["size"] as Dictionary).has("enum"),
		"size should declare an enum")
	assert_true((s["properties"]["quality"] as Dictionary).has("enum"),
		"quality should declare an enum")

func test_estimate_cost_is_per_image_constant():
	# Per-image billing — prompt length doesn't enter the bill.
	var short_cost: float = plugin.estimate_cost("hi", {})
	var long_cost: float = plugin.estimate_cost("a much longer prompt about dragons", {})
	assert_almost_eq(short_cost, long_cost, 1e-9,
		"OpenAI image bills per image, not per prompt char")
	assert_almost_eq(short_cost, plugin.per_image_cost_usd, 1e-9)


# ---------- Lifecycle ----------

func test_initialize_rejects_empty_key():
	var r: Dictionary = plugin.initialize({})
	assert_false(bool(r["success"]),
		"initialize without api_key should fail")

func test_initialize_accepts_key_and_custom_rate():
	var r: Dictionary = plugin.initialize({
		"api_key": "sk-test-abc",
		"per_image_cost_usd": 0.080,
	})
	assert_true(bool(r["success"]))
	assert_almost_eq(plugin.per_image_cost_usd, 0.080, 1e-9,
		"custom rate should override the default")

func test_health_check_gate_on_key():
	assert_false(bool(plugin.health_check()["healthy"]),
		"unconfigured plugin reports unhealthy")
	plugin.initialize({"api_key": "sk-test-abc"})
	assert_true(bool(plugin.health_check()["healthy"]),
		"after initialize the deferred-health-check returns healthy")


# ---------- Param validation ----------

func test_generate_without_key_emits_auth_failed():
	watch_signals(plugin)
	var tid: String = plugin.generate("a wizard", {})
	assert_ne(tid, "")
	await wait_for_signal(plugin.task_failed, 1.0)
	var params = get_signal_parameters(plugin, "task_failed", 0)
	assert_eq(params[1]["code"], BasePluginScript.ERR_AUTH_FAILED)

func test_generate_empty_prompt_is_invalid_params():
	plugin.initialize({"api_key": "sk-test-abc"})
	watch_signals(plugin)
	plugin.generate("", {})
	await wait_for_signal(plugin.task_failed, 1.0)
	var params = get_signal_parameters(plugin, "task_failed", 0)
	assert_eq(params[1]["code"], BasePluginScript.ERR_INVALID_PARAMS)

func test_generate_bad_size_rejected():
	plugin.initialize({"api_key": "sk-test-abc"})
	watch_signals(plugin)
	plugin.generate("hi", {"size": "999x999"})
	await wait_for_signal(plugin.task_failed, 1.0)
	var params = get_signal_parameters(plugin, "task_failed", 0)
	assert_eq(params[1]["code"], BasePluginScript.ERR_INVALID_PARAMS)

func test_generate_bad_quality_rejected():
	plugin.initialize({"api_key": "sk-test-abc"})
	watch_signals(plugin)
	plugin.generate("hi", {"quality": "ultra"})
	await wait_for_signal(plugin.task_failed, 1.0)
	var params = get_signal_parameters(plugin, "task_failed", 0)
	assert_eq(params[1]["code"], BasePluginScript.ERR_INVALID_PARAMS)

func test_generate_overlong_prompt_rejected():
	plugin.initialize({"api_key": "sk-test-abc"})
	watch_signals(plugin)
	# OpenAI's documented max is 4000; we mirror it in _validate_params.
	var huge_prompt: String = "x".repeat(4001)
	plugin.generate(huge_prompt, {})
	await wait_for_signal(plugin.task_failed, 1.0)
	var params = get_signal_parameters(plugin, "task_failed", 0)
	assert_eq(params[1]["code"], BasePluginScript.ERR_INVALID_PARAMS)


# ---------- Cancellation ----------

func test_cancel_returns_false_for_unknown_task():
	assert_false(plugin.cancel("nope:not-a-real-task"),
		"cancelling a task we never started should return false")

# ---------- Test connection probe ----------

func test_test_connection_without_key():
	var r: Dictionary = await plugin.test_connection()
	assert_false(bool(r["success"]),
		"test_connection should fail when api_key is unconfigured")
	assert_true("api_key" in str(r.get("error", "")),
		"error should mention api_key; got: %s" % str(r.get("error", "")))


# ---------- Plugin registry integration ----------

func test_plugin_registry_includes_openai_image():
	var entry: Dictionary = load("res://scripts/plugin_registry.gd").get_entry("openai_image")
	assert_false(entry.is_empty(),
		"plugin_registry should know about openai_image")
	assert_eq(str(entry["category"]), "image",
		"openai_image should be registered as an image plugin")
	assert_eq(str(entry["env_var"]), "OPENAI_API_KEY",
		"env var should be OPENAI_API_KEY")
