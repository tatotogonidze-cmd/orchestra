# Tests for BasePlugin contract: constants exist, signal declarations present,
# helper methods produce correctly-shaped outputs.

extends GutTest

const BasePluginScript = preload("res://scripts/base_plugin.gd")

func test_error_code_constants_exist():
	assert_eq(BasePluginScript.ERR_RATE_LIMIT, "RATE_LIMIT")
	assert_eq(BasePluginScript.ERR_AUTH_FAILED, "AUTH_FAILED")
	assert_eq(BasePluginScript.ERR_NETWORK, "NETWORK")
	assert_eq(BasePluginScript.ERR_INVALID_PARAMS, "INVALID_PARAMS")
	assert_eq(BasePluginScript.ERR_PROVIDER_ERROR, "PROVIDER_ERROR")
	assert_eq(BasePluginScript.ERR_TIMEOUT, "TIMEOUT")
	assert_eq(BasePluginScript.ERR_CANCELLED, "CANCELLED")
	assert_eq(BasePluginScript.ERR_INSUFFICIENT_BUDGET, "INSUFFICIENT_BUDGET")
	assert_eq(BasePluginScript.ERR_UNKNOWN, "UNKNOWN")

func test_signals_declared():
	var plugin = BasePluginScript.new()
	add_child_autofree(plugin)
	assert_true(plugin.has_signal("task_progress"))
	assert_true(plugin.has_signal("task_completed"))
	assert_true(plugin.has_signal("task_failed"))
	assert_true(plugin.has_signal("task_stream_chunk"))

func test_default_metadata_shape():
	var plugin = BasePluginScript.new()
	add_child_autofree(plugin)
	var meta = plugin.get_metadata()
	assert_true(meta.has("plugin_name"))
	assert_true(meta.has("version"))
	assert_true(meta.has("category"))
	assert_true(meta.has("capabilities"))
	assert_true(meta.has("cost_unit"))
	assert_true(meta.has("limits"))
	assert_true(meta["capabilities"].has("parallel"))
	assert_true(meta["capabilities"].has("streaming"))
	assert_true(meta["capabilities"].has("cancel"))

func test_make_error_helper_shape():
	var plugin = BasePluginScript.new()
	add_child_autofree(plugin)
	var err = plugin._make_error("RATE_LIMIT", "slow down", true, 500)
	assert_eq(err["code"], "RATE_LIMIT")
	assert_eq(err["message"], "slow down")
	assert_true(bool(err["retryable"]))
	assert_eq(int(err["retry_after_ms"]), 500)

func test_make_error_omits_optional_when_absent():
	var plugin = BasePluginScript.new()
	add_child_autofree(plugin)
	var err = plugin._make_error("NETWORK", "offline")
	assert_false(err.has("retry_after_ms"))
	assert_false(err.has("raw"))

func test_unimplemented_generate_returns_empty():
	var plugin = BasePluginScript.new()
	add_child_autofree(plugin)
	# BasePlugin.generate is abstract — returns "".
	var tid = plugin.generate("anything", {})
	assert_eq(tid, "")

func test_default_param_schema_shape():
	var plugin = BasePluginScript.new()
	add_child_autofree(plugin)
	var schema = plugin.get_param_schema()
	assert_eq(schema["type"], "object")
	assert_true(schema.has("properties"))
	assert_true(schema.has("required"))
