# Tests for ClaudePlugin: metadata, param schema, pricing override,
# param validation, cost estimate, auth failure without api_key. No network.

extends GutTest

const ClaudePluginScript = preload("res://plugins/claude_plugin.gd")
const BasePluginScript = preload("res://scripts/base_plugin.gd")

var plugin

func before_each():
	plugin = ClaudePluginScript.new()
	add_child_autofree(plugin)

# ---------- Metadata / schema ----------

func test_metadata_shape():
	var m: Dictionary = plugin.get_metadata()
	assert_eq(m["plugin_name"], "claude")
	assert_eq(m["category"], "text")
	assert_true(m["capabilities"]["parallel"])
	assert_true(m["capabilities"]["cancel"])
	assert_eq(m["cost_unit"], "USD")

func test_param_schema_model_enum_includes_sonnet():
	var s: Dictionary = plugin.get_param_schema()
	assert_true(s["properties"]["model"]["enum"].has("claude-sonnet-4-6"))
	assert_true(s["properties"].has("max_tokens"))
	assert_true(s["properties"].has("system"))
	assert_true(s["properties"].has("temperature"))

func test_estimate_cost_positive():
	assert_gt(plugin.estimate_cost("write a haiku about bugs", {}), 0.0)

func test_estimate_cost_higher_with_larger_max_tokens():
	var low: float = plugin.estimate_cost("prompt", {"max_tokens": 100})
	var high: float = plugin.estimate_cost("prompt", {"max_tokens": 8000})
	assert_gt(high, low)

# ---------- Lifecycle ----------

func test_initialize_rejects_empty_key():
	assert_false(bool(plugin.initialize({})["success"]))

func test_initialize_accepts_pricing_override():
	var r: Dictionary = plugin.initialize({
		"api_key": "sk-ant-test",
		"pricing": {
			"claude-sonnet-4-6": {"input": 1.0, "output": 2.0}
		}
	})
	assert_true(bool(r["success"]))
	assert_eq(float(plugin.pricing["claude-sonnet-4-6"]["input"]), 1.0)
	assert_eq(float(plugin.pricing["claude-sonnet-4-6"]["output"]), 2.0)

func test_health_check_gate_on_key():
	assert_false(bool(plugin.health_check()["healthy"]))
	plugin.initialize({"api_key": "sk-ant-test"})
	assert_true(bool(plugin.health_check()["healthy"]))

# ---------- Param validation ----------

func test_generate_without_key_emits_auth_failed():
	watch_signals(plugin)
	var tid: String = plugin.generate("hi", {})
	assert_ne(tid, "")
	await wait_for_signal(plugin.task_failed, 1.0)
	var params = get_signal_parameters(plugin, "task_failed", 0)
	assert_eq(params[1]["code"], BasePluginScript.ERR_AUTH_FAILED)

func test_generate_empty_prompt_rejected():
	plugin.initialize({"api_key": "sk-ant-test"})
	watch_signals(plugin)
	plugin.generate("", {})
	await wait_for_signal(plugin.task_failed, 1.0)
	var params = get_signal_parameters(plugin, "task_failed", 0)
	assert_eq(params[1]["code"], BasePluginScript.ERR_INVALID_PARAMS)

func test_generate_bad_max_tokens_rejected():
	plugin.initialize({"api_key": "sk-ant-test"})
	watch_signals(plugin)
	plugin.generate("hi", {"max_tokens": 999999})
	await wait_for_signal(plugin.task_failed, 1.0)
	var params = get_signal_parameters(plugin, "task_failed", 0)
	assert_eq(params[1]["code"], BasePluginScript.ERR_INVALID_PARAMS)

func test_generate_bad_temperature_rejected():
	plugin.initialize({"api_key": "sk-ant-test"})
	watch_signals(plugin)
	plugin.generate("hi", {"temperature": 3.0})
	await wait_for_signal(plugin.task_failed, 1.0)
	var params = get_signal_parameters(plugin, "task_failed", 0)
	assert_eq(params[1]["code"], BasePluginScript.ERR_INVALID_PARAMS)

func test_generate_unknown_model_rejected():
	plugin.initialize({"api_key": "sk-ant-test"})
	watch_signals(plugin)
	plugin.generate("hi", {"model": "gpt-999-turbo-max"})
	await wait_for_signal(plugin.task_failed, 1.0)
	var params = get_signal_parameters(plugin, "task_failed", 0)
	assert_eq(params[1]["code"], BasePluginScript.ERR_INVALID_PARAMS)
