# header_bar.gd
# Top-level action bar for the main shell (Phase 27 / ADR 027).
#
# Hosts the app's persistent action buttons — GDD viewer, Scene
# Tester, Budget HUD, Lock now — plus a title label on the left.
# These were originally crowded into cost_footer; ADR 023 flagged
# the 4-button threshold as the moment to split, and ADR 027 does
# the move.
#
# Signal names match what cost_footer used to emit, deliberately —
# main_shell wires the same handlers to header_bar instead, with
# minimal upstream change.
#
# Layout (single row, fixed height):
#
#   ┌──────────────────────────────────────────────────────────┐
#   │ Orchestra              [GDD] [Scenes] [Budget HUD] [Lock now] │
#   └──────────────────────────────────────────────────────────┘

extends PanelContainer

signal gdd_requested()
signal scenes_requested()
signal hud_requested()
signal lock_requested()

var _hbox: HBoxContainer
var _title_label: Label
var _gdd_button: Button
var _scenes_button: Button
var _hud_button: Button
var _lock_button: Button


func _ready() -> void:
	_hbox = HBoxContainer.new()
	_hbox.add_theme_constant_override("separation", 8)
	add_child(_hbox)

	_title_label = Label.new()
	_title_label.text = "Orchestra"
	_title_label.add_theme_font_size_override("font_size", 14)
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hbox.add_child(_title_label)

	# Action buttons — order intentionally matches the order they
	# emerged across phases: GDD (16), Scenes (23), Budget HUD (13),
	# Lock now (14). Same signal names as the previous cost_footer
	# buttons so main_shell wiring is a near no-op.
	_gdd_button = Button.new()
	_gdd_button.text = "GDD"
	_gdd_button.tooltip_text = "Open the Game Design Document viewer"
	_gdd_button.pressed.connect(_emit_gdd_requested)
	_hbox.add_child(_gdd_button)

	_scenes_button = Button.new()
	_scenes_button.text = "Scenes"
	_scenes_button.tooltip_text = "Open the Scene Tester to assemble + preview scenes"
	_scenes_button.pressed.connect(_emit_scenes_requested)
	_hbox.add_child(_scenes_button)

	_hud_button = Button.new()
	_hud_button.text = "Budget HUD"
	_hud_button.tooltip_text = "Open the budget overview + per-category breakdown"
	_hud_button.pressed.connect(_emit_hud_requested)
	_hbox.add_child(_hud_button)

	_lock_button = Button.new()
	_lock_button.text = "Lock now"
	_lock_button.tooltip_text = "Lock the credential store and re-show the unlock dialog"
	_lock_button.pressed.connect(_emit_lock_requested)
	_hbox.add_child(_lock_button)


# ---------- Internals ----------

func _emit_gdd_requested() -> void:
	emit_signal("gdd_requested")

func _emit_scenes_requested() -> void:
	emit_signal("scenes_requested")

func _emit_hud_requested() -> void:
	emit_signal("hud_requested")

func _emit_lock_requested() -> void:
	emit_signal("lock_requested")
