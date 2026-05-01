# Tests for header_bar.gd. Mirror the action-button assertions that
# previously lived in test_cost_footer.gd before Phase 27's split.

extends GutTest

const HeaderBarScript = preload("res://scripts/ui/header_bar.gd")


func _make_header() -> Node:
	var h: Node = HeaderBarScript.new()
	add_child_autofree(h)
	return h


# ---------- Build / structure ----------

func test_header_builds_action_buttons():
	var h: Node = _make_header()
	assert_not_null(h._title_label, "_title_label should be built")
	assert_not_null(h._gdd_button, "_gdd_button should be built")
	assert_not_null(h._scenes_button, "_scenes_button should be built")
	assert_not_null(h._hud_button, "_hud_button should be built")
	assert_not_null(h._settings_button, "_settings_button should be built")
	assert_not_null(h._lock_button, "_lock_button should be built")

func test_title_default_text():
	var h: Node = _make_header()
	assert_eq(h._title_label.text, "Orchestra",
		"title should default to the app name")


# ---------- Signals ----------

func test_gdd_button_emits_gdd_requested():
	var h: Node = _make_header()
	watch_signals(h)
	h._emit_gdd_requested()
	assert_signal_emitted(h, "gdd_requested",
		"clicking GDD should emit gdd_requested for main_shell to surface gdd_panel")

func test_scenes_button_emits_scenes_requested():
	var h: Node = _make_header()
	watch_signals(h)
	h._emit_scenes_requested()
	assert_signal_emitted(h, "scenes_requested",
		"clicking Scenes should emit scenes_requested for main_shell to surface scene_panel")

func test_hud_button_emits_hud_requested():
	var h: Node = _make_header()
	watch_signals(h)
	h._emit_hud_requested()
	assert_signal_emitted(h, "hud_requested",
		"clicking Budget HUD should emit hud_requested")

func test_lock_button_emits_lock_requested():
	var h: Node = _make_header()
	watch_signals(h)
	h._emit_lock_requested()
	assert_signal_emitted(h, "lock_requested",
		"clicking Lock now should emit lock_requested")

func test_settings_button_emits_settings_requested():
	var h: Node = _make_header()
	watch_signals(h)
	h._emit_settings_requested()
	assert_signal_emitted(h, "settings_requested",
		"clicking Settings should emit settings_requested for main_shell to surface settings_panel")
