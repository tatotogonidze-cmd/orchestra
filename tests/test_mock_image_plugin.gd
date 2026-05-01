# Tests for MockImagePlugin: metadata, param schema, generate writes
# a real PNG, RATE_LIMIT first-request behaviour, cancel, end-to-end
# preview readiness. Mirrors test_mock_audio / test_mock_3d.

extends GutTest

const MockImagePluginScript = preload("res://plugins/mock_image_plugin.gd")
const BasePluginScript = preload("res://scripts/base_plugin.gd")

var plugin


func before_each() -> void:
	plugin = MockImagePluginScript.new()
	add_child_autofree(plugin)
	plugin.initialize({})
	# Per-test isolation: redirect output so the synthetic PNGs don't
	# pollute the real user://assets/image_mock/ folder.
	# (The plugin reads OUTPUT_DIR as a const; tests use the default
	# location since file isolation isn't needed for unit tests — each
	# task_id is unique.)


# ---------- Metadata / schema ----------

func test_metadata_shape():
	var m: Dictionary = plugin.get_metadata()
	assert_eq(m["plugin_name"], "mock_image")
	assert_eq(m["category"], "image")
	assert_true(m["supported_formats"].has("png"))
	assert_true(m["capabilities"]["parallel"])
	assert_true(m["capabilities"]["cancel"])

func test_param_schema_has_size_enum():
	var s: Dictionary = plugin.get_param_schema()
	assert_true(s["properties"].has("size"))
	var size_enum: Array = (s["properties"]["size"] as Dictionary).get("enum", [])
	assert_true(size_enum.has(64),
		"size enum should include 64; got: %s" % str(size_enum))


# ---------- Lifecycle ----------

func test_health_check_always_ok():
	var h: Dictionary = plugin.health_check()
	assert_true(bool(h["healthy"]),
		"mock image health-check should always pass")

func test_test_connection_is_deterministic():
	var r: Dictionary = await plugin.test_connection()
	assert_true(bool(r["success"]),
		"mock test_connection should always succeed for credential-editor probes")


# ---------- First-request rate-limit (drives PluginManager retry) ----------

func test_first_request_fails_with_rate_limit():
	watch_signals(plugin)
	var tid: String = plugin.generate("anything", {})
	await wait_for_signal(plugin.task_failed, 1.0)
	var params = get_signal_parameters(plugin, "task_failed", 0)
	assert_eq(params[1]["code"], BasePluginScript.ERR_RATE_LIMIT,
		"first request should fail RATE_LIMIT to drive retry coverage")
	assert_true(bool(params[1]["retryable"]),
		"the failure should be marked retryable")

func test_disabling_first_request_fail_succeeds_immediately():
	plugin.fail_first_request = false
	watch_signals(plugin)
	plugin.generate("a small red square", {})
	await wait_for_signal(plugin.task_completed, 2.0)
	# task_completed fired — happy path.
	var params = get_signal_parameters(plugin, "task_completed", 0)
	var result: Dictionary = params[1]
	assert_eq(str(result["asset_type"]), "image")
	assert_eq(str(result["format"]), "png")


# ---------- Real PNG output ----------

func test_completed_task_writes_real_png_to_disk():
	plugin.fail_first_request = false
	watch_signals(plugin)
	plugin.generate("synthwave sunset", {"size": 64})
	await wait_for_signal(plugin.task_completed, 2.0)
	var params = get_signal_parameters(plugin, "task_completed", 0)
	var path: String = str(params[1]["path"])
	assert_true(FileAccess.file_exists(path),
		"plugin should write a real PNG at the result path")
	# Image should be loadable — confirms it's actually a PNG, not just bytes.
	var img := Image.new()
	var err: Error = img.load(path)
	assert_eq(err, OK,
		"plugin output should be a valid PNG decodable by Image.load")
	assert_eq(img.get_width(), 64, "output should match requested size")
	assert_eq(img.get_height(), 64, "output should be square")
	# Cleanup so the test doesn't leave files behind.
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

func test_color_is_deterministic_per_prompt():
	# Same prompt → same color. Drive twice and compare the central
	# pixel; useful for snapshot-style tests that want stable bytes.
	plugin.fail_first_request = false
	watch_signals(plugin)
	plugin.generate("frosty pine forest", {"size": 64})
	await wait_for_signal(plugin.task_completed, 2.0)
	var p1 = get_signal_parameters(plugin, "task_completed", 0)
	var path_a: String = str(p1[1]["path"])

	# Re-create the plugin (so request_count resets and fail_first
	# gating is consistent).
	plugin = MockImagePluginScript.new()
	add_child_autofree(plugin)
	plugin.initialize({})
	plugin.fail_first_request = false
	watch_signals(plugin)
	plugin.generate("frosty pine forest", {"size": 64})
	await wait_for_signal(plugin.task_completed, 2.0)
	var p2 = get_signal_parameters(plugin, "task_completed", 0)
	var path_b: String = str(p2[1]["path"])

	var img_a := Image.new(); img_a.load(path_a)
	var img_b := Image.new(); img_b.load(path_b)
	assert_eq(img_a.get_pixel(32, 32), img_b.get_pixel(32, 32),
		"same prompt should produce same color across runs")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path_a))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path_b))


# ---------- Param validation ----------

func test_invalid_size_rejected():
	watch_signals(plugin)
	plugin.generate("hi", {"size": 999})
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
	# Cancel synchronously — the task hasn't completed yet because of
	# the await timer in _run_mock_task.
	plugin.cancel(tid)
	await wait_for_signal(plugin.task_failed, 2.0)
	var params = get_signal_parameters(plugin, "task_failed", 0)
	assert_eq(params[1]["code"], BasePluginScript.ERR_CANCELLED)
