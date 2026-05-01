# Tests for budget_hud.gd. Exercises the dialog's render-from-tracker
# path, the Apply / Reset / Close handlers, and the breakdown UI.

extends GutTest

const BudgetHudScript = preload("res://scripts/ui/budget_hud.gd")
const CostTrackerScript = preload("res://scripts/cost_tracker.gd")


func _make_hud_with_tracker() -> Dictionary:
	var t: Node = CostTrackerScript.new()
	add_child_autofree(t)
	var h: Node = BudgetHudScript.new()
	add_child_autofree(h)
	h.bind(t)
	return {"hud": h, "tracker": t}


# ---------- Build / structure ----------

func test_hud_builds_top_level_pieces():
	var h: Node = BudgetHudScript.new()
	add_child_autofree(h)
	assert_not_null(h._panel)
	assert_not_null(h._summary_label)
	assert_not_null(h._progress)
	assert_not_null(h._breakdown_container)
	assert_not_null(h._limit_input)
	assert_not_null(h._apply_limit_button)
	assert_not_null(h._reset_button)
	assert_not_null(h._close_button)

func test_hud_starts_hidden():
	var h: Node = BudgetHudScript.new()
	add_child_autofree(h)
	assert_false(h.visible)


# ---------- Show / refresh ----------

func test_show_dialog_renders_summary_no_limit():
	var ctx: Dictionary = _make_hud_with_tracker()
	var h: Node = ctx["hud"]
	var t: Node = ctx["tracker"]
	t.record_cost("claude", 2.5)
	h.show_dialog()
	assert_true(h.visible)
	assert_true("Spent: $2.50" in h._summary_label.text,
		"summary should reflect spent total; got: %s" % h._summary_label.text)
	assert_true("not set" in h._summary_label.text,
		"summary should call out 'not set' when no limit is configured")

func test_show_dialog_renders_progress_with_limit():
	var ctx: Dictionary = _make_hud_with_tracker()
	var h: Node = ctx["hud"]
	var t: Node = ctx["tracker"]
	t.set_session_limit(10.0)
	t.record_cost("claude", 5.0)
	h.show_dialog()
	assert_almost_eq(h._progress.value, 0.5, 0.001,
		"progress should be 50% at half budget")
	assert_true("$5.00" in h._summary_label.text,
		"summary should include remaining; got: %s" % h._summary_label.text)

func test_show_dialog_renders_breakdown_rows_per_known_category():
	var ctx: Dictionary = _make_hud_with_tracker()
	var h: Node = ctx["hud"]
	var t: Node = ctx["tracker"]
	t.record_cost("claude", 0.10)
	t.record_cost("elevenlabs", 0.05)
	t.record_cost("tripo", 0.15)
	h.show_dialog()
	# We render one row per known category (text, audio, image, 3d, unknown).
	# 5 categories → 5 child rows in the breakdown container.
	assert_eq(h._breakdown_container.get_child_count(), 5,
		"breakdown should have one row per known category")

func test_limit_prefilled_when_set():
	var ctx: Dictionary = _make_hud_with_tracker()
	var h: Node = ctx["hud"]
	var t: Node = ctx["tracker"]
	t.set_session_limit(42.50)
	h.show_dialog()
	assert_eq(h._limit_input.text, "42.50",
		"limit input should pre-fill with the current limit on show")


# ---------- Apply / Reset / Close ----------

func test_apply_with_value_updates_tracker_limit():
	var ctx: Dictionary = _make_hud_with_tracker()
	var h: Node = ctx["hud"]
	var t: Node = ctx["tracker"]
	h.show_dialog()
	h._limit_input.text = "75"
	h._on_apply_limit_pressed()
	assert_almost_eq(t.get_session_limit(), 75.0, 0.001,
		"Apply should drive tracker.set_session_limit")

func test_apply_with_blank_clears_limit():
	var ctx: Dictionary = _make_hud_with_tracker()
	var h: Node = ctx["hud"]
	var t: Node = ctx["tracker"]
	t.set_session_limit(50.0)
	h.show_dialog()
	h._limit_input.text = ""
	h._on_apply_limit_pressed()
	assert_eq(t.get_session_limit(), 0.0,
		"Apply with a blank field should clear the limit (0)")

func test_reset_clears_tracker_state():
	var ctx: Dictionary = _make_hud_with_tracker()
	var h: Node = ctx["hud"]
	var t: Node = ctx["tracker"]
	t.set_session_limit(10.0)
	t.record_cost("claude", 5.0)
	h.show_dialog()
	h._on_reset_pressed()
	assert_eq(t.get_total(), 0.0,
		"Reset should zero the tracker's running total")
	# Limit is preserved across reset (see CostTracker.reset).
	assert_almost_eq(t.get_session_limit(), 10.0, 0.001)

func test_close_emits_signal_and_hides():
	var ctx: Dictionary = _make_hud_with_tracker()
	var h: Node = ctx["hud"]
	h.show_dialog()
	watch_signals(h)
	h._on_close_pressed()
	assert_signal_emitted(h, "closed")
	assert_false(h.visible)


# ---------- Esc-to-close (Phase 14) ----------

func test_escape_acts_like_close_when_visible():
	var ctx: Dictionary = _make_hud_with_tracker()
	var h: Node = ctx["hud"]
	h.show_dialog()
	watch_signals(h)
	var ev := InputEventKey.new()
	ev.keycode = KEY_ESCAPE
	ev.pressed = true
	h._unhandled_input(ev)
	assert_signal_emitted(h, "closed",
		"Esc should trigger Close when the HUD is visible")
	assert_false(h.visible)

func test_escape_is_noop_when_hidden():
	var h: Node = BudgetHudScript.new()
	add_child_autofree(h)
	# HUD built but never shown. Esc should be ignored.
	watch_signals(h)
	var ev := InputEventKey.new()
	ev.keycode = KEY_ESCAPE
	ev.pressed = true
	h._unhandled_input(ev)
	assert_signal_not_emitted(h, "closed")


# ---------- Settings persistence (Phase 24 / ADR 024) ----------

const SettingsManagerScript = preload("res://scripts/settings_manager.gd")

func _make_settings() -> Node:
	var s: Node = SettingsManagerScript.new()
	add_child_autofree(s)
	# Per-test path so we never touch real user settings.
	s.configure("user://_test_settings_hud_%d_%d.json" % [
		Time.get_ticks_msec(), randi() % 100000])
	return s

func test_apply_limit_persists_via_settings():
	var ctx: Dictionary = _make_hud_with_tracker()
	var h: Node = ctx["hud"]
	var settings: Node = _make_settings()
	# Re-bind with settings — bind accepts (tracker, settings).
	h.bind(ctx["tracker"], settings)
	h.show_dialog()
	h._limit_input.text = "33.5"
	h._on_apply_limit_pressed()
	assert_almost_eq(float(settings.get_value("cost.session_limit", 0.0)),
		33.5, 0.001,
		"Apply should write the new limit through settings_manager")

func test_apply_blank_persists_zero():
	# Clearing the field should persist 0.0 — not just leave the old
	# value lying around.
	var ctx: Dictionary = _make_hud_with_tracker()
	var settings: Node = _make_settings()
	settings.set_value("cost.session_limit", 50.0)
	(ctx["hud"] as Node).bind(ctx["tracker"], settings)
	(ctx["hud"] as Node).show_dialog()
	(ctx["hud"] as Node)._limit_input.text = ""
	(ctx["hud"] as Node)._on_apply_limit_pressed()
	assert_almost_eq(float(settings.get_value("cost.session_limit", -1.0)),
		0.0, 0.001,
		"Apply with blank field should persist 0.0 (no limit)")

func test_apply_without_settings_works_without_persistence():
	# When settings is null (default bind arg), the HUD just drives
	# the tracker. No crash, no persistence — same as before Phase 24.
	var ctx: Dictionary = _make_hud_with_tracker()
	var h: Node = ctx["hud"]
	# Default bind — no settings argument.
	h.bind(ctx["tracker"])
	h.show_dialog()
	h._limit_input.text = "5"
	h._on_apply_limit_pressed()
	assert_almost_eq((ctx["tracker"] as Node).get_session_limit(), 5.0, 0.001)


# ---------- Hard-block policy toggle (Phase 26 / ADR 026) ----------

func test_hud_builds_hard_block_checkbox():
	var h: Node = BudgetHudScript.new()
	add_child_autofree(h)
	assert_not_null(h._hard_block_checkbox,
		"_hard_block_checkbox should be built (Phase 26)")
	assert_false(h._hard_block_checkbox.button_pressed,
		"checkbox should default to unchecked (warn mode)")

func test_toggle_hard_block_persists_policy():
	var ctx: Dictionary = _make_hud_with_tracker()
	var h: Node = ctx["hud"]
	var settings: Node = _make_settings()
	h.bind(ctx["tracker"], settings)
	h.show_dialog()
	# Simulate the user checking the box. The connect target is
	# _on_hard_block_toggled — call it directly.
	h._on_hard_block_toggled(true)
	assert_eq(str(settings.get_value("cost.dispatch_policy", "warn")),
		"hard_block",
		"toggling on should persist 'hard_block'")
	# Toggle off persists the explicit warn value (so future reads
	# don't accidentally fall through to the default).
	h._on_hard_block_toggled(false)
	assert_eq(str(settings.get_value("cost.dispatch_policy", "")),
		"warn",
		"toggling off should persist 'warn'")

func test_show_dialog_reflects_persisted_policy():
	# A previously-saved hard_block setting should pre-check the box
	# the next time the HUD opens.
	var ctx: Dictionary = _make_hud_with_tracker()
	var h: Node = ctx["hud"]
	var settings: Node = _make_settings()
	settings.set_value("cost.dispatch_policy", "hard_block")
	h.bind(ctx["tracker"], settings)
	h.show_dialog()
	assert_true(h._hard_block_checkbox.button_pressed,
		"persisted 'hard_block' should pre-check the checkbox on open")

func test_toggle_without_settings_is_safe_noop():
	# Without a bound settings_manager, the toggle handler should
	# silently no-op rather than crash.
	var ctx: Dictionary = _make_hud_with_tracker()
	var h: Node = ctx["hud"]
	h.bind(ctx["tracker"])  # no settings
	h.show_dialog()
	h._on_hard_block_toggled(true)
	pass_test("toggle without settings is a graceful no-op")
