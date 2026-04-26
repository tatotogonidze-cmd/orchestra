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
