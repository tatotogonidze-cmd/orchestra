# settings_panel.gd
# Modal overlay for editing every persisted preference (Phase 33 /
# ADR 033). Replaces the per-consumer-UI scattered editing model
# (BudgetHUD edits cost.session_limit, unlock_dialog edits
# credentials.always_skip, gdd_panel edits gdd.last_path, etc) with
# a single surface where the user can:
#
#   - See every setting that's currently persisted, alongside its
#     default + a brief description.
#   - Edit any value via a typed input (LineEdit / SpinBox /
#     CheckBox depending on declared type).
#   - Reset a single key to default (removes the persisted value).
#   - Reset ALL settings (clears the entire store).
#
# Plugin-param keys (`plugin.<name>.params.<field>`) are NOT shown
# here — they're per-plugin context-sensitive and live in the
# Generate Form's param_form, which already has its own per-row
# reset (Phase 28). Showing them in this panel would mean rendering
# every plugin's full schema, which belongs in a future per-plugin
# settings expansion.

extends Control

const PluginRegistryScript = preload("res://scripts/plugin_registry.gd")

signal closed()

# Registry table for the settings keys we ship in this panel.
# Each row: {key, label, type, default, description}.
# Types: "string" | "bool" | "float" | "integer" | "enum"
#
# Plugin-namespaced keys (`plugin.<name>.params.<field>`) intentionally
# excluded — they're per-plugin and live in param_form's own UI.
const _SETTINGS_REGISTRY: Array = [
	{
		"key":         "cost.session_limit",
		"label":       "Cost: session limit",
		"type":        "float",
		"default":     0.0,
		"description": "Maximum spend per session in USD. 0 = no limit.",
	},
	{
		"key":         "cost.dispatch_policy",
		"label":       "Cost: dispatch policy",
		"type":        "enum",
		"enum":        ["warn", "hard_block"],
		"default":     "warn",
		"description": "warn = soft warnings only. hard_block = refuse Generate when over limit.",
	},
	{
		"key":         "credentials.always_skip",
		"label":       "Credentials: always skip unlock",
		"type":        "bool",
		"default":     false,
		"description": "Bypass the unlock dialog at app start. Env-vars are still resolved.",
	},
	{
		"key":         "gdd.last_path",
		"label":       "GDD: last-used path",
		"type":        "string",
		"default":     "",
		"description": "Pre-fills the GDD viewer's path input on open.",
	},
	{
		"key":         "gdd.last_export_path",
		"label":       "GDD: last export path",
		"type":        "string",
		"default":     "",
		"description": "Default destination for the GDD viewer's Export → Markdown button.",
	},
]

var _settings: Node = null

# Top-level layout pieces.
var _panel: PanelContainer
var _vbox: VBoxContainer
var _header_label: Label
var _status_label: Label
var _rows_container: VBoxContainer
var _close_button: Button
var _reset_all_button: Button

# key -> {control: Control, type: String, reset_button: Button}
var _rows: Dictionary = {}


func _ready() -> void:
	anchor_right = 1.0
	anchor_bottom = 1.0
	mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.anchor_right = 1.0
	dim.anchor_bottom = 1.0
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(640, 0)
	_panel.anchor_left = 0.5
	_panel.anchor_top = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_bottom = 0.5
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(_panel)

	_vbox = VBoxContainer.new()
	_vbox.add_theme_constant_override("separation", 10)
	_panel.add_child(_vbox)

	_header_label = Label.new()
	_header_label.text = "Settings"
	_header_label.add_theme_font_size_override("font_size", 18)
	_vbox.add_child(_header_label)

	_status_label = Label.new()
	_status_label.text = "Edit any field to persist immediately. Reset returns a single key to its default."
	_status_label.modulate = Color(0.7, 0.7, 0.7, 1.0)
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_vbox.add_child(_status_label)

	_rows_container = VBoxContainer.new()
	_rows_container.add_theme_constant_override("separation", 6)
	_vbox.add_child(_rows_container)

	# Footer.
	var footer := HBoxContainer.new()
	footer.alignment = BoxContainer.ALIGNMENT_END
	footer.add_theme_constant_override("separation", 8)
	_vbox.add_child(footer)

	_reset_all_button = Button.new()
	_reset_all_button.text = "Reset all"
	_reset_all_button.tooltip_text = "Clear every persisted setting. All defaults take effect."
	_reset_all_button.pressed.connect(_on_reset_all_pressed)
	footer.add_child(_reset_all_button)

	_close_button = Button.new()
	_close_button.text = "Close"
	_close_button.pressed.connect(_on_close_pressed)
	footer.add_child(_close_button)

	visible = false


# ---------- Public API ----------

func bind(settings: Node) -> void:
	_settings = settings

func show_dialog() -> void:
	_rebuild_rows()
	visible = true


# ---------- Internals ----------

# Rebuild every row from the registry. Called on each show_dialog so
# external mutations (e.g. BudgetHUD persisting a new limit) are
# reflected when the user opens this panel.
func _rebuild_rows() -> void:
	# Free immediately — same orphan-tracker pattern as the other
	# rebuilders (ADR 011 / 012 / 028).
	for child in _rows_container.get_children():
		_rows_container.remove_child(child)
		child.free()
	_rows.clear()
	if _settings == null:
		_status_label.text = "(no settings_manager bound)"
		return
	for spec in _SETTINGS_REGISTRY:
		_build_row(spec as Dictionary)

func _build_row(spec: Dictionary) -> void:
	var key: String = str(spec.get("key", ""))
	if key.is_empty():
		return
	var t: String = str(spec.get("type", "string"))
	var label_text: String = str(spec.get("label", key))
	var description: String = str(spec.get("description", ""))
	var default_value: Variant = spec.get("default", null)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	if not description.is_empty():
		row.tooltip_text = description
	_rows_container.add_child(row)

	var name_label := Label.new()
	name_label.text = label_text
	name_label.custom_minimum_size = Vector2(220, 0)
	if not description.is_empty():
		name_label.tooltip_text = description
	row.add_child(name_label)

	# Read the current value (or default) before building the input.
	var current_value: Variant = _settings.call("get_value", key, default_value)

	var ctrl: Control = null
	match t:
		"bool":
			ctrl = _make_bool_control(key, bool(current_value))
		"integer":
			ctrl = _make_int_control(key, int(current_value))
		"float":
			ctrl = _make_float_control(key, float(current_value))
		"enum":
			ctrl = _make_enum_control(key, str(current_value), spec.get("enum", []) as Array)
		_:
			ctrl = _make_string_control(key, str(current_value))

	if ctrl != null:
		ctrl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(ctrl)

	var reset_btn := Button.new()
	reset_btn.text = "↺"
	reset_btn.tooltip_text = "Reset to default — removes the persisted value"
	reset_btn.pressed.connect(func() -> void:
		_on_reset_pressed(key))
	row.add_child(reset_btn)

	_rows[key] = {
		"control":      ctrl,
		"type":         t,
		"reset_button": reset_btn,
		"default":      default_value,
		"enum":         spec.get("enum", []),
	}

# Per-type input builders. Each wires its change signal to a
# _persist_for_key handler that writes through settings_manager.

func _make_bool_control(key: String, current: bool) -> CheckBox:
	var cb := CheckBox.new()
	cb.button_pressed = current
	cb.toggled.connect(func(pressed: bool) -> void:
		_persist_value(key, pressed))
	return cb

func _make_int_control(key: String, current: int) -> SpinBox:
	var sb := SpinBox.new()
	sb.step = 1.0
	sb.rounded = true
	sb.allow_lesser = true
	sb.allow_greater = true
	sb.min_value = -1_000_000_000.0
	sb.max_value = 1_000_000_000.0
	sb.value = float(current)
	sb.value_changed.connect(func(v: float) -> void:
		_persist_value(key, int(v)))
	return sb

func _make_float_control(key: String, current: float) -> SpinBox:
	var sb := SpinBox.new()
	sb.step = 0.01
	sb.allow_lesser = true
	sb.allow_greater = true
	sb.min_value = -1_000_000_000.0
	sb.max_value = 1_000_000_000.0
	sb.value = current
	sb.value_changed.connect(func(v: float) -> void:
		_persist_value(key, v))
	return sb

func _make_string_control(key: String, current: String) -> LineEdit:
	var le := LineEdit.new()
	le.text = current
	le.text_submitted.connect(func(_t: String) -> void:
		_persist_value(key, le.text))
	# Persist on focus loss too — the user may type then click away
	# without pressing Enter.
	le.focus_exited.connect(func() -> void:
		_persist_value(key, le.text))
	return le

func _make_enum_control(key: String, current: String, values: Array) -> OptionButton:
	var ob := OptionButton.new()
	for v in values:
		ob.add_item(str(v))
	# Pre-select the current value if it's in the enum.
	for i in range(values.size()):
		if str(values[i]) == current:
			ob.selected = i
			break
	ob.item_selected.connect(func(idx: int) -> void:
		if idx >= 0 and idx < values.size():
			_persist_value(key, str(values[idx])))
	return ob


# ---------- Handlers ----------

func _persist_value(key: String, value: Variant) -> void:
	if _settings == null or not _settings.has_method("set_value"):
		return
	_settings.call("set_value", key, value)
	_status_label.text = "Saved: %s" % key
	_status_label.modulate = Color(0.5, 0.9, 0.5, 1.0)

func _on_reset_pressed(key: String) -> void:
	if _settings == null or not _rows.has(key):
		return
	if _settings.has_method("remove_value"):
		_settings.call("remove_value", key)
	# Restore the control to its default value visually.
	var entry: Dictionary = _rows[key]
	var t: String = str(entry.get("type", ""))
	var default_value: Variant = entry.get("default")
	var ctrl = entry.get("control", null)
	if ctrl == null:
		return
	# Block signals during the programmatic restore — otherwise
	# setting `SpinBox.value = 0.0` (or the equivalent for other
	# types) fires the change signal connected to _persist_value
	# and immediately re-persists what we just removed.
	ctrl.set_block_signals(true)
	match t:
		"bool":
			(ctrl as CheckBox).button_pressed = bool(default_value)
		"integer":
			(ctrl as SpinBox).value = float(default_value) if default_value != null else 0.0
		"float":
			(ctrl as SpinBox).value = float(default_value) if default_value != null else 0.0
		"enum":
			var values: Array = entry.get("enum", []) as Array
			for i in range(values.size()):
				if values[i] == default_value:
					(ctrl as OptionButton).selected = i
					break
		_:
			(ctrl as LineEdit).text = str(default_value) if default_value != null else ""
	ctrl.set_block_signals(false)
	_status_label.text = "Reset: %s" % key
	_status_label.modulate = Color(0.85, 0.85, 0.85, 1.0)

func _on_reset_all_pressed() -> void:
	if _settings == null or not _settings.has_method("clear"):
		return
	_settings.call("clear")
	_rebuild_rows()
	_status_label.text = "All settings reset to defaults"
	_status_label.modulate = Color(0.85, 0.85, 0.85, 1.0)

func _on_close_pressed() -> void:
	visible = false
	emit_signal("closed")

# Esc closes — same convention as the other overlays.
func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey:
		var key: InputEventKey = event as InputEventKey
		if key.pressed and not key.echo and key.keycode == KEY_ESCAPE:
			get_viewport().set_input_as_handled()
			_on_close_pressed()
