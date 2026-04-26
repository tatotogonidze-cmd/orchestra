# Integration-ish tests for parallel generation:
# - Two plugins in different categories (3d + audio) run concurrently and both complete.
# - parallel_generate_by_category filters correctly.
# - All active tasks are tracked while running and cleared when finished.

extends GutTest

const PluginManagerScript = preload("res://scripts/plugin_manager.gd")
const Mock3DPluginScript = preload("res://plugins/mock_3d_plugin.gd")
const MockAudioPluginScript = preload("res://plugins/mock_audio_plugin.gd")

var manager

func before_each():
	manager = PluginManagerScript.new()
	add_child_autofree(manager)

func _make_plugins() -> Dictionary:
	var p3 = Mock3DPluginScript.new()
	add_child_autofree(p3)
	var pa = MockAudioPluginScript.new()
	add_child_autofree(pa)
	# Disable retry-inducing behavior in audio for plain parallel test.
	pa.fail_first_request = false
	manager.register_plugin("mock_3d", p3)
	manager.register_plugin("mock_audio", pa)
	manager.enable_plugin("mock_3d")
	manager.enable_plugin("mock_audio")
	return {"p3": p3, "pa": pa}

# Wait for N plugin_task_completed emissions or until timeout.
# NOTE: the counter is wrapped in an Array because GDScript 2.0 lambdas
# capture ints by value — writes to a plain local int from inside the
# lambda would not be visible to this function.
func _wait_for_n_completions(n: int, timeout_s: float) -> int:
	var counter: Array = [0]
	var cb := func(_plugin_name, _task_id, _result): counter[0] += 1
	manager.plugin_task_completed.connect(cb)
	var deadline: int = Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while counter[0] < n and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	manager.plugin_task_completed.disconnect(cb)
	return counter[0]

func test_parallel_generate_both_complete():
	_make_plugins()
	var ids: Array = manager.parallel_generate(["mock_3d", "mock_audio"], "castle scene", {})
	assert_eq(ids.size(), 2)
	# Both tracked while running.
	var active: Array = manager.get_all_active_tasks()
	assert_true(ids[0] in active)
	assert_true(ids[1] in active)

	var completed: int = await _wait_for_n_completions(2, 5.0)
	assert_eq(completed, 2, "both tasks should complete within 5s")
	# Both cleared after completion.
	var active_after: Array = manager.get_all_active_tasks()
	assert_false(ids[0] in active_after)
	assert_false(ids[1] in active_after)

func test_parallel_generate_by_category_filters_correctly():
	_make_plugins()
	# Register an extra 3D plugin so "3d" category has 2 plugins, "audio" has 1.
	var p3b = Mock3DPluginScript.new()
	add_child_autofree(p3b)
	manager.register_plugin("mock_3d_b", p3b)
	manager.enable_plugin("mock_3d_b")

	var ids_3d: Array = manager.parallel_generate_by_category("3d", "dragon", {})
	assert_eq(ids_3d.size(), 2, "two 3D plugins expected")
	for tid in ids_3d:
		assert_true(tid.begins_with("mock_3d"), "expected 3d namespace, got %s" % tid)

	var ids_audio: Array = manager.parallel_generate_by_category("audio", "bg music", {})
	assert_eq(ids_audio.size(), 1)
	assert_true(ids_audio[0].begins_with("mock_audio"))

func test_parallel_generate_ids_are_unique_and_namespaced():
	_make_plugins()
	var ids: Array = manager.parallel_generate(["mock_3d", "mock_audio"], "p", {})
	assert_eq(ids.size(), 2)
	assert_ne(ids[0], ids[1], "parallel task ids must be unique")
	# Each must carry the :inner format.
	for tid in ids:
		assert_true(tid.find(":") > 0, "task_id must be namespaced: %s" % tid)
