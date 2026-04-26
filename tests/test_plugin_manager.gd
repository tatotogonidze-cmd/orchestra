# Tests for PluginManager: registration, enable/health_check, generate + signal
# re-emission (including the critical argument-order check), cancel,
# parallel_generate, disable cancels in-flight, shutdown clears state.

extends GutTest

const PluginManagerScript = preload("res://scripts/plugin_manager.gd")
const Mock3DPluginScript = preload("res://plugins/mock_3d_plugin.gd")

var manager
var plugin

func before_each():
	manager = PluginManagerScript.new()
	add_child_autofree(manager)
	plugin = Mock3DPluginScript.new()
	add_child_autofree(plugin)

# ---------- Registration ----------

func test_register_success():
	var r = manager.register_plugin("mock_3d", plugin)
	assert_true(bool(r["success"]), "register should succeed")
	assert_true(manager.is_plugin_registered("mock_3d"))

func test_register_duplicate_fails():
	manager.register_plugin("mock_3d", plugin)
	var other = Mock3DPluginScript.new()
	add_child_autofree(other)
	var r = manager.register_plugin("mock_3d", other)
	assert_false(bool(r["success"]))
	assert_true(str(r["error"]).find("already registered") >= 0)

func test_register_empty_name_fails():
	var r = manager.register_plugin("", plugin)
	assert_false(bool(r["success"]))

# ---------- Enable / health_check ----------

func test_enable_passes_health_check():
	manager.register_plugin("mock_3d", plugin)
	var r = manager.enable_plugin("mock_3d")
	assert_true(bool(r["success"]))
	assert_true(manager.is_plugin_active("mock_3d"))

func test_enable_unregistered_fails():
	var r = manager.enable_plugin("ghost")
	assert_false(bool(r["success"]))

# ---------- Generate + signal re-emission ----------

# THE CRITICAL BUG CHECK: namespaced task_id and argument order on progress signal.
func test_generate_and_progress_signal_argument_order():
	manager.register_plugin("mock_3d", plugin)
	manager.enable_plugin("mock_3d")
	watch_signals(manager)
	var tid = manager.generate("mock_3d", "a dragon", {"style": "lowpoly"})
	assert_true(tid.begins_with("mock_3d:"), "task_id must be namespaced: got %s" % tid)
	# Wait for at least one progress, then completion.
	await wait_for_signal(manager.plugin_task_completed, 3.0)
	assert_signal_emitted(manager, "plugin_task_progress")
	# Inspect the first progress emission arguments — plugin_name must be arg[0], not elsewhere.
	var params = get_signal_parameters(manager, "plugin_task_progress", 0)
	assert_not_null(params, "expected at least one plugin_task_progress emission")
	assert_eq(params[0], "mock_3d", "arg[0] must be plugin_name")
	assert_eq(params[1], tid,        "arg[1] must be the namespaced task_id")
	assert_true(params[2] is float,  "arg[2] must be progress (float)")
	assert_true(params[3] is String, "arg[3] must be message (String)")

func test_generate_emits_completed_with_result():
	manager.register_plugin("mock_3d", plugin)
	manager.enable_plugin("mock_3d")
	watch_signals(manager)
	var tid = manager.generate("mock_3d", "a castle", {"style": "realistic"})
	await wait_for_signal(manager.plugin_task_completed, 3.0)
	assert_signal_emitted(manager, "plugin_task_completed")
	var params = get_signal_parameters(manager, "plugin_task_completed", 0)
	assert_eq(params[0], "mock_3d")
	assert_eq(params[1], tid)
	assert_true(params[2] is Dictionary)
	assert_eq(params[2]["asset_type"], "3d")
	assert_eq(params[2]["style"], "realistic")

func test_cost_incurred_emitted_on_nonzero_cost():
	manager.register_plugin("mock_3d", plugin)
	manager.enable_plugin("mock_3d")
	watch_signals(manager)
	manager.generate("mock_3d", "prompt", {})
	await wait_for_signal(manager.plugin_task_completed, 3.0)
	assert_signal_emitted(manager, "cost_incurred")
	var params = get_signal_parameters(manager, "cost_incurred", 0)
	assert_eq(params[0], "mock_3d")
	assert_true(float(params[1]) > 0.0)
	assert_eq(params[2], "USD")

# ---------- Active task registry ----------

func test_active_task_tracked_then_removed_on_completion():
	manager.register_plugin("mock_3d", plugin)
	manager.enable_plugin("mock_3d")
	var tid = manager.generate("mock_3d", "p", {})
	assert_true(tid in manager.get_all_active_tasks(), "task should be tracked while running")
	await wait_for_signal(manager.plugin_task_completed, 3.0)
	assert_false(tid in manager.get_all_active_tasks(), "task should be removed after completion")

# ---------- Cancel ----------

func test_cancel_removes_task():
	manager.register_plugin("mock_3d", plugin)
	manager.enable_plugin("mock_3d")
	watch_signals(manager)
	var tid = manager.generate("mock_3d", "p", {})
	var ok = manager.cancel(tid)
	assert_true(ok)
	await wait_for_signal(manager.plugin_task_failed, 3.0)
	assert_signal_emitted(manager, "plugin_task_failed")
	var params = get_signal_parameters(manager, "plugin_task_failed", 0)
	assert_eq(params[2]["code"], "CANCELLED")

func test_cancel_bad_namespace_returns_false():
	assert_false(manager.cancel("no_colon_here"))
	assert_false(manager.cancel(""))

# ---------- Disable / shutdown ----------

func test_disable_cancels_in_flight():
	manager.register_plugin("mock_3d", plugin)
	manager.enable_plugin("mock_3d")
	watch_signals(manager)
	manager.generate("mock_3d", "p", {})
	manager.disable_plugin("mock_3d")
	await wait_for_signal(manager.plugin_task_failed, 3.0)
	assert_signal_emitted(manager, "plugin_task_failed")
	assert_false(manager.is_plugin_active("mock_3d"))

func test_shutdown_clears_state():
	manager.register_plugin("mock_3d", plugin)
	manager.enable_plugin("mock_3d")
	manager.shutdown()
	assert_false(manager.is_plugin_registered("mock_3d"))
	assert_false(manager.is_plugin_active("mock_3d"))
	assert_eq(manager.get_all_active_tasks().size(), 0)

# ---------- Parallel ----------

func test_parallel_generate_returns_multiple_ids():
	var p2 = Mock3DPluginScript.new()
	add_child_autofree(p2)
	manager.register_plugin("mock_3d_a", plugin)
	manager.register_plugin("mock_3d_b", p2)
	manager.enable_plugin("mock_3d_a")
	manager.enable_plugin("mock_3d_b")
	var ids = manager.parallel_generate(["mock_3d_a", "mock_3d_b"], "p", {})
	assert_eq(ids.size(), 2)
	assert_true(ids[0].begins_with("mock_3d_a:"))
	assert_true(ids[1].begins_with("mock_3d_b:"))

func test_parallel_generate_by_category():
	var p2 = Mock3DPluginScript.new()
	add_child_autofree(p2)
	manager.register_plugin("mock_3d_a", plugin)
	manager.register_plugin("mock_3d_b", p2)
	manager.enable_plugin("mock_3d_a")
	manager.enable_plugin("mock_3d_b")
	var ids = manager.parallel_generate_by_category("3d", "p", {})
	assert_eq(ids.size(), 2)
