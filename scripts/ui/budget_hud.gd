# budget_hud.gd
# Detailed cost overlay. Same modal shape as the other dialogs (full-
# screen Control with a dim layer + centered PanelContainer). Surfaces
# from the cost_footer or any "Manage Budget" affordance.
#
# What it shows:
#   - Session limit, spent, remaining, with a ProgressBar.
#   - Warning / over banner that flips color to match cost_tracker
#     state (green ok / amber warn / red over).
#   - Per-category breakdown (text / audio / image / 3d / unknown).
#   - Average cost per task (Total / Tasks).
#
# What it lets the user do:
#   - Set / change the session limit.
#   - Reset the running counter back to zero.
#   - Close.
#
# Like the other modals, every panel is rebuilt on `show_dialog()` so
# we can re-read the latest tracker state — no stale snapshots.

extends Control

const _CATEGORY_ORDER: Array = ["text", "audio", "image", "3d", "unknown"]

signal closed()

var _tracker: Node = null
# Optional settings_manager for persisting the session limit across
# app launches (Phase 24 / ADR 024). When null, Apply just drives the
# tracker without saving — caller chose not to persist.
var _settings: Node = null

# Setting key the HUD writes when the user Applies a new limit.
const _SETTING_KEY_LIMIT: String = "cost.session_limit"

var _panel: PanelContainer
var _vbox: VBoxContainer
var _header_label: Label
var _status_banner: Label
var _summary_label: Label
var _progress: ProgressBar
var _breakdown_container: VBoxContainer
var _limit_input: LineEdit
var _apply_limit_button: Button
var _reset_button: Button
var _close_button: Button
# Phase 26: hard-gating opt-in. When checked, Orchestrator.generate
# refuses dispatches once the session is at/over the limit. Default
# unchecked = "warn" mode (Phase 13 behaviour preserved).
var _hard_block_checkbox: CheckBox

# Setting key the HUD reads + writes for the dispatch policy.
const _SETTING_KEY_POLICY: String = "cost.dispatch_policy"


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
	_panel.custom_minimum_size = Vector2(560, 0)
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
	_header_label.text = "Budget Overview"
	_header_label.add_theme_font_size_override("font_size", 18)
	_vbox.add_child(_header_label)

	_status_banner = Label.new()
	_status_banner.text = ""
	_status_banner.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_vbox.add_child(_status_banner)

	_summary_label = Label.new()
	_summary_label.text = ""
	_summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_vbox.add_child(_summary_label)

	_progress = ProgressBar.new()
	_progress.min_value = 0.0
	_progress.max_value = 1.0
	_progress.value = 0.0
	_progress.show_percentage = false
	_progress.custom_minimum_size = Vector2(0, 14)
	_vbox.add_child(_progress)

	# Per-category breakdown lives in its own VBox so we can clear+repaint
	# its rows on show_dialog without thrashing the rest of the layout.
	var breakdown_header := Label.new()
	breakdown_header.text = "Breakdown by category"
	breakdown_header.add_theme_font_size_override("font_size", 14)
	_vbox.add_child(breakdown_header)

	_breakdown_container = VBoxContainer.new()
	_breakdown_container.add_theme_constant_override("separation", 4)
	_vbox.add_child(_breakdown_container)

	# Session-limit editor row.
	var limit_row := HBoxContainer.new()
	limit_row.add_theme_constant_override("separation", 6)
	_vbox.add_child(limit_row)

	var limit_label := Label.new()
	limit_label.text = "Session limit ($, 0 = no limit):"
	limit_row.add_child(limit_label)

	_limit_input = LineEdit.new()
	_limit_input.placeholder_text = "0.00"
	_limit_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	limit_row.add_child(_limit_input)

	_apply_limit_button = Button.new()
	_apply_limit_button.text = "Apply"
	_apply_limit_button.pressed.connect(_on_apply_limit_pressed)
	limit_row.add_child(_apply_limit_button)

	# Phase 26: hard-gating opt-in. Persists immediately on toggle so
	# the Orchestrator picks up the new policy on the very next
	# dispatch — no need to click Apply for this row.
	_hard_block_checkbox = CheckBox.new()
	_hard_block_checkbox.text = "Hard-block dispatches when over budget"
	_hard_block_checkbox.tooltip_text = "When enabled, Generate refuses to dispatch once the session is at the configured limit. Default is warn-only."
	_hard_block_checkbox.toggled.connect(_on_hard_block_toggled)
	_vbox.add_child(_hard_block_checkbox)

	# Footer.
	var footer := HBoxContainer.new()
	footer.alignment = BoxContainer.ALIGNMENT_END
	footer.add_theme_constant_override("separation", 8)
	_vbox.add_child(footer)

	_reset_button = Button.new()
	_reset_button.text = "Reset session"
	_reset_button.pressed.connect(_on_reset_pressed)
	footer.add_child(_reset_button)

	_close_button = Button.new()
	_close_button.text = "Close"
	_close_button.pressed.connect(_on_close_pressed)
	footer.add_child(_close_button)

	visible = false


# ---------- Public API ----------

func bind(tracker: Node, settings: Node = null) -> void:
	_tracker = tracker
	_settings = settings
	if tracker == null:
		return
	# We don't subscribe in bind() — refresh happens on every show_dialog().
	# If we wanted live updates while the dialog is open, we'd hook
	# cost_updated here. For MVP the user opens the HUD, looks, closes.

func show_dialog() -> void:
	_refresh()
	visible = true


# ---------- Internals ----------

func _refresh() -> void:
	if _tracker == null:
		_status_banner.text = "(no cost tracker bound)"
		return
	var spent: float = float(_tracker.call("get_total"))
	var limit: float = float(_tracker.call("get_session_limit"))
	var threshold: float = float(_tracker.call("get_warning_threshold"))
	var task_count: int = int(_tracker.call("get_task_count"))
	var avg: float = float(_tracker.call("get_average_cost_per_task"))

	# Headline summary.
	if limit > 0.0:
		var remaining: float = limit - spent
		var rem_str: String = "$%.2f" % remaining if remaining >= 0.0 \
			else "-$%.2f (over)" % (-remaining)
		_summary_label.text = "Limit: $%.2f · Spent: $%.2f · Remaining: %s\nTasks: %d · Avg/task: $%.4f" % [
			limit, spent, rem_str, task_count, avg]
	else:
		_summary_label.text = "Limit: not set · Spent: $%.2f · Tasks: %d · Avg/task: $%.4f" % [
			spent, task_count, avg]

	# Banner state.
	if limit <= 0.0:
		_set_banner("No session limit configured.", Color(0.85, 0.85, 0.85, 1.0))
		_progress.value = 0.0
	else:
		var ratio: float = clamp(spent / limit, 0.0, 1.0)
		_progress.value = ratio
		if spent >= limit:
			_set_banner("Over budget — back off or raise the limit.",
				Color(1.0, 0.4, 0.4, 1.0))
		elif threshold > 0.0 and spent >= limit * threshold:
			_set_banner("Approaching budget limit.", Color(1.0, 0.7, 0.2, 1.0))
		else:
			_set_banner("On track.", Color(0.5, 0.9, 0.5, 1.0))

	# Limit editor: prefill with the current value (or empty for "not set").
	_limit_input.text = "" if limit <= 0.0 else "%.2f" % limit

	# Phase 26: reflect persisted dispatch policy into the checkbox.
	# Default ("warn") leaves the box unchecked, preserving Phase 13
	# behaviour for users who never opened the HUD.
	if _hard_block_checkbox != null and _settings != null \
			and _settings.has_method("get_value"):
		var policy: String = str(_settings.call(
			"get_value", _SETTING_KEY_POLICY, "warn"))
		_hard_block_checkbox.button_pressed = (policy == "hard_block")

	# Per-category breakdown rows.
	_rebuild_breakdown(spent)

func _set_banner(text: String, color: Color) -> void:
	_status_banner.text = text
	_status_banner.modulate = color

func _rebuild_breakdown(total: float) -> void:
	# Free immediately rather than queue_free, same orphan-tracker
	# reasoning as ADR 011 / 012.
	for child in _breakdown_container.get_children():
		_breakdown_container.remove_child(child)
		child.free()
	var by_cat: Dictionary = _tracker.call("get_breakdown")
	# Render a row per category we know about, even if its bucket is
	# empty — gives a stable layout the user can scan.
	for cat in _CATEGORY_ORDER:
		var amount: float = float(by_cat.get(cat, 0.0))
		var pct: float = 0.0
		if total > 0.0:
			pct = (amount / total) * 100.0
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var name_lbl := Label.new()
		name_lbl.text = cat
		name_lbl.custom_minimum_size = Vector2(80, 0)
		row.add_child(name_lbl)
		var bar := ProgressBar.new()
		bar.min_value = 0.0
		bar.max_value = 100.0
		bar.value = pct
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(180, 12)
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(bar)
		var amount_lbl := Label.new()
		amount_lbl.text = "$%.4f (%.0f%%)" % [amount, pct]
		row.add_child(amount_lbl)
		_breakdown_container.add_child(row)


# ---------- Handlers ----------

func _on_apply_limit_pressed() -> void:
	if _tracker == null:
		return
	var raw: String = _limit_input.text.strip_edges()
	var new_limit: float = 0.0
	if not raw.is_empty():
		new_limit = float(raw)
	_tracker.call("set_session_limit", new_limit)
	# Persist across launches (Phase 24). 0.0 means "no limit" — we
	# write the value either way so removing a limit also persists.
	if _settings != null and _settings.has_method("set_value"):
		_settings.call("set_value", _SETTING_KEY_LIMIT, new_limit)
	# Repaint to reflect new limit + refreshed banner.
	_refresh()

func _on_reset_pressed() -> void:
	if _tracker == null:
		return
	_tracker.call("reset")
	_refresh()

func _on_close_pressed() -> void:
	visible = false
	emit_signal("closed")

# Phase 26: persist immediately on toggle. We don't gate on Apply
# because the policy is a simple boolean — the user's intent is
# clear from the click. Orchestrator reads cost.dispatch_policy on
# every generate, so the next dispatch picks up the new value
# without further wiring.
func _on_hard_block_toggled(pressed: bool) -> void:
	if _settings == null or not _settings.has_method("set_value"):
		return
	var policy: String = "hard_block" if pressed else "warn"
	_settings.call("set_value", _SETTING_KEY_POLICY, policy)

# Escape acts like the Close button. Gated on visibility so a stray Esc
# elsewhere in the app doesn't fire us.
func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey:
		var key: InputEventKey = event as InputEventKey
		if key.pressed and not key.echo and key.keycode == KEY_ESCAPE:
			get_viewport().set_input_as_handled()
			_on_close_pressed()
