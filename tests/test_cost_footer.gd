# Tests for cost_footer.gd. We drive a real CostTracker and verify the
# footer repaints + flips state in lockstep.

extends GutTest

const CostFooterScript = preload("res://scripts/ui/cost_footer.gd")
const CostTrackerScript = preload("res://scripts/cost_tracker.gd")


func _make_footer_with_tracker() -> Dictionary:
	var t: Node = CostTrackerScript.new()
	add_child_autofree(t)
	var f: Node = CostFooterScript.new()
	add_child_autofree(f)
	f.bind(t)
	return {"footer": f, "tracker": t}


# ---------- Build / structure ----------

func test_footer_builds_its_children():
	var f: Node = CostFooterScript.new()
	add_child_autofree(f)
	assert_not_null(f._spent_label, "_spent_label not built")
	assert_not_null(f._remaining_label, "_remaining_label not built")
	assert_not_null(f._hud_button, "_hud_button not built")

func test_unbound_footer_shows_placeholder_message():
	var f: Node = CostFooterScript.new()
	add_child_autofree(f)
	f.bind(null)
	assert_true("(no tracker)" in f._spent_label.text,
		"unbound footer should surface a placeholder; got: %s" % f._spent_label.text)


# ---------- Refresh on cost_updated ----------

func test_record_cost_updates_footer_text():
	var ctx: Dictionary = _make_footer_with_tracker()
	var f: Node = ctx["footer"]
	var t: Node = ctx["tracker"]
	t.record_cost("claude", 0.42)
	assert_true("$0.42" in f._spent_label.text,
		"footer should show updated total; got: %s" % f._spent_label.text)

func test_no_limit_shows_budget_not_set():
	var ctx: Dictionary = _make_footer_with_tracker()
	# Initial state — no limit configured.
	assert_true("not set" in (ctx["footer"] as Node)._remaining_label.text,
		"footer should advertise 'not set' until a limit is configured")

func test_limit_set_shows_remaining():
	var ctx: Dictionary = _make_footer_with_tracker()
	var f: Node = ctx["footer"]
	var t: Node = ctx["tracker"]
	t.set_session_limit(20.0)
	t.record_cost("claude", 5.0)
	assert_true("$15.00" in f._remaining_label.text and "$20.00" in f._remaining_label.text,
		"footer should show '$15.00 / $20.00' with a limit set; got: %s" % f._remaining_label.text)

func test_remaining_goes_negative_when_over():
	var ctx: Dictionary = _make_footer_with_tracker()
	var f: Node = ctx["footer"]
	var t: Node = ctx["tracker"]
	t.set_session_limit(10.0)
	t.record_cost("claude", 12.0)
	assert_true("Over by" in f._remaining_label.text,
		"footer should switch to 'Over by' when spent > limit; got: %s" % f._remaining_label.text)


# ---------- State / color transitions ----------

func test_state_starts_ok():
	var ctx: Dictionary = _make_footer_with_tracker()
	assert_eq((ctx["footer"] as Node)._state, "ok")

func test_state_flips_to_warning_at_threshold():
	var ctx: Dictionary = _make_footer_with_tracker()
	var f: Node = ctx["footer"]
	var t: Node = ctx["tracker"]
	t.set_session_limit(10.0)
	# Default threshold 0.8 → warn at $8.
	t.record_cost("claude", 8.0)
	assert_eq(f._state, "warning",
		"footer should be in warning state once spend ≥ 80% of limit")

func test_state_flips_to_over_at_limit():
	var ctx: Dictionary = _make_footer_with_tracker()
	var f: Node = ctx["footer"]
	var t: Node = ctx["tracker"]
	t.set_session_limit(5.0)
	t.record_cost("claude", 6.0)
	assert_eq(f._state, "over")

func test_state_resets_to_ok_after_reset():
	var ctx: Dictionary = _make_footer_with_tracker()
	var f: Node = ctx["footer"]
	var t: Node = ctx["tracker"]
	t.set_session_limit(5.0)
	t.record_cost("claude", 6.0)
	assert_eq(f._state, "over")
	t.reset()
	assert_eq(f._state, "ok",
		"reset should bring the footer back to the ok state")


# ---------- HUD signal ----------

func test_hud_button_emits_hud_requested():
	var ctx: Dictionary = _make_footer_with_tracker()
	var f: Node = ctx["footer"]
	watch_signals(f)
	# The button's pressed signal flows through _emit_hud_requested.
	f._emit_hud_requested()
	assert_signal_emitted(f, "hud_requested")


# ---------- Lock Now button (Phase 14) ----------

func test_footer_builds_lock_button():
	var f: Node = CostFooterScript.new()
	add_child_autofree(f)
	assert_not_null(f._lock_button, "_lock_button should be built alongside _hud_button")

func test_lock_button_emits_lock_requested():
	var f: Node = CostFooterScript.new()
	add_child_autofree(f)
	watch_signals(f)
	f._emit_lock_requested()
	assert_signal_emitted(f, "lock_requested",
		"clicking Lock now should emit lock_requested for main_shell to drive credential_store.lock")


# ---------- GDD button (Phase 16) ----------

func test_footer_builds_gdd_button():
	var f: Node = CostFooterScript.new()
	add_child_autofree(f)
	assert_not_null(f._gdd_button, "_gdd_button should be built alongside HUD/Lock")

func test_gdd_button_emits_gdd_requested():
	var f: Node = CostFooterScript.new()
	add_child_autofree(f)
	watch_signals(f)
	f._emit_gdd_requested()
	assert_signal_emitted(f, "gdd_requested",
		"clicking GDD should emit gdd_requested for main_shell to surface gdd_panel")
