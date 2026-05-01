# Unit tests for param_form.gd. We hand it hand-crafted schemas (not
# real plugin schemas) so each test pins one widget-mapping rule.
#
# Production smoke is covered indirectly by test_ui_shell, where
# generate_form binds to a real orchestrator and exercises the
# claude/elevenlabs/tripo schemas end to end.

extends GutTest

const ParamFormScript = preload("res://scripts/ui/param_form.gd")


func _make_form() -> Node:
	var f: Node = ParamFormScript.new()
	add_child_autofree(f)
	return f


# ---------- Empty / unsupported schemas ----------

func test_empty_schema_renders_only_header():
	var f: Node = _make_form()
	f.set_schema({})
	assert_eq(f._rows.size(), 0,
		"empty schema should produce zero param rows")
	# The header label survives — clear() doesn't drop it.
	assert_true(f._header_label.text.find("none") >= 0,
		"empty schema should label the header as '(none)'; got: %s"
			% f._header_label.text)

func test_schema_with_no_properties_renders_zero_rows():
	var f: Node = _make_form()
	f.set_schema({"type": "object", "properties": {}, "required": []})
	assert_eq(f._rows.size(), 0)


# ---------- Boolean ----------

func test_boolean_property_renders_checkbox_with_default():
	var f: Node = _make_form()
	f.set_schema({
		"type": "object",
		"properties": {
			"enabled": {"type": "boolean", "default": true,
				"description": "Toggle me."},
		},
	})
	assert_true(f._rows.has("enabled"))
	var ctrl = f._rows["enabled"]["control"]
	assert_true(ctrl is CheckBox, "boolean should map to CheckBox")
	assert_true((ctrl as CheckBox).button_pressed,
		"default true should pre-check the box")


# ---------- Integer ----------

func test_integer_property_renders_spinbox_with_bounds():
	var f: Node = _make_form()
	f.set_schema({
		"type": "object",
		"properties": {
			"max_tokens": {
				"type": "integer", "minimum": 1, "maximum": 8192, "default": 1024,
			},
		},
	})
	var ctrl = f._rows["max_tokens"]["control"]
	assert_true(ctrl is SpinBox)
	var sb: SpinBox = ctrl as SpinBox
	assert_eq(sb.min_value, 1.0)
	assert_eq(sb.max_value, 8192.0)
	assert_eq(sb.value, 1024.0)
	assert_true(sb.rounded, "integer SpinBox should be in rounded mode")


# ---------- Number (float) ----------

func test_number_property_renders_spinbox_with_float_bounds():
	var f: Node = _make_form()
	f.set_schema({
		"type": "object",
		"properties": {
			"temperature": {
				"type": "number", "minimum": 0.0, "maximum": 1.0, "default": 0.5,
			},
		},
	})
	var ctrl = f._rows["temperature"]["control"]
	assert_true(ctrl is SpinBox)
	var sb: SpinBox = ctrl as SpinBox
	assert_almost_eq(sb.value, 0.5, 0.001)
	assert_almost_eq(sb.step, 0.01, 0.001,
		"number SpinBox should use a sub-integer step")


# ---------- String — enum vs free-form ----------

func test_string_with_enum_renders_option_button():
	var f: Node = _make_form()
	f.set_schema({
		"type": "object",
		"properties": {
			"style": {
				"type": "string",
				"enum": ["lowpoly", "realistic", "stylized"],
				"default": "realistic",
			},
		},
	})
	var ctrl = f._rows["style"]["control"]
	assert_true(ctrl is OptionButton)
	var ob: OptionButton = ctrl as OptionButton
	assert_eq(ob.get_item_count(), 3)
	# Default is "realistic" → second item (index 1).
	assert_eq(ob.selected, 1, "default value should drive the OptionButton selection")

func test_string_without_enum_renders_line_edit():
	var f: Node = _make_form()
	f.set_schema({
		"type": "object",
		"properties": {
			"system": {"type": "string", "default": "be helpful"},
		},
	})
	var ctrl = f._rows["system"]["control"]
	assert_true(ctrl is LineEdit)
	assert_eq((ctrl as LineEdit).text, "be helpful")


# ---------- get_values ----------

func test_get_values_returns_typed_dict():
	var f: Node = _make_form()
	f.set_schema({
		"type": "object",
		"properties": {
			"flag":  {"type": "boolean", "default": false},
			"count": {"type": "integer", "minimum": 0, "maximum": 10, "default": 3},
			"frac":  {"type": "number",  "minimum": 0.0, "maximum": 1.0, "default": 0.25},
			"name":  {"type": "string",  "default": "alpha"},
			"mode":  {"type": "string",  "enum": ["a", "b", "c"], "default": "b"},
		},
	})
	# Mutate each control as a "user did this".
	(f._rows["flag"]["control"] as CheckBox).button_pressed = true
	(f._rows["count"]["control"] as SpinBox).value = 7
	(f._rows["frac"]["control"] as SpinBox).value = 0.9
	(f._rows["name"]["control"] as LineEdit).text = "beta"
	(f._rows["mode"]["control"] as OptionButton).selected = 2  # "c"

	var values: Dictionary = f.get_values()
	assert_eq(values["flag"], true)
	assert_eq(int(values["count"]), 7)
	assert_almost_eq(float(values["frac"]), 0.9, 0.001)
	assert_eq(values["name"], "beta")
	assert_eq(values["mode"], "c",
		"string-with-enum should write the enum value, not the index")

func test_get_values_omits_empty_strings():
	# A LineEdit left at its empty default would clutter the params dict
	# with `"system": ""` entries the plugin would have defaulted anyway.
	# We skip empties so the plugin's own defaults stay authoritative.
	var f: Node = _make_form()
	f.set_schema({
		"type": "object",
		"properties": {
			"system": {"type": "string", "default": ""},
		},
	})
	# User leaves the field empty.
	var values: Dictionary = f.get_values()
	assert_false(values.has("system"),
		"empty string defaults should be omitted from get_values output")


# ---------- clear / re-render ----------

func test_clear_removes_all_rows_but_keeps_header():
	var f: Node = _make_form()
	f.set_schema({
		"type": "object",
		"properties": {
			"a": {"type": "boolean", "default": false},
			"b": {"type": "integer", "minimum": 0, "maximum": 10, "default": 1},
		},
	})
	assert_eq(f._rows.size(), 2)
	f.clear()
	assert_eq(f._rows.size(), 0,
		"clear should remove all field rows")
	# Header should still be in the tree as a child of f.
	assert_true(f._header_label.is_inside_tree())

# ---------- Per-plugin persistence (Phase 25 / ADR 025) ----------

const SettingsManagerScript = preload("res://scripts/settings_manager.gd")

func _make_settings() -> Node:
	var s: Node = SettingsManagerScript.new()
	add_child_autofree(s)
	# Per-test path so we never touch the real user://settings.json.
	s.configure("user://_test_pf_settings_%d_%d.json" % [
		Time.get_ticks_msec(), randi() % 100000])
	return s

func test_set_schema_with_settings_overrides_default():
	# Persisted value should win over the schema's own default when
	# the form opens.
	var settings: Node = _make_settings()
	settings.set_value("plugin.claude.params.max_tokens", 2048)
	var f: Node = _make_form()
	f.set_schema({
		"type": "object",
		"properties": {
			"max_tokens": {
				"type": "integer", "minimum": 1, "maximum": 8192, "default": 1024,
			},
		},
	}, "claude", settings)
	var sb: SpinBox = f._rows["max_tokens"]["control"] as SpinBox
	assert_eq(int(sb.value), 2048,
		"persisted value should override the schema's default")

func test_set_schema_without_settings_uses_schema_default():
	# Backwards-compat: calling set_schema with one argument behaves
	# exactly as in Phase 15 — pure schema-driven defaults.
	var f: Node = _make_form()
	f.set_schema({
		"type": "object",
		"properties": {
			"max_tokens": {
				"type": "integer", "minimum": 1, "maximum": 8192, "default": 1024,
			},
		},
	})
	var sb: SpinBox = f._rows["max_tokens"]["control"] as SpinBox
	assert_eq(int(sb.value), 1024,
		"without settings, schema default should apply unchanged")

func test_set_schema_without_plugin_name_skips_persistence_lookup():
	# Even when settings is provided, an empty plugin_name disables
	# the lookup. Defends against an accidental empty-name path
	# clobbering one plugin's keys with another's.
	var settings: Node = _make_settings()
	var f: Node = _make_form()
	f.set_schema({
		"type": "object",
		"properties": {
			"max_tokens": {"type": "integer", "minimum": 1, "maximum": 8192, "default": 1024},
		},
	}, "", settings)
	assert_eq(int((f._rows["max_tokens"]["control"] as SpinBox).value), 1024,
		"empty plugin_name should fall back to schema default")

func test_persist_values_writes_through_settings():
	var settings: Node = _make_settings()
	var f: Node = _make_form()
	f.set_schema({
		"type": "object",
		"properties": {
			"flag":  {"type": "boolean", "default": false},
			"count": {"type": "integer", "minimum": 0, "maximum": 10, "default": 3},
			"name":  {"type": "string", "default": "alpha"},
		},
	}, "claude", settings)
	# Mutate as the user would.
	(f._rows["flag"]["control"] as CheckBox).button_pressed = true
	(f._rows["count"]["control"] as SpinBox).value = 7
	(f._rows["name"]["control"] as LineEdit).text = "beta"
	f.persist_values()
	# Each field should now be saved under the plugin's namespace.
	assert_true(bool(settings.get_value("plugin.claude.params.flag")),
		"boolean field should persist")
	assert_eq(int(settings.get_value("plugin.claude.params.count")), 7,
		"integer field should persist")
	assert_eq(settings.get_value("plugin.claude.params.name"), "beta",
		"string field should persist")

func test_persist_values_no_op_without_settings():
	# Without a bound settings_manager, persist_values should be a
	# silent no-op — same backwards-compat shape as Phase 15.
	var f: Node = _make_form()
	f.set_schema({
		"type": "object",
		"properties": {
			"count": {"type": "integer", "minimum": 0, "maximum": 10, "default": 3},
		},
	})
	(f._rows["count"]["control"] as SpinBox).value = 7
	f.persist_values()  # should not crash
	pass_test("persist_values without settings is a graceful no-op")

func test_persist_values_no_op_without_plugin_name():
	# Same defensive path: settings present but plugin_name empty.
	var settings: Node = _make_settings()
	var f: Node = _make_form()
	f.set_schema({
		"type": "object",
		"properties": {
			"count": {"type": "integer", "minimum": 0, "maximum": 10, "default": 3},
		},
	}, "", settings)
	(f._rows["count"]["control"] as SpinBox).value = 7
	f.persist_values()
	assert_eq(settings.keys().size(), 0,
		"persist_values with empty plugin_name should not write anything")


# ---------- Reset-to-default per row (Phase 28 / ADR 028) ----------

func test_row_builds_reset_button_for_supported_types():
	var f: Node = _make_form()
	f.set_schema({
		"type": "object",
		"properties": {
			"a": {"type": "boolean", "default": false},
			"b": {"type": "integer", "minimum": 0, "maximum": 10, "default": 1},
			"c": {"type": "number", "minimum": 0.0, "maximum": 1.0, "default": 0.5},
			"d": {"type": "string", "default": "hello"},
			"e": {"type": "string", "enum": ["x", "y"], "default": "x"},
		},
	})
	for k in ["a", "b", "c", "d", "e"]:
		assert_true(f._rows[k].has("reset_button"),
			"row '%s' should have a reset_button" % k)

func test_row_captures_schema_default_for_reset():
	# The schema default is captured BEFORE saved-value override —
	# reset always restores to schema, not to the most recent saved.
	var settings: Node = _make_settings()
	settings.set_value("plugin.claude.params.max_tokens", 8000)
	var f: Node = _make_form()
	f.set_schema({
		"type": "object",
		"properties": {
			"max_tokens": {"type": "integer", "minimum": 1, "maximum": 8192, "default": 1024},
		},
	}, "claude", settings)
	# Saved value (8000) is what's currently shown.
	assert_eq(int((f._rows["max_tokens"]["control"] as SpinBox).value), 8000)
	# But the schema default (1024) is what reset will restore to.
	assert_eq(int(f._rows["max_tokens"]["schema_default"]), 1024,
		"schema_default should be the original 1024, not the override")

func test_reset_restores_integer_to_schema_default():
	var f: Node = _make_form()
	f.set_schema({
		"type": "object",
		"properties": {
			"max_tokens": {"type": "integer", "minimum": 1, "maximum": 8192, "default": 1024},
		},
	})
	# User mutated the value.
	(f._rows["max_tokens"]["control"] as SpinBox).value = 7000
	f._on_reset_pressed("max_tokens")
	assert_eq(int((f._rows["max_tokens"]["control"] as SpinBox).value), 1024,
		"reset should restore the SpinBox to the schema default")

func test_reset_restores_boolean_to_schema_default():
	var f: Node = _make_form()
	f.set_schema({
		"type": "object",
		"properties": {
			"flag": {"type": "boolean", "default": true},
		},
	})
	(f._rows["flag"]["control"] as CheckBox).button_pressed = false
	f._on_reset_pressed("flag")
	assert_true((f._rows["flag"]["control"] as CheckBox).button_pressed,
		"reset should restore the CheckBox to the schema default")

func test_reset_restores_enum_to_schema_default():
	var f: Node = _make_form()
	f.set_schema({
		"type": "object",
		"properties": {
			"style": {
				"type": "string",
				"enum": ["lowpoly", "realistic", "stylized"],
				"default": "realistic",
			},
		},
	})
	# Move selection off the default.
	(f._rows["style"]["control"] as OptionButton).selected = 0  # "lowpoly"
	f._on_reset_pressed("style")
	# realistic = index 1.
	assert_eq((f._rows["style"]["control"] as OptionButton).selected, 1,
		"reset should restore the OptionButton to the default's index")

func test_reset_removes_persisted_override():
	var settings: Node = _make_settings()
	settings.set_value("plugin.claude.params.max_tokens", 8000)
	var f: Node = _make_form()
	f.set_schema({
		"type": "object",
		"properties": {
			"max_tokens": {"type": "integer", "minimum": 1, "maximum": 8192, "default": 1024},
		},
	}, "claude", settings)
	assert_true(settings.has_value("plugin.claude.params.max_tokens"),
		"precondition: persisted value should exist before reset")
	f._on_reset_pressed("max_tokens")
	assert_false(settings.has_value("plugin.claude.params.max_tokens"),
		"reset should remove the persisted override so the schema default takes over on next render")

func test_reset_unknown_field_is_safe_noop():
	var f: Node = _make_form()
	f.set_schema({
		"type": "object",
		"properties": {
			"a": {"type": "integer", "default": 5},
		},
	})
	# Should not crash.
	f._on_reset_pressed("does_not_exist")
	pass_test("reset on unknown field is a graceful no-op")


func test_set_schema_replaces_previous_schema():
	# Re-rendering with a new schema should drop the old controls — no
	# stale orphans, no double widgets.
	var f: Node = _make_form()
	f.set_schema({
		"type": "object",
		"properties": {"a": {"type": "boolean", "default": false}},
	})
	assert_true(f._rows.has("a"))
	f.set_schema({
		"type": "object",
		"properties": {"b": {"type": "integer", "minimum": 0, "maximum": 5, "default": 2}},
	})
	assert_false(f._rows.has("a"),
		"old field 'a' should be gone after re-render")
	assert_true(f._rows.has("b"),
		"new field 'b' should be present after re-render")
