# unlock_dialog.gd
# Full-screen modal that gates the rest of the UI on app startup.
#
# Two reasons it exists:
#   1. The credential store is encrypted — somebody has to type the master
#      password before any plugin can be auto-registered from it.
#   2. We don't want to require env-vars in the daily-driver flow. The
#      Skip button keeps that escape hatch open: env-vars still resolve in
#      Orchestrator._resolve_config(), so users who ONLY want the env-var
#      path can dismiss this dialog without unlocking.
#
# Behavior:
#   - On show_dialog(), checks whether `user://credentials.enc` already
#     exists. If yes → "Unlock to load saved credentials." If no → "Set a
#     master password to create an encrypted store." (Same flow either
#     way; the helper text tells the user what's about to happen.)
#   - Unlock pressed → Orchestrator.unlock_and_register(password). On
#     success emits `unlocked(registered: Array)` and hides itself. On
#     failure paints an error and stays up.
#   - Skip pressed → emits `skipped()` and hides. Caller is expected to
#     fall through to env-var-only registration.
#   - Enter on the password field is treated as Unlock pressed.
#
# Test hooks:
#   - We expose the input/buttons/labels as `_`-prefixed members so
#     tests/test_unlock_dialog.gd can poke them without faking input
#     events. Headless GUT can't simulate clicks reliably; calling the
#     handlers directly is the pragmatic path.

extends Control

signal unlocked(registered: Array)
signal skipped()

const DEFAULT_STORE_PATH: String = "user://credentials.enc"

# Path checked to decide between "first-run" and "existing store" helper
# text. Defaults to the same path CredentialStore writes to. Tests override
# this so they can hit either branch without touching the real file.
var store_path: String = DEFAULT_STORE_PATH

var _orch: Node = null

var _panel: PanelContainer
var _vbox: VBoxContainer
var _header_label: Label
var _helper_label: Label
var _password_input: LineEdit
var _error_label: Label
var _unlock_button: Button
var _skip_button: Button


func _ready() -> void:
	# Cover the whole viewport so clicks outside the panel don't bleed
	# through to the panels behind us. The panel itself is centered.
	anchor_right = 1.0
	anchor_bottom = 1.0
	mouse_filter = Control.MOUSE_FILTER_STOP

	# Dim background. ColorRect at full size with semi-opaque black.
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.anchor_right = 1.0
	dim.anchor_bottom = 1.0
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	# Centered panel.
	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(420, 0)
	_panel.anchor_left = 0.5
	_panel.anchor_top = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_bottom = 0.5
	# Offsets are tuned by the panel's own minimum size; we let Godot's
	# layout pick the height. We anchor the center and let it expand.
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(_panel)

	_vbox = VBoxContainer.new()
	_vbox.add_theme_constant_override("separation", 10)
	_panel.add_child(_vbox)

	_header_label = Label.new()
	_header_label.text = "Unlock credential store"
	_header_label.add_theme_font_size_override("font_size", 18)
	_vbox.add_child(_header_label)

	_helper_label = Label.new()
	_helper_label.text = "" # Filled in by show_dialog().
	_helper_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_helper_label.modulate = Color(0.85, 0.85, 0.85, 1.0)
	_vbox.add_child(_helper_label)

	_password_input = LineEdit.new()
	_password_input.secret = true
	_password_input.placeholder_text = "master password"
	_password_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Pressing Enter in the field acts like clicking Unlock.
	_password_input.text_submitted.connect(_on_password_submitted)
	_vbox.add_child(_password_input)

	_error_label = Label.new()
	_error_label.text = ""
	_error_label.modulate = Color(1.0, 0.45, 0.45, 1.0)
	_error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_vbox.add_child(_error_label)

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	btn_row.add_theme_constant_override("separation", 8)
	_vbox.add_child(btn_row)

	_skip_button = Button.new()
	_skip_button.text = "Skip"
	_skip_button.tooltip_text = "Continue with env-var credentials only"
	_skip_button.pressed.connect(_on_skip_pressed)
	btn_row.add_child(_skip_button)

	_unlock_button = Button.new()
	_unlock_button.text = "Unlock"
	_unlock_button.pressed.connect(_on_unlock_pressed)
	btn_row.add_child(_unlock_button)

	# Default to hidden; main_shell calls show_dialog() once the
	# orchestrator is bound.
	visible = false


# ---------- Public API ----------

func bind(orch: Node) -> void:
	_orch = orch

# Show the dialog and refresh its helper text based on whether a credential
# store file already exists. Caller is expected to have called bind() first;
# if not, Unlock will surface a clear error.
func show_dialog() -> void:
	_error_label.text = ""
	_password_input.text = ""
	_helper_label.text = _resolve_helper_text()
	visible = true
	# Grab focus so the user can just start typing. Deferred so that the
	# focus call lands after the visibility change has propagated.
	_password_input.call_deferred("grab_focus")


# ---------- Internals ----------

func _resolve_helper_text() -> String:
	if FileAccess.file_exists(store_path):
		return "An encrypted credential store exists. Enter the master " \
			+ "password to unlock and auto-register every plugin you've saved."
	return "No credential store yet. Pick a master password — the store " \
		+ "will be created on first save. Or click Skip to use env-vars only."

func _on_password_submitted(_text: String) -> void:
	_on_unlock_pressed()

func _on_unlock_pressed() -> void:
	if _orch == null:
		_error_label.text = "no orchestrator bound (internal error)"
		return
	var pw: String = _password_input.text
	if pw.is_empty():
		_error_label.text = "master password required"
		return
	# Disable the buttons while we work — unlock is synchronous on the
	# CredentialStore side, but register_all_available walks every plugin
	# and may take a noticeable beat. Avoid double-clicks.
	_set_buttons_enabled(false)
	var result: Dictionary = _orch.unlock_and_register(pw)
	_set_buttons_enabled(true)
	if not bool(result.get("success", false)):
		_error_label.text = "unlock failed: %s" % str(result.get("error", "unknown"))
		# Clear the password field so the user re-types deliberately. Leaves
		# focus where it was so they can immediately retry.
		_password_input.text = ""
		return
	var registered: Array = result.get("registered", []) as Array
	visible = false
	emit_signal("unlocked", registered)

func _on_skip_pressed() -> void:
	visible = false
	emit_signal("skipped")

# Escape acts like Skip — same UX as a desktop dialog where Esc dismisses
# without committing. Only fires when the overlay is visible so a stray
# Esc elsewhere in the app doesn't accidentally dismiss us.
func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey:
		var key: InputEventKey = event as InputEventKey
		if key.pressed and not key.echo and key.keycode == KEY_ESCAPE:
			get_viewport().set_input_as_handled()
			_on_skip_pressed()

func _set_buttons_enabled(enabled: bool) -> void:
	_unlock_button.disabled = not enabled
	_skip_button.disabled = not enabled
	_password_input.editable = enabled
