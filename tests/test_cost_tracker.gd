# Unit tests for CostTracker. Pure logic — we drive the tracker via
# `record_cost` directly rather than through the EventBus, which keeps
# the test surface focused on the accumulation / threshold logic.
# (Integration with EventBus.cost_incurred is exercised in
# test_orchestrator.gd, where a real plugin reports cost end-to-end.)

extends GutTest

const CostTrackerScript = preload("res://scripts/cost_tracker.gd")

var t: Node


func before_each() -> void:
	t = CostTrackerScript.new()
	add_child_autofree(t)


# ---------- Initial state ----------

func test_initial_state_is_zero():
	assert_eq(t.get_total(), 0.0)
	assert_eq(t.get_session_limit(), 0.0)
	assert_eq(t.get_remaining(), 0.0,
		"with no limit, remaining is 0 by convention")
	assert_eq(t.get_task_count(), 0)
	assert_eq(t.get_breakdown().size(), 0)
	assert_eq(t.get_average_cost_per_task(), 0.0)


# ---------- Accumulation ----------

func test_record_cost_updates_total_and_breakdown():
	watch_signals(t)
	t.record_cost("claude", 0.0125)
	assert_almost_eq(t.get_total(), 0.0125, 0.0001)
	assert_eq(t.get_task_count(), 1)
	# claude is registered under category "text".
	var by_cat: Dictionary = t.get_breakdown()
	assert_almost_eq(float(by_cat.get("text", 0.0)), 0.0125, 0.0001,
		"claude cost should land in the 'text' bucket")
	assert_signal_emitted(t, "cost_updated")

func test_record_cost_zero_is_ignored():
	watch_signals(t)
	t.record_cost("claude", 0.0)
	assert_eq(t.get_total(), 0.0)
	assert_eq(t.get_task_count(), 0)
	assert_signal_not_emitted(t, "cost_updated",
		"zero-cost tasks should not trigger UI repaints")

func test_record_cost_negative_is_ignored():
	# Negative costs are nonsense in our model — silently drop.
	t.record_cost("claude", -1.0)
	assert_eq(t.get_total(), 0.0)
	assert_eq(t.get_task_count(), 0)

func test_unknown_plugin_lands_in_unknown_bucket():
	t.record_cost("not-in-registry", 1.5)
	assert_almost_eq(t.get_total(), 1.5, 0.0001)
	var by_cat: Dictionary = t.get_breakdown()
	assert_almost_eq(float(by_cat.get("unknown", 0.0)), 1.5, 0.0001)

func test_breakdown_sums_match_total_across_categories():
	t.record_cost("claude", 0.10)       # text
	t.record_cost("elevenlabs", 0.05)   # audio
	t.record_cost("tripo", 0.30)        # 3d
	t.record_cost("claude", 0.05)       # text again
	assert_almost_eq(t.get_total(), 0.50, 0.0001)
	var by_cat: Dictionary = t.get_breakdown()
	assert_almost_eq(float(by_cat["text"]), 0.15, 0.0001)
	assert_almost_eq(float(by_cat["audio"]), 0.05, 0.0001)
	assert_almost_eq(float(by_cat["3d"]), 0.30, 0.0001)
	assert_eq(t.get_task_count(), 4)


# ---------- Limits + warnings ----------

func test_no_signals_when_limit_unset():
	watch_signals(t)
	t.record_cost("claude", 100.0)
	# No limit, so the threshold logic should be a no-op.
	assert_signal_not_emitted(t, "budget_warning_reached")
	assert_signal_not_emitted(t, "budget_limit_reached")

func test_warning_fires_at_threshold():
	t.set_session_limit(10.0)
	# Default threshold 0.8 → fires at $8.00
	watch_signals(t)
	t.record_cost("claude", 7.99)
	assert_signal_not_emitted(t, "budget_warning_reached",
		"should not fire below threshold")
	t.record_cost("claude", 0.02)  # total now 8.01
	assert_signal_emitted(t, "budget_warning_reached",
		"warning should fire when crossing the threshold")
	# Limit not yet reached.
	assert_signal_not_emitted(t, "budget_limit_reached")

func test_warning_fires_only_once_until_reset():
	# GUT's watch_signals doesn't reset its emission counter between
	# calls in the same test, so we use assert_signal_emit_count to
	# verify the latch directly: one crossing of the threshold should
	# produce exactly one warning emission, not two.
	t.set_session_limit(10.0)
	watch_signals(t)
	t.record_cost("claude", 9.0)   # crosses 80% → warning fires
	t.record_cost("claude", 0.5)   # still below limit, latch should hold
	assert_signal_emit_count(t, "budget_warning_reached", 1,
		"warning should be latched after first crossing — one emission, not two")

func test_limit_fires_at_or_over_session_limit():
	t.set_session_limit(5.0)
	watch_signals(t)
	t.record_cost("claude", 5.0)
	assert_signal_emitted(t, "budget_limit_reached")

func test_limit_signal_carries_spent_and_limit():
	t.set_session_limit(5.0)
	watch_signals(t)
	t.record_cost("claude", 6.0)
	var params: Array = get_signal_parameters(t, "budget_limit_reached")
	assert_almost_eq(float(params[0]), 6.0, 0.0001, "spent")
	assert_almost_eq(float(params[1]), 5.0, 0.0001, "limit")

func test_set_warning_threshold_zero_disables_warning():
	t.set_warning_threshold(0.0)
	t.set_session_limit(10.0)
	watch_signals(t)
	t.record_cost("claude", 10.0)  # would normally fire warning + limit
	assert_signal_not_emitted(t, "budget_warning_reached",
		"warning threshold of 0 disables the warning signal")
	assert_signal_emitted(t, "budget_limit_reached",
		"limit signal should still fire — threshold gate is independent")


# ---------- Limit changes ----------

func test_raising_limit_rearms_latches():
	t.set_session_limit(10.0)
	t.record_cost("claude", 9.0)  # warning latched
	# Bump the limit. The user has more budget now; we should be willing
	# to warn them again as they approach the new threshold.
	t.set_session_limit(100.0)
	watch_signals(t)
	t.record_cost("claude", 75.0)   # total $84, > 80% of $100 → re-warn
	assert_signal_emitted(t, "budget_warning_reached")

func test_setting_limit_emits_cost_updated_for_repaint():
	# Even when the totals don't change, the UI should repaint because
	# "remaining" is recomputed against the new limit.
	watch_signals(t)
	t.set_session_limit(50.0)
	assert_signal_emitted(t, "cost_updated",
		"set_session_limit should trigger a UI repaint")

func test_remaining_after_limit_set():
	t.set_session_limit(10.0)
	t.record_cost("claude", 3.0)
	assert_almost_eq(t.get_remaining(), 7.0, 0.0001)
	t.record_cost("claude", 8.0)  # over budget
	assert_almost_eq(t.get_remaining(), -1.0, 0.0001,
		"remaining can go negative; UI surfaces 'over by $X'")

func test_negative_limit_is_clamped_to_zero():
	t.set_session_limit(-50.0)
	assert_eq(t.get_session_limit(), 0.0)


# ---------- Reset ----------

func test_reset_clears_state_and_repaints():
	t.set_session_limit(10.0)
	t.record_cost("claude", 5.0)
	t.record_cost("elevenlabs", 1.0)
	watch_signals(t)
	t.reset()
	assert_eq(t.get_total(), 0.0)
	assert_eq(t.get_task_count(), 0)
	assert_eq(t.get_breakdown().size(), 0)
	assert_signal_emitted(t, "cost_updated")
	# The session limit setting itself is preserved across reset — only
	# the running spend is cleared.
	assert_almost_eq(t.get_session_limit(), 10.0, 0.0001,
		"reset should clear spend but keep the configured limit")

func test_reset_rearms_warning_latch():
	# Cross the threshold once, reset, cross it again. The reset must
	# clear the latch so the SECOND crossing fires its own warning.
	t.set_session_limit(10.0)
	t.record_cost("claude", 9.0)   # warning fires (and latches)
	t.reset()                       # clears latches AND running spend
	watch_signals(t)
	t.record_cost("claude", 8.5)   # crosses 80% threshold post-reset → warn
	assert_signal_emit_count(t, "budget_warning_reached", 1,
		"after reset, crossing the threshold again should re-fire warning")
	assert_almost_eq(t.get_total(), 8.5, 0.0001)


# ---------- Average per task ----------

func test_average_cost_per_task_after_multiple():
	t.record_cost("claude", 0.10)
	t.record_cost("claude", 0.20)
	t.record_cost("claude", 0.30)
	assert_almost_eq(t.get_average_cost_per_task(), 0.20, 0.0001)
