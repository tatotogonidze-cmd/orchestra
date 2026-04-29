# credential_editor.gd
# Modal for per-plugin credential management. Built around the same shape
# as unlock_dialog: full-screen Control, dim background, centered panel.
#
# What it manages:
#   - One row per plugin known to PluginRegistry — Claude, ElevenLabs,
#     Tripo, plus the mocks (registry decides what shows up).
#   - Each row: api_key field with show/hide toggle and a delete button.
#
# What it deliberately does NOT manage (yet):
#   - Multi-key plugins (claude.pricing dict, elevenlabs.per_char_cost_usd).
#     Those are tuning knobs, not secrets, and they need typed inputs.
#     Follow-up — see ADR 011.
#   - Test-connection probe. The api_key may be syntactically valid but
#     auth-rejected at the provider; a real check requires a free or near-
#     free call per provider. Follow-up.
#
# Locked-store branch: if credential_store.is_unlocked() returns false on
# show_dialog(), we render an "Unlock first" message and an Unlock button
# that re-emits an `unlock_requested` signal. main_shell handles that by
# bringing up the unlock dialog again.
#
# Save semantics:
#   - Only ROWS THE USER TOUCHED are written. We compare each row's
#     current text to the value we initially loaded; if unchanged, we
#     skip the set_credential call. This means saving an unchanged form
#     is a no-op on disk.
#   - Rows whose Delete button was pressed are removed via
#     remove_credential. Pressing Delete also empties the field locally
#     so the row visibly reflects the upcoming write.
#
# Test hooks:
#   - `_rows: Dictionary` keyed by plugin_name with the row's controls
#     and bookkeeping. Tests reach in to inspect/manipulate.
#   - `_on_save_pressed` / `_on_cancel_pressed` / `_on_delete_pressed`
#     handlers are callable directly so tests don't have to fake clicks.

extends Control

const PluginRegistryScript = preload("res://scripts/plugin_registry.gd")

signal saved(changed_plugins: Array)
signal cancelled()
signal unlock_requested()

var _orch: Node = null

# Top-level layout pieces.
var _panel: PanelContainer
var _vbox: VBoxContainer
var _header_label: Label
var _status_label: Label

# Container that holds plugin rows when unlocked, OR the lock notice when
# locked. We rebuild its children on every show_dialog() so the editor
# always reflects the current store state.
var _rows_container: VBoxContainer

# Save/Cancel/Unlock buttons. _unlock_button only exists in the locked
# branch; we rebuild the footer on every show_dialog().
var _save_button: Button
var _cancel_button: Button
var _unlock_button: Button

# plugin_name -> {
#   "row":            HBoxContainer,
#   "name_label":     Label,
#   "input":          LineEdit,
#   "toggle_button":  Button,
#   "delete_button":  Button,
#   "initial_value":  String,  # Snapshot at show_dialog time.
#   "marked_delete":  bool,
# }
var _rows: Dictionary = {}


func _ready() -> void:
	anchor_right = 1.0
	anchor_bottom = 1.0
	mouse_filter = Control.MOUSE_FILTER_STOP

	# Dim layer.
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.anchor_right = 1.0
	dim.anchor_bottom = 1.0
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	# Centered panel — wider than the unlock dialog because rows have
	# more content per line.
	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(520, 0)
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
	_header_label.text = "Manage Credentials"
	_header_label.add_theme_font_size_override("font_size", 18)
	_vbox.add_child(_header_label)

	_status_label = Label.new()
	_status_label.text = ""
	_status_label.modulate = Color(0.85, 0.85, 0.85, 1.0)
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_vbox.add_child(_status_label)

	# Body — populated on show_dialog().
	_rows_container = VBoxContainer.new()
	_rows_container.add_theme_constant_override("separation", 6)
	_vbox.add_child(_rows_container)

	# Footer row — Save / Cancel (or Unlock / Cancel in the locked branch).
	# We don't build the footer here; show_dialog() does, so we can swap
	# Save↔Unlock cleanly without juggling visibility on a shared button.
	visible = false


# ---------- Public API ----------

func bind(orch: Node) -> void:
	_orch = orch

func show_dialog() -> void:
	_status_label.text = ""
	_clear_rows_and_footer()
	if _orch == null:
		_render_error("no orchestrator bound (internal error)")
		visible = true
		return
	var store: Node = _orch.credential_store if "credential_store" in _orch else null
	if store == null or not store.is_unlocked():
		_render_locked_branch()
	else:
		_render_unlocked_branch(store)
	visible = true


# ---------- Rendering ----------

func _clear_rows_and_footer() -> void:
	# remove_child + free (NOT queue_free): queue_free is async — it lands
	# next idle frame — so back-to-back show_dialog() calls in tests would
	# leave the freed nodes alive long enough for GUT's orphan tracker to
	# flag them. We're not inside a signal callback for any of these
	# children (show_dialog is a fresh entry point), so synchronous free()
	# is safe.
	for child in _rows_container.get_children():
		_rows_container.remove_child(child)
		child.free()
	_rows.clear()
	# Drop the previous footer too — we re-add it at the end of every
	# show_dialog() because Save↔Unlock can swap.
	_save_button = null
	_cancel_button = null
	_unlock_button = null
	# The footer (if it exists) is the last sibling of _rows_container in
	# _vbox. Find and remove anything after _rows_container.
	var children: Array = _vbox.get_children()
	var seen_rows: bool = false
	for c in children:
		if c == _rows_container:
			seen_rows = true
			continue
		if seen_rows and c is HBoxContainer:
			_vbox.remove_child(c)
			c.free()

func _render_error(msg: String) -> void:
	_status_label.text = msg
	_status_label.modulate = Color(1.0, 0.45, 0.45, 1.0)
	# Footer: just a Cancel button so the user can dismiss.
	var footer: HBoxContainer = _build_footer()
	_cancel_button = _add_footer_button(footer, "Close", _on_cancel_pressed)

func _render_locked_branch() -> void:
	_status_label.text = "Credential store is locked. Unlock it first to manage saved keys."
	_status_label.modulate = Color(0.85, 0.85, 0.85, 1.0)
	var footer: HBoxContainer = _build_footer()
	_cancel_button = _add_footer_button(footer, "Cancel", _on_cancel_pressed)
	_unlock_button = _add_footer_button(footer, "Unlock", _on_unlock_pressed)

func _render_unlocked_branch(store: Node) -> void:
	_status_label.text = "Edit per-plugin API keys. Save persists; Cancel discards."
	_status_label.modulate = Color(0.85, 0.85, 0.85, 1.0)
	for plugin_name in PluginRegistryScript.names():
		_build_row(str(plugin_name), store)
	var footer: HBoxContainer = _build_footer()
	_cancel_button = _add_footer_button(footer, "Cancel", _on_cancel_pressed)
	_save_button = _add_footer_button(footer, "Save", _on_save_pressed)

func _build_footer() -> HBoxContainer:
	var footer := HBoxContainer.new()
	footer.alignment = BoxContainer.ALIGNMENT_END
	footer.add_theme_constant_override("separation", 8)
	_vbox.add_child(footer)
	return footer

func _add_footer_button(footer: HBoxContainer, text: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(handler)
	footer.add_child(b)
	return b

func _build_row(plugin_name: String, store: Node) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_rows_container.add_child(row)

	var name_label := Label.new()
	name_label.text = plugin_name
	name_label.custom_minimum_size = Vector2(110, 0)
	row.add_child(name_label)

	# Pre-fill from credential store. Empty if the user hasn't set this
	# plugin's key yet.
	var initial: String = ""
	var lookup: Dictionary = store.get_credential(plugin_name, "api_key")
	if bool(lookup.get("success", false)):
		initial = str(lookup.get("value", ""))

	var input := LineEdit.new()
	input.text = initial
	input.secret = true
	input.placeholder_text = "api key"
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(input)

	var toggle := Button.new()
	toggle.text = "Show"
	toggle.toggle_mode = true
	toggle.tooltip_text = "Toggle key visibility"
	# Lambda over .bind() per ADR 003. We capture `input` and `toggle`
	# directly so the handler can flip them as a pair.
	toggle.toggled.connect(func(pressed: bool) -> void:
		input.secret = not pressed
		toggle.text = "Hide" if pressed else "Show"
	)
	row.add_child(toggle)

	var delete := Button.new()
	delete.text = "Delete"
	delete.tooltip_text = "Mark this key for removal on Save"
	delete.pressed.connect(func() -> void:
		_on_delete_pressed(plugin_name)
	)
	row.add_child(delete)

	# Phase 22 (ADR 022): per-row Test connection button + status label.
	# The button uses the CURRENTLY REGISTERED plugin instance — so the
	# user must Save before testing newly-typed keys. Tooltip flags this.
	var test_btn := Button.new()
	test_btn.text = "Test"
	test_btn.tooltip_text = "Probe the saved api_key against the provider's API. Save first if you've changed it."
	test_btn.pressed.connect(func() -> void:
		_on_test_connection_pressed(plugin_name))
	row.add_child(test_btn)

	var test_status := Label.new()
	test_status.text = ""
	test_status.modulate = Color(0.85, 0.85, 0.85, 1.0)
	test_status.custom_minimum_size = Vector2(160, 0)
	row.add_child(test_status)

	_rows[plugin_name] = {
		"row":             row,
		"name_label":      name_label,
		"input":           input,
		"toggle_button":   toggle,
		"delete_button":   delete,
		"test_button":     test_btn,
		"test_status":     test_status,
		"initial_value":   initial,
		"marked_delete":   false,
	}


# ---------- Handlers ----------

func _on_save_pressed() -> void:
	if _orch == null:
		_status_label.text = "no orchestrator bound (internal error)"
		_status_label.modulate = Color(1.0, 0.45, 0.45, 1.0)
		return
	var store: Node = _orch.credential_store if "credential_store" in _orch else null
	if store == null or not store.is_unlocked():
		# Race: store got locked between show_dialog and Save. Bail with
		# a clear message rather than silently dropping the user's input.
		_status_label.text = "store became locked; nothing was saved"
		_status_label.modulate = Color(1.0, 0.45, 0.45, 1.0)
		return

	var changed: Array = []
	for plugin_name in _rows.keys():
		var entry: Dictionary = _rows[plugin_name]
		var input: LineEdit = entry["input"]
		var initial: String = str(entry["initial_value"])
		var current: String = input.text
		var marked_delete: bool = bool(entry["marked_delete"])

		if marked_delete:
			# Remove unconditionally — even if the field already happened
			# to be empty, an explicit Delete should leave the store in
			# the "key absent" state.
			store.remove_credential(plugin_name, "api_key")
			changed.append(plugin_name)
			continue
		if current == initial:
			continue
		if current.is_empty():
			# Treat "edited to empty" as "remove" — saving a blank field
			# would leave junk in the store.
			store.remove_credential(plugin_name, "api_key")
		else:
			store.set_credential(plugin_name, "api_key", current)
		changed.append(plugin_name)

	visible = false
	emit_signal("saved", changed)

func _on_cancel_pressed() -> void:
	visible = false
	emit_signal("cancelled")

# Escape acts like Cancel — discards staged edits, hides the modal.
func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey:
		var key: InputEventKey = event as InputEventKey
		if key.pressed and not key.echo and key.keycode == KEY_ESCAPE:
			get_viewport().set_input_as_handled()
			_on_cancel_pressed()

func _on_unlock_pressed() -> void:
	# We don't drive the unlock dialog ourselves; main_shell wires this
	# signal to its existing unlock_dialog instance. That keeps the unlock
	# UX a single code path, no matter where it's triggered from.
	visible = false
	emit_signal("unlock_requested")

func _on_delete_pressed(plugin_name: String) -> void:
	if not _rows.has(plugin_name):
		return
	var entry: Dictionary = _rows[plugin_name]
	(entry["input"] as LineEdit).text = ""
	entry["marked_delete"] = true
	# Visually dim the row so the user can see what's about to be wiped
	# on Save. Cancel still discards everything including this mark.
	(entry["row"] as Control).modulate = Color(0.6, 0.6, 0.6, 1.0)
	_rows[plugin_name] = entry


# ---------- Test connection (Phase 22 / ADR 022) ----------

# Click handler for the per-row Test button. Fetches the currently-
# registered plugin instance, awaits its test_connection probe, and
# routes the result through _set_test_result so the UI updates.
#
# We deliberately use the REGISTERED plugin (not the typed value):
# probing a stale key is misleading, but coupling Test to register-
# with-typed-key would mean either re-registering on every keystroke
# or spinning up a temporary plugin instance per click. Documented in
# ADR 022 follow-ups.
func _on_test_connection_pressed(plugin_name: String) -> void:
	if not _rows.has(plugin_name):
		return
	var entry: Dictionary = _rows[plugin_name]
	# Defensive: guard against `_orch` being null OR being a Node that
	# doesn't expose a `plugin_manager` property. Reading the property
	# directly on a bare Node would raise an "Invalid get index" error
	# at runtime; the `in` check keeps the failure mode polite.
	if _orch == null or not ("plugin_manager" in _orch) \
			or _orch.plugin_manager == null:
		_set_test_result(plugin_name,
			{"success": false, "error": "no orchestrator bound"})
		return
	var pm: Node = _orch.plugin_manager
	var active: Dictionary = pm.active_plugins as Dictionary
	if not active.has(plugin_name):
		_set_test_result(plugin_name,
			{"success": false,
			 "error": "plugin not registered — Save the key first"})
		return
	var plugin: Node = active[plugin_name]
	if plugin == null or not plugin.has_method("test_connection"):
		_set_test_result(plugin_name,
			{"success": false, "error": "plugin has no test_connection"})
		return
	# Mark in-flight visually before awaiting.
	(entry["test_button"] as Button).disabled = true
	(entry["test_status"] as Label).text = "testing…"
	(entry["test_status"] as Label).modulate = Color(0.85, 0.85, 0.85, 1.0)
	# Await the probe. Synchronous probes (mocks) return immediately;
	# real plugins do an HTTP round-trip.
	var result: Dictionary = await plugin.test_connection()
	# The user may have closed the editor / switched contexts in the
	# interim. Defensive: only paint if the row still exists.
	if not _rows.has(plugin_name):
		return
	(entry["test_button"] as Button).disabled = false
	_set_test_result(plugin_name, result)

# Update the per-row test status label from a result Dictionary.
# Public so tests can drive it without standing up a plugin probe.
func _set_test_result(plugin_name: String, result: Dictionary) -> void:
	if not _rows.has(plugin_name):
		return
	var entry: Dictionary = _rows[plugin_name]
	var status: Label = entry["test_status"]
	if bool(result.get("success", false)):
		var msg: String = str(result.get("message", "OK"))
		status.text = "✓ %s" % msg
		status.modulate = Color(0.5, 0.9, 0.5, 1.0)
	else:
		var err: String = str(result.get("error", "failed"))
		status.text = "✗ %s" % err
		status.modulate = Color(1.0, 0.45, 0.45, 1.0)
