# cost_footer.gd
# Persistent status bar at the bottom of the main shell. Always visible.
# Renders one line:
#
#   Session Cost: $12.34 | Budget Left: $7.66 / $20.00         [HUD ▸]
#
# Color shifts as we approach / cross the configured limit:
#   - default: white-ish (no concern)
#   - warning: amber, when CostTracker emits budget_warning_reached
#   - over:    red,   when budget_limit_reached
#
# Click anywhere on the bar (or the HUD button) emits `hud_requested`.
# main_shell catches that and pops the BudgetHUD overlay.
#
# This panel is purely presentational — it doesn't drive cost recording.
# Numbers come from the bound CostTracker via `cost_updated`.

extends PanelContainer

signal hud_requested()
# Emitted when the user clicks "Lock now". main_shell wires this to
# credential_store.lock() + a fresh unlock_dialog. Footer doesn't drive
# either directly — keeps the credential surface in one code path.
signal lock_requested()
# Emitted when the user clicks "GDD". main_shell wires to gdd_panel.
signal gdd_requested()

# Default modulate per state. We modulate the cost label, not the whole
# panel, so the panel background stays consistent.
const COLOR_OK: Color = Color(0.85, 0.85, 0.85, 1.0)
const COLOR_WARN: Color = Color(1.0, 0.7, 0.2, 1.0)
const COLOR_OVER: Color = Color(1.0, 0.4, 0.4, 1.0)

var _tracker: Node = null

var _hbox: HBoxContainer
var _spent_label: Label
var _remaining_label: Label
var _hud_button: Button
var _lock_button: Button
var _gdd_button: Button

# Track the last "state" we painted so tests can assert without parsing
# a Color out of modulate (which is also valid — but a string is easier
# to reason about).
var _state: String = "ok"


func _ready() -> void:
	# Click anywhere on the panel itself opens the HUD. We intercept
	# at the panel level rather than only on a button so the whole bar
	# is a target — easier to hit than a specific button.
	gui_input.connect(_on_panel_input)
	mouse_filter = Control.MOUSE_FILTER_STOP

	_hbox = HBoxContainer.new()
	_hbox.add_theme_constant_override("separation", 12)
	add_child(_hbox)

	_spent_label = Label.new()
	_spent_label.text = "Session Cost: $0.00"
	_spent_label.modulate = COLOR_OK
	_hbox.add_child(_spent_label)

	var sep := Label.new()
	sep.text = "|"
	sep.modulate = Color(0.5, 0.5, 0.5, 1.0)
	_hbox.add_child(sep)

	_remaining_label = Label.new()
	_remaining_label.text = "Budget: not set"
	_remaining_label.modulate = COLOR_OK
	_remaining_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hbox.add_child(_remaining_label)

	_gdd_button = Button.new()
	_gdd_button.text = "GDD"
	_gdd_button.tooltip_text = "Open the Game Design Document viewer"
	_gdd_button.pressed.connect(_emit_gdd_requested)
	_hbox.add_child(_gdd_button)

	_hud_button = Button.new()
	_hud_button.text = "Budget HUD"
	_hud_button.pressed.connect(_emit_hud_requested)
	_hbox.add_child(_hud_button)

	_lock_button = Button.new()
	_lock_button.text = "Lock now"
	_lock_button.tooltip_text = "Lock the credential store and re-show the unlock dialog"
	_lock_button.pressed.connect(_emit_lock_requested)
	_hbox.add_child(_lock_button)


# ---------- Public API ----------

func bind(tracker: Node) -> void:
	_tracker = tracker
	if tracker == null:
		_state = "ok"
		_spent_label.text = "Session Cost: (no tracker)"
		_remaining_label.text = ""
		return
	# Subscribe to repaint events. cost_updated covers both record_cost
	# and limit changes; warning / limit signals are handled separately
	# to flip the color state.
	if tracker.has_signal("cost_updated") and not tracker.cost_updated.is_connected(_refresh):
		tracker.cost_updated.connect(_refresh)
	if tracker.has_signal("budget_warning_reached") and not tracker.budget_warning_reached.is_connected(_on_warning):
		tracker.budget_warning_reached.connect(_on_warning)
	if tracker.has_signal("budget_limit_reached") and not tracker.budget_limit_reached.is_connected(_on_over):
		tracker.budget_limit_reached.connect(_on_over)
	_refresh()


# ---------- Internals ----------

func _refresh() -> void:
	if _tracker == null:
		return
	var spent: float = float(_tracker.call("get_total"))
	var limit: float = float(_tracker.call("get_session_limit"))
	_spent_label.text = "Session Cost: $%.2f" % spent
	if limit > 0.0:
		var remaining: float = limit - spent
		# Recompute color state on every refresh — set_session_limit may
		# have moved the bar without firing warning/over again.
		var threshold: float = float(_tracker.call("get_warning_threshold"))
		if spent >= limit:
			_apply_state("over")
		elif threshold > 0.0 and spent >= limit * threshold:
			_apply_state("warning")
		else:
			_apply_state("ok")
		if remaining >= 0.0:
			_remaining_label.text = "Budget Left: $%.2f / $%.2f" % [remaining, limit]
		else:
			_remaining_label.text = "Over by $%.2f / $%.2f" % [-remaining, limit]
	else:
		_apply_state("ok")
		_remaining_label.text = "Budget: not set"

func _apply_state(state: String) -> void:
	_state = state
	match state:
		"warning":
			_spent_label.modulate = COLOR_WARN
			_remaining_label.modulate = COLOR_WARN
		"over":
			_spent_label.modulate = COLOR_OVER
			_remaining_label.modulate = COLOR_OVER
		_:
			_spent_label.modulate = COLOR_OK
			_remaining_label.modulate = COLOR_OK

func _on_warning(_spent: float, _limit: float) -> void:
	_apply_state("warning")

func _on_over(_spent: float, _limit: float) -> void:
	_apply_state("over")

# Click anywhere on the panel (not just the button) opens the HUD.
func _on_panel_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			_emit_hud_requested()

func _emit_hud_requested() -> void:
	emit_signal("hud_requested")

func _emit_lock_requested() -> void:
	emit_signal("lock_requested")

func _emit_gdd_requested() -> void:
	emit_signal("gdd_requested")
