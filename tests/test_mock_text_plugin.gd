# Tests for MockTextPlugin: metadata, param schema, echo body,
# RATE_LIMIT first-request, cancel, max_words clamp. Mirrors
# test_mock_audio / test_mock_image. No network.

extends GutTest

const MockTextPluginScript = preload("res://plugins/mock_text_plugin.gd")
const BasePluginScript = preload("res://scripts/base_plugin.gd")

var plugin

func before_each():
	plugin = MockTextPluginScript.new()
	add_child_autofree(plugin)
	plugin.initialize({})


# ---------- Metadata / schema ----------

func test_metadata_shape():
	var m: Dictionary = plugin.get_metadata()
	assert_eq(m["plugin_name"], "mock_text")
	assert_eq(m["category"], "text")
	assert_true(m["supported_formats"].has("plain"))
	assert_true(m["capabilities"]["parallel"])
	assert_true(m["capabilities"]["cancel"])

func test_param_schema_has_max_words():
	var s: Dictionary = plugin.get_param_schema()
	assert_true(s["properties"].has("max_words"),
		"param schema should declare max_words")


# ---------- Lifecycle ----------

func test_health_check_always_ok():
	assert_true(bool(plugin.health_check()["healthy"]))

func test_test_connection_is_deterministic():
	var r: Dictionary = await plugin.test_connection()
	assert_true(bool(r["success"]),
		"mock test_connection should always succeed")


# ---------- First-request RATE_LIMIT (drives PluginManager retry) ----------

func test_first_request_fails_with_rate_limit():
	watch_signals(plugin)
	plugin.generate("hello", {})
	await wait_for_signal(plugin.task_failed, 1.0)
	var params = get_signal_parameters(plugin, "task_failed", 0)
	assert_eq(params[1]["code"], BasePluginScript.ERR_RATE_LIMIT,
		"first request should fail RATE_LIMIT to drive retry coverage")
	assert_true(bool(params[1]["retryable"]),
		"the failure should be marked retryable")

func test_disabling_first_request_fail_succeeds_immediately():
	plugin.fail_first_request = false
	watch_signals(plugin)
	plugin.generate("hello", {})
	await wait_for_signal(plugin.task_completed, 2.0)
	var params = get_signal_parameters(plugin, "task_completed", 0)
	var result: Dictionary = params[1]
	assert_eq(str(result["asset_type"]), "text")
	assert_eq(str(result["format"]), "plain")


# ---------- Echo content ----------

func test_echo_contains_prompt_and_mock_prefix():
	plugin.fail_first_request = false
	watch_signals(plugin)
	plugin.generate("a prompt about pelicans", {})
	await wait_for_signal(plugin.task_completed, 2.0)
	var params = get_signal_parameters(plugin, "task_completed", 0)
	var body: String = str(params[1]["text"])
	assert_true(body.begins_with("[mock]"),
		"echo should be prefixed with [mock]; got: %s" % body)
	assert_true("pelicans" in body,
		"echo should preserve the original prompt; got: %s" % body)

func test_echo_is_deterministic_across_runs():
	# Same prompt → same echo. Useful for snapshot tests.
	plugin.fail_first_request = false
	watch_signals(plugin)
	plugin.generate("frosty pine forest", {})
	await wait_for_signal(plugin.task_completed, 2.0)
	var p1 = get_signal_parameters(plugin, "task_completed", 0)
	var first_body: String = str(p1[1]["text"])

	plugin = MockTextPluginScript.new()
	add_child_autofree(plugin)
	plugin.initialize({})
	plugin.fail_first_request = false
	watch_signals(plugin)
	plugin.generate("frosty pine forest", {})
	await wait_for_signal(plugin.task_completed, 2.0)
	var p2 = get_signal_parameters(plugin, "task_completed", 0)
	assert_eq(str(p2[1]["text"]), first_body,
		"same prompt should produce identical echo across runs")

func test_max_words_clamps_long_echoes():
	plugin.fail_first_request = false
	watch_signals(plugin)
	plugin.generate("one two three four five six seven", {"max_words": 3})
	await wait_for_signal(plugin.task_completed, 2.0)
	var params = get_signal_parameters(plugin, "task_completed", 0)
	var body: String = str(params[1]["text"])
	# "[mock] one two" → 3 words (the prefix is one word, then two
	# words from the prompt).
	var word_count: int = body.split(" ", false).size()
	assert_eq(word_count, 3,
		"max_words=3 should clamp to 3 total words; got %d in: %s" % [word_count, body])


# ---------- Param validation ----------

func test_empty_prompt_is_invalid():
	watch_signals(plugin)
	plugin.generate("", {})
	await wait_for_signal(plugin.task_failed, 1.0)
	var params = get_signal_parameters(plugin, "task_failed", 0)
	assert_eq(params[1]["code"], BasePluginScript.ERR_INVALID_PARAMS)

func test_max_words_out_of_range_rejected():
	watch_signals(plugin)
	plugin.generate("hi", {"max_words": -5})
	await wait_for_signal(plugin.task_failed, 1.0)
	var params = get_signal_parameters(plugin, "task_failed", 0)
	assert_eq(params[1]["code"], BasePluginScript.ERR_INVALID_PARAMS)


# ---------- Cancellation ----------

func test_cancel_unknown_task_returns_false():
	assert_false(plugin.cancel("nope:not-a-task"))

func test_cancel_running_task_emits_failure():
	plugin.fail_first_request = false
	watch_signals(plugin)
	var tid: String = plugin.generate("slow", {})
	# Cancel synchronously — task hasn't completed yet because of the
	# await timer in _run_mock_task.
	plugin.cancel(tid)
	await wait_for_signal(plugin.task_failed, 2.0)
	var params = get_signal_parameters(plugin, "task_failed", 0)
	assert_eq(params[1]["code"], BasePluginScript.ERR_CANCELLED)


# ---------- Cost ----------

func test_estimate_cost_is_constant():
	# Per-request flat cost; prompt length doesn't enter the bill.
	assert_almost_eq(plugin.estimate_cost("a", {}), 0.001, 1e-9)
	assert_almost_eq(plugin.estimate_cost("a much longer prompt", {}),
		0.001, 1e-9)
