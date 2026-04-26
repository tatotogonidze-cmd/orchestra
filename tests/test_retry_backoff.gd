# Tests for retry/backoff: RATE_LIMIT failure from MockAudioPlugin's first request
# must be retried, succeed, and preserve the ORIGINAL namespaced task_id in the
# final plugin_task_completed signal. Also verifies retry_scheduled fires and
# non-retryable errors don't retry.

extends GutTest

const PluginManagerScript = preload("res://scripts/plugin_manager.gd")
const MockAudioPluginScript = preload("res://plugins/mock_audio_plugin.gd")
const BasePluginScript = preload("res://scripts/base_plugin.gd")

var manager
var audio

func before_each():
	manager = PluginManagerScript.new()
	add_child_autofree(manager)
	# Use a short backoff so the test runs fast.
	manager.retry_config = {
		"max_retries": 3,
		"base_delay_ms": 20,
		"max_delay_ms": 200,
		"backoff_multiplier": 2.0,
	}
	audio = MockAudioPluginScript.new()
	add_child_autofree(audio)
	audio.fail_first_request = true
	manager.register_plugin("mock_audio", audio)
	manager.enable_plugin("mock_audio")

# ---------- Happy path: fail then succeed ----------

func test_rate_limit_retry_eventually_succeeds():
	watch_signals(manager)
	var original_tid: String = manager.generate("mock_audio", "ambient drone", {"duration": 10})
	assert_true(original_tid.begins_with("mock_audio:"))

	# Wait for final completion (goes through retry first).
	await wait_for_signal(manager.plugin_task_completed, 5.0)
	assert_signal_emitted(manager, "plugin_task_completed")

	# retry_scheduled must have fired at least once with the ORIGINAL namespaced id.
	assert_signal_emitted(manager, "retry_scheduled")
	var retry_params = get_signal_parameters(manager, "retry_scheduled", 0)
	assert_not_null(retry_params, "expected a retry_scheduled emission")
	assert_eq(retry_params[0], original_tid, "retry_scheduled must carry ORIGINAL task_id")
	assert_eq(int(retry_params[1]), 1, "first retry should be attempt 1")
	assert_true(int(retry_params[2]) >= 20, "delay must respect retry_after_ms/base")

	# The completion's task_id must equal the original (alias preserves identity).
	var comp_params = get_signal_parameters(manager, "plugin_task_completed", 0)
	assert_eq(comp_params[1], original_tid,
		"completed task_id must equal original across retries (got %s)" % str(comp_params[1]))
	assert_eq(comp_params[0], "mock_audio")
	assert_true(comp_params[2] is Dictionary)

func test_first_failure_is_not_surfaced_when_retry_succeeds():
	watch_signals(manager)
	manager.generate("mock_audio", "p", {"duration": 5})
	await wait_for_signal(manager.plugin_task_completed, 5.0)
	# The first failure WAS retryable and retry succeeded, so no plugin_task_failed
	# should have surfaced to callers.
	assert_signal_not_emitted(manager, "plugin_task_failed")

# ---------- Retry budget exhausted ----------

# Force the plugin to keep failing by making every request the "first" one:
# set fail_first_request = true and reset _request_count on each retry.
# Simpler approach: set max_retries = 0 so a single retryable failure surfaces
# as plugin_task_failed.
func test_retry_exhaustion_surfaces_failure():
	manager.retry_config["max_retries"] = 0
	watch_signals(manager)
	var tid: String = manager.generate("mock_audio", "p", {"duration": 5})
	await wait_for_signal(manager.plugin_task_failed, 5.0)
	assert_signal_emitted(manager, "plugin_task_failed")
	var fail_params = get_signal_parameters(manager, "plugin_task_failed", 0)
	assert_eq(fail_params[1], tid)
	assert_eq(fail_params[2]["code"], BasePluginScript.ERR_RATE_LIMIT)

# ---------- Non-retryable errors don't retry ----------

# We reuse mock_audio but flip to fail_first_request = false and instead
# force a non-retryable error by cancelling immediately.
func test_non_retryable_cancel_does_not_retry():
	audio.fail_first_request = false
	watch_signals(manager)
	var tid: String = manager.generate("mock_audio", "p", {"duration": 5})
	var ok: bool = manager.cancel(tid)
	assert_true(ok)
	await wait_for_signal(manager.plugin_task_failed, 5.0)
	assert_signal_emitted(manager, "plugin_task_failed")
	# retry_scheduled must not have fired for a CANCELLED (non-retryable) error.
	assert_signal_not_emitted(manager, "retry_scheduled")
