# param_form.gd
# Reusable Container that renders typed controls from a JSON-Schema-ish
# dict. Built for `BasePlugin.get_param_schema()`, which every plugin
# overrides to declare its `generate(params)` knobs.
#
# Schema shape we support (a strict subset of JSON Schema):
#
#   {
#     "type": "object",
#     "properties": {
#       <field_name>: {
#         "type":        "string" | "integer" | "number" | "boolean",
#         "default":     <value>,                 # required for typed widgets
#         "minimum":     <num>,                   # integer / number only
#         "maximum":     <num>,                   # integer / number only
#         "enum":        [<values>],              # string only — renders OptionButton
#         "description": <human-readable hint>,   # rendered as tooltip
#       },
#       ...
#     },
#     "required": [<field_names>]                  # advisory only for MVP
#   }
#
# Widget mapping:
#
#   boolean                          → CheckBox
#   integer                          → SpinBox (step 1, integer mode)
#   number                           → SpinBox (step 0.01, float mode)
#   string + enum                    → OptionButton
#   string (no enum)                 → LineEdit
#
# Out of scope for MVP (documented as follow-ups in ADR 015):
#   - "object" / "array" property types (nested schemas, lists).
#   - "anyOf" / "oneOf" / conditional fields.
#   - Per-field validation feedback (turning the row red on invalid).
#   - "format" hints (e.g. password-style masking, file pickers).
#
# Test hooks:
#   - `_rows: Dictionary` field_name → {"control": Control, "type": String}
#     so tests can read/write controls without searching the tree.
#   - `set_schema(schema)` and `get_values()` are the public surface.
#   - `clear()` is exposed so generate_form can rebuild on plugin
#     selection change.

extends VBoxContainer

# field_name -> {
#   "control": Control,        # the actual widget (CheckBox / SpinBox / ...)
#   "type":    String,          # "boolean" / "integer" / "number" / "string"
#   "is_enum": bool,            # true if the string field has an enum (OptionButton)
#   "enum":    Array,           # the enum values, in order — only when is_enum
# }
var _rows: Dictionary = {}

# Header label, kept around so we can tweak its text per-plugin without
# rebuilding the whole tree.
var _header_label: Label

# Phase 25 / ADR 025: per-plugin persistence context. When both are
# set, set_schema reads saved values to override defaults and
# persist_values() writes the form state back through settings on
# submit. When either is empty/null, persistence is a no-op (the
# form behaves exactly as in Phase 15).
var _plugin_name: String = ""
var _settings: Node = null

# Setting-key prefix for persisted params. The full key shape is
# `plugin.<plugin_name>.params.<field>` — matches the dotted
# namespacing convention from ADR 024.
const _SETTING_KEY_PREFIX: String = "plugin"


func _ready() -> void:
	_header_label = Label.new()
	_header_label.text = "Parameters"
	_header_label.add_theme_font_size_override("font_size", 13)
	_header_label.modulate = Color(0.85, 0.85, 0.85, 1.0)
	add_child(_header_label)
	# Header is always present; rows go below it.


# ---------- Public API ----------

# Replace the entire form with widgets derived from `schema`.
#
# Phase 25 (ADR 025): when `plugin_name` and `settings` are both
# provided, the form's defaults get overridden by any persisted
# values for that plugin (key shape:
# `plugin.<plugin_name>.params.<field>`). Calls without those args
# behave exactly as in Phase 15 — pure schema-driven defaults.
func set_schema(schema: Dictionary, plugin_name: String = "",
		settings: Node = null) -> void:
	clear()
	_plugin_name = plugin_name
	_settings = settings
	if schema.is_empty():
		_header_label.text = "Parameters (none)"
		return
	var props = schema.get("properties", {})
	if not (props is Dictionary) or (props as Dictionary).is_empty():
		_header_label.text = "Parameters (none)"
		return
	_header_label.text = "Parameters"
	for field_name in (props as Dictionary).keys():
		var spec = (props as Dictionary)[field_name]
		if spec is Dictionary:
			# Override schema default with persisted value when present.
			# We duplicate the spec to avoid mutating the caller's
			# schema Dictionary.
			var effective: Dictionary = (spec as Dictionary).duplicate(true)
			var saved: Variant = _read_saved_value(str(field_name))
			if saved != null:
				effective["default"] = saved
			_build_row(str(field_name), effective)

# Drop every field row but keep the header. Used between renders so we
# never accumulate stale widgets — same orphan-tracker reasoning as the
# other rebuilders in the UI layer.
func clear() -> void:
	for field_name in _rows.keys():
		var row: Control = _rows[field_name].get("row", null)
		if row != null and is_instance_valid(row):
			remove_child(row)
			row.free()
	_rows.clear()

# Snapshot the current values into a Dictionary suitable for passing
# straight into `Orchestrator.generate(plugin, prompt, params)`. Skips
# string fields whose value is empty AND whose default is also empty —
# avoids cluttering the request with `"system": ""` pairs that the
# plugin would have defaulted anyway.
func get_values() -> Dictionary:
	var out: Dictionary = {}
	for field_name in _rows.keys():
		var entry: Dictionary = _rows[field_name]
		var t: String = str(entry.get("type", ""))
		var ctrl = entry.get("control", null)
		if ctrl == null:
			continue
		match t:
			"boolean":
				out[field_name] = (ctrl as CheckBox).button_pressed
			"integer":
				out[field_name] = int((ctrl as SpinBox).value)
			"number":
				out[field_name] = float((ctrl as SpinBox).value)
			"string":
				if bool(entry.get("is_enum", false)):
					var ob: OptionButton = ctrl as OptionButton
					var idx: int = ob.selected
					if idx < 0:
						continue
					var vals: Array = entry.get("enum", []) as Array
					if idx < vals.size():
						out[field_name] = vals[idx]
				else:
					var le: LineEdit = ctrl as LineEdit
					var v: String = le.text
					if not v.is_empty():
						out[field_name] = v
	return out


# Phase 25: write current form values back through settings under
# `plugin.<plugin_name>.params.<field>`. No-op when no settings or
# plugin_name has been bound. Empty strings (already filtered by
# get_values) don't get written — same skip logic as the
# get_values "trailing default empty string" rule.
#
# Called by generate_form on a successful Generate dispatch — we
# only persist values the user actively committed to a real call,
# not values they were idly poking at.
func persist_values() -> void:
	if _settings == null or _plugin_name.is_empty():
		return
	if not _settings.has_method("set_value"):
		return
	var values: Dictionary = get_values()
	for field_name in values.keys():
		var key: String = _setting_key_for(str(field_name))
		_settings.call("set_value", key, values[field_name])


# ---------- Internals ----------

# Read a persisted param value for the current (_plugin_name) plugin,
# or null if missing / no settings bound. Returning null lets the
# caller fall back to the schema's own default.
func _read_saved_value(field_name: String) -> Variant:
	if _settings == null or _plugin_name.is_empty():
		return null
	if not _settings.has_method("has_value") or not _settings.has_method("get_value"):
		return null
	var key: String = _setting_key_for(field_name)
	if not _settings.call("has_value", key):
		return null
	return _settings.call("get_value", key)

# Build the dotted setting key for a given field of the current plugin.
func _setting_key_for(field_name: String) -> String:
	return "%s.%s.params.%s" % [_SETTING_KEY_PREFIX, _plugin_name, field_name]


func _build_row(field_name: String, spec: Dictionary) -> void:
	var t: String = str(spec.get("type", "string"))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	# Tooltip on the row carries the description, since per-control
	# tooltips would mean three different tooltip shapes (Button has
	# tooltip_text, LineEdit has tooltip_text, etc — same property
	# name, different surfaces).
	var desc: String = str(spec.get("description", ""))
	if not desc.is_empty():
		row.tooltip_text = desc
	add_child(row)

	var name_label := Label.new()
	name_label.text = field_name
	name_label.custom_minimum_size = Vector2(110, 0)
	if not desc.is_empty():
		name_label.tooltip_text = desc
	row.add_child(name_label)

	var entry: Dictionary = {"type": t, "row": row}
	var ctrl: Control = null

	match t:
		"boolean":
			ctrl = _make_bool_control(spec)
		"integer":
			ctrl = _make_int_control(spec)
		"number":
			ctrl = _make_number_control(spec)
		"string":
			if spec.has("enum") and spec["enum"] is Array:
				ctrl = _make_enum_control(spec, entry)
			else:
				ctrl = _make_string_control(spec)
		_:
			# Unknown types fall back to a read-only "(unsupported)"
			# label so the user sees the field but can't break it.
			var stub := Label.new()
			stub.text = "(unsupported type: %s)" % t
			stub.modulate = Color(0.7, 0.7, 0.7, 1.0)
			ctrl = stub

	if ctrl != null:
		ctrl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(ctrl)
		entry["control"] = ctrl
		_rows[field_name] = entry

func _make_bool_control(spec: Dictionary) -> CheckBox:
	var cb := CheckBox.new()
	cb.button_pressed = bool(spec.get("default", false))
	return cb

func _make_int_control(spec: Dictionary) -> SpinBox:
	var sb := SpinBox.new()
	sb.step = 1.0
	sb.rounded = true
	if spec.has("minimum"):
		sb.min_value = float(spec["minimum"])
	else:
		sb.allow_lesser = true
		sb.min_value = -1_000_000_000.0
	if spec.has("maximum"):
		sb.max_value = float(spec["maximum"])
	else:
		sb.allow_greater = true
		sb.max_value = 1_000_000_000.0
	sb.value = float(spec.get("default", 0))
	return sb

func _make_number_control(spec: Dictionary) -> SpinBox:
	var sb := SpinBox.new()
	sb.step = 0.01
	if spec.has("minimum"):
		sb.min_value = float(spec["minimum"])
	else:
		sb.allow_lesser = true
		sb.min_value = -1_000_000_000.0
	if spec.has("maximum"):
		sb.max_value = float(spec["maximum"])
	else:
		sb.allow_greater = true
		sb.max_value = 1_000_000_000.0
	sb.value = float(spec.get("default", 0.0))
	return sb

func _make_string_control(spec: Dictionary) -> LineEdit:
	var le := LineEdit.new()
	le.text = str(spec.get("default", ""))
	le.placeholder_text = str(spec.get("default", ""))
	return le

func _make_enum_control(spec: Dictionary, entry: Dictionary) -> OptionButton:
	var values: Array = (spec["enum"] as Array)
	var ob := OptionButton.new()
	for v in values:
		ob.add_item(str(v))
	# Pre-select the default if it's in the enum; otherwise the first.
	var default_val = spec.get("default", null)
	var sel_idx: int = 0
	for i in range(values.size()):
		if values[i] == default_val:
			sel_idx = i
			break
	if values.size() > 0:
		ob.selected = sel_idx
	# Stash both the flag and the values for get_values to read back.
	entry["is_enum"] = true
	entry["enum"] = values
	return ob
