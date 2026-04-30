# Tests for SettingsManager. Each test gets a unique on-disk path
# under user:// so the real `user://settings.json` is never touched.

extends GutTest

const SettingsManagerScript = preload("res://scripts/settings_manager.gd")

var sm
var test_path: String


func before_each() -> void:
	test_path = "user://_test_settings_%d_%d.json" % [
		Time.get_ticks_msec(), randi() % 100000]
	sm = SettingsManagerScript.new()
	add_child_autofree(sm)
	sm.configure(test_path)

func after_each() -> void:
	var abs: String = ProjectSettings.globalize_path(test_path)
	if FileAccess.file_exists(test_path):
		DirAccess.remove_absolute(abs)


# ---------- Initial state ----------

func test_initial_state_is_empty():
	assert_eq(sm.keys().size(), 0)

func test_get_returns_default_for_missing_key():
	assert_eq(sm.get_value("does.not.exist", "fallback"), "fallback")
	assert_eq(int(sm.get_value("missing.int", 42)), 42)
	assert_eq(sm.get_value("missing.no_default"), null)

func test_has_value_false_initially():
	assert_false(sm.has_value("anything"))


# ---------- Set / get round-trip ----------

func test_set_string_round_trip():
	sm.set_value("gdd.last_path", "user://my.json")
	assert_eq(sm.get_value("gdd.last_path"), "user://my.json")
	assert_true(sm.has_value("gdd.last_path"))

func test_set_bool_round_trip():
	sm.set_value("credentials.always_skip", true)
	assert_true(bool(sm.get_value("credentials.always_skip")))

func test_set_int_round_trip():
	sm.set_value("ui.recent_count", 7)
	assert_eq(int(sm.get_value("ui.recent_count")), 7)

func test_set_float_round_trip():
	sm.set_value("cost.session_limit", 49.95)
	assert_almost_eq(float(sm.get_value("cost.session_limit")), 49.95, 0.001)

func test_set_overwrites_existing():
	sm.set_value("k", "first")
	sm.set_value("k", "second")
	assert_eq(sm.get_value("k"), "second")


# ---------- Remove + clear ----------

func test_remove_value_drops_key():
	sm.set_value("temp", true)
	assert_true(sm.has_value("temp"))
	assert_true(sm.remove_value("temp"))
	assert_false(sm.has_value("temp"))

func test_remove_value_returns_false_for_missing_key():
	assert_false(sm.remove_value("never.set"))

func test_clear_empties_all_values():
	sm.set_value("a", 1)
	sm.set_value("b", 2)
	sm.clear()
	assert_eq(sm.keys().size(), 0)
	assert_false(sm.has_value("a"))


# ---------- Persistence ----------

func test_set_persists_immediately():
	sm.set_value("cost.session_limit", 25.0)
	# New instance pointed at the same file should see the value.
	var sm2 = SettingsManagerScript.new()
	add_child_autofree(sm2)
	sm2.configure(test_path)
	assert_almost_eq(float(sm2.get_value("cost.session_limit")), 25.0, 0.001,
		"set_value should persist immediately, no explicit save needed")

func test_remove_persists_immediately():
	sm.set_value("temp", true)
	sm.remove_value("temp")
	var sm2 = SettingsManagerScript.new()
	add_child_autofree(sm2)
	sm2.configure(test_path)
	assert_false(sm2.has_value("temp"),
		"remove_value should persist the deletion to disk")

func test_clear_persists_immediately():
	sm.set_value("a", 1)
	sm.set_value("b", 2)
	sm.clear()
	var sm2 = SettingsManagerScript.new()
	add_child_autofree(sm2)
	sm2.configure(test_path)
	assert_eq(sm2.keys().size(), 0)

func test_load_handles_missing_file():
	# configure() with a path that doesn't exist on disk should
	# leave the manager empty, not crash.
	var sm3 = SettingsManagerScript.new()
	add_child_autofree(sm3)
	var fresh_path: String = "user://_test_settings_never_existed_%d.json" % randi()
	sm3.configure(fresh_path)
	assert_eq(sm3.keys().size(), 0)
	# Should still be writable.
	sm3.set_value("first", "value")
	assert_eq(sm3.get_value("first"), "value")
	# Cleanup
	if FileAccess.file_exists(fresh_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(fresh_path))

func test_configure_resets_in_memory_state():
	sm.set_value("a", 1)
	# Re-configure to a new fresh path; old in-memory state should drop.
	var fresh_path: String = "user://_test_settings_alt_%d.json" % randi()
	sm.configure(fresh_path)
	assert_false(sm.has_value("a"),
		"reconfigure should drop in-memory values and reload from new path")
	if FileAccess.file_exists(fresh_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(fresh_path))


# ---------- Signals ----------

func test_set_emits_setting_changed():
	watch_signals(sm)
	sm.set_value("k", "v")
	assert_signal_emitted(sm, "setting_changed")
	var params: Array = get_signal_parameters(sm, "setting_changed")
	assert_eq(params[0], "k")
	assert_eq(params[1], "v")

func test_remove_emits_setting_removed():
	sm.set_value("k", "v")
	watch_signals(sm)
	sm.remove_value("k")
	assert_signal_emitted(sm, "setting_removed")

func test_remove_missing_does_not_emit():
	watch_signals(sm)
	sm.remove_value("never.was")
	assert_signal_not_emitted(sm, "setting_removed",
		"removing an absent key should be a quiet no-op")


# ---------- Type fidelity through JSON ----------

func test_dictionary_value_round_trip():
	# JSON supports nested objects — verify we don't lose structure.
	sm.set_value("nested", {"inner": "yes", "count": 3})
	var sm2 = SettingsManagerScript.new()
	add_child_autofree(sm2)
	sm2.configure(test_path)
	var got: Dictionary = sm2.get_value("nested") as Dictionary
	assert_eq(got["inner"], "yes")
	assert_eq(int(got["count"]), 3)

func test_array_value_round_trip():
	sm.set_value("recent_paths", ["a.json", "b.json", "c.json"])
	var sm2 = SettingsManagerScript.new()
	add_child_autofree(sm2)
	sm2.configure(test_path)
	var got: Array = sm2.get_value("recent_paths") as Array
	assert_eq(got.size(), 3)
	assert_eq(str(got[2]), "c.json")
