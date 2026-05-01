# Tests for settings_panel.gd. Each test gets its own SettingsManager
# bound to a unique on-disk path under user:// so the real
# `user://settings.json` is never touched. Internal handlers
# (_persist_value, _on_reset_pressed, _on_reset_all_pressed) are
# exercised directly — same test seam pattern as the rest of the
# overlay suites.

extends GutTest

const SettingsPanelScript = preload("res://scripts/ui/settings_panel.gd")
const SettingsManagerScript = preload("res://scripts/settings_manager.gd")

var sm: Node
var test_path: String


func before_each() -> void:
	test_path = "user://_test_settings_panel_%d_%d.json" % [
		Time.get_ticks_msec(), randi() % 100000]
	sm = SettingsManagerScript.new()
	add_child_autofree(sm)
	sm.configure(test_path)

func after_each() -> void:
	var abs: String = ProjectSettings.globalize_path(test_path)
	if FileAccess.file_exists(test_path):
		DirAccess.remove_absolute(abs)


func _make_panel() -> Node:
	var p: Node = SettingsPanelScript.new()
	add_child_autofree(p)
	p.bind(sm)
	return p


# ---------- Build / structure ----------

func test_panel_builds_top_level_pieces():
	var p: Node = SettingsPanelScript.new()
	add_child_autofree(p)
	assert_not_null(p._panel, "_panel should be built")
	assert_not_null(p._header_label, "_header_label should be built")
	assert_not_null(p._status_label, "_status_label should be built")
	assert_not_null(p._rows_container, "_rows_container should be built")
	assert_not_null(p._reset_all_button, "_reset_all_button should be built")
	assert_not_null(p._close_button, "_close_button should be built")

func test_panel_starts_hidden():
	var p: Node = SettingsPanelScript.new()
	add_child_autofree(p)
	assert_false(p.visible, "settings panel should start hidden")


# ---------- Show / row rebuild ----------

func test_show_dialog_makes_panel_visible():
	var p: Node = _make_panel()
	p.show_dialog()
	assert_true(p.visible, "show_dialog should make the panel visible")

func test_show_dialog_builds_one_row_per_registry_entry():
	var p: Node = _make_panel()
	p.show_dialog()
	# The registry currently ships 5 entries: cost.session_limit,
	# cost.dispatch_policy, credentials.always_skip, gdd.last_path,
	# gdd.last_export_path.
	assert_eq(p._rows.size(), 5,
		"each registry entry should produce a row; got: %d" % p._rows.size())
	assert_true(p._rows.has("cost.session_limit"),
		"cost.session_limit row should exist")
	assert_true(p._rows.has("cost.dispatch_policy"),
		"cost.dispatch_policy row should exist")
	assert_true(p._rows.has("credentials.always_skip"),
		"credentials.always_skip row should exist")
	assert_true(p._rows.has("gdd.last_path"),
		"gdd.last_path row should exist")
	assert_true(p._rows.has("gdd.last_export_path"),
		"gdd.last_export_path row should exist (Phase 34)")

func test_rebuild_reflects_external_mutation():
	# A consumer (e.g. BudgetHUD) persisted a new limit. Re-opening
	# settings should reflect that without restarting the app.
	var p: Node = _make_panel()
	sm.set_value("cost.session_limit", 75.0)
	p.show_dialog()
	var entry: Dictionary = p._rows["cost.session_limit"]
	var ctrl: SpinBox = entry["control"] as SpinBox
	assert_almost_eq(ctrl.value, 75.0, 0.001,
		"row should reflect externally-mutated value on rebuild")


# ---------- Persist on edit ----------

func test_persist_writes_through_to_settings_manager():
	var p: Node = _make_panel()
	p.show_dialog()
	# Drive the persist handler directly; bypassing CheckBox click
	# matches the test seam used in test_unlock_dialog etc.
	p._persist_value("credentials.always_skip", true)
	assert_true(bool(sm.get_value("credentials.always_skip")),
		"setting should be persisted after _persist_value")

func test_persist_status_label_shows_saved_message():
	var p: Node = _make_panel()
	p.show_dialog()
	p._persist_value("gdd.last_path", "user://demo.json")
	assert_true("Saved" in p._status_label.text,
		"status label should advertise the save; got: %s" % p._status_label.text)

func test_no_panic_when_settings_unbound():
	# Constructed but bind() never called — panel should still build,
	# and persist should be a no-op rather than crashing.
	var p: Node = SettingsPanelScript.new()
	add_child_autofree(p)
	p.show_dialog()
	# Show should still flip visible (but rows stay zero).
	assert_true(p.visible, "panel should still surface even without settings")
	assert_eq(p._rows.size(), 0,
		"no rows should be built without a bound settings manager")
	p._persist_value("anything", 1)  # must not crash.


# ---------- Reset single ----------

func test_reset_removes_persisted_value():
	var p: Node = _make_panel()
	sm.set_value("cost.session_limit", 60.0)
	p.show_dialog()
	p._on_reset_pressed("cost.session_limit")
	assert_false(sm.has_value("cost.session_limit"),
		"reset should drop the key from settings_manager")

func test_reset_restores_default_visually():
	var p: Node = _make_panel()
	sm.set_value("cost.session_limit", 60.0)
	p.show_dialog()
	p._on_reset_pressed("cost.session_limit")
	var entry: Dictionary = p._rows["cost.session_limit"]
	var ctrl: SpinBox = entry["control"] as SpinBox
	assert_almost_eq(ctrl.value, 0.0, 0.001,
		"reset should restore the SpinBox to the registry default")

func test_reset_string_field_clears_lineedit():
	var p: Node = _make_panel()
	sm.set_value("gdd.last_path", "user://something.json")
	p.show_dialog()
	p._on_reset_pressed("gdd.last_path")
	var entry: Dictionary = p._rows["gdd.last_path"]
	var ctrl: LineEdit = entry["control"] as LineEdit
	assert_eq(ctrl.text, "",
		"reset should clear the LineEdit to the registry default ('')")

func test_reset_bool_field_clears_checkbox():
	var p: Node = _make_panel()
	sm.set_value("credentials.always_skip", true)
	p.show_dialog()
	p._on_reset_pressed("credentials.always_skip")
	var entry: Dictionary = p._rows["credentials.always_skip"]
	var ctrl: CheckBox = entry["control"] as CheckBox
	assert_false(ctrl.button_pressed,
		"reset should restore the CheckBox to the registry default (false)")

func test_reset_enum_field_restores_default_selection():
	var p: Node = _make_panel()
	sm.set_value("cost.dispatch_policy", "hard_block")
	p.show_dialog()
	p._on_reset_pressed("cost.dispatch_policy")
	var entry: Dictionary = p._rows["cost.dispatch_policy"]
	var ctrl: OptionButton = entry["control"] as OptionButton
	# The default for cost.dispatch_policy is "warn" — index 0 in the
	# declared enum array.
	assert_eq(ctrl.get_item_text(ctrl.selected), "warn",
		"reset should restore OptionButton to the registry default selection")


# ---------- Reset all ----------

func test_reset_all_clears_settings_store():
	var p: Node = _make_panel()
	sm.set_value("cost.session_limit", 30.0)
	sm.set_value("credentials.always_skip", true)
	sm.set_value("gdd.last_path", "user://x.json")
	p.show_dialog()
	p._on_reset_all_pressed()
	assert_eq(sm.keys().size(), 0,
		"reset all should wipe every persisted setting")

func test_reset_all_rebuilds_rows_to_defaults():
	var p: Node = _make_panel()
	sm.set_value("cost.session_limit", 30.0)
	p.show_dialog()
	p._on_reset_all_pressed()
	# After clear+rebuild, the cost.session_limit row should reflect the
	# registry default (0.0).
	var entry: Dictionary = p._rows["cost.session_limit"]
	var ctrl: SpinBox = entry["control"] as SpinBox
	assert_almost_eq(ctrl.value, 0.0, 0.001,
		"reset_all should rebuild rows with default values")


# ---------- Close ----------

func test_close_hides_panel_and_emits_signal():
	var p: Node = _make_panel()
	p.show_dialog()
	watch_signals(p)
	p._on_close_pressed()
	assert_false(p.visible, "close should hide the panel")
	assert_signal_emitted(p, "closed",
		"close should emit the closed signal")
