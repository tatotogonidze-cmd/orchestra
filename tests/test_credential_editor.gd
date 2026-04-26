# Structural tests for the credential editor.
#
# Approach is the same as test_unlock_dialog: drive the editor through
# its internal handlers (`_on_save_pressed`, `_on_cancel_pressed`,
# `_on_delete_pressed`) and observe state + signals. GUT runs headless;
# faking mouse clicks isn't worth the brittleness.
#
# We use a real Orchestrator + CredentialStore so we exercise the actual
# CRUD plumbing. Each test pre-unlocks the credential store with a
# unique `user://_test_*.enc` path so we never touch the real
# `user://credentials.enc` and tests stay hermetic.

extends GutTest

const CredentialEditorScript = preload("res://scripts/ui/credential_editor.gd")
const OrchestratorScript = preload("res://scripts/orchestrator.gd")
const PluginRegistryScript = preload("res://scripts/plugin_registry.gd")


func _unique_store_path() -> String:
	return "user://_test_creds_editor_%d_%d.enc" % [
		Time.get_ticks_msec(), randi() % 100000]


func _remove_path(path: String) -> void:
	var abs_path: String = ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(abs_path)


# Stand up a fresh Orchestrator and pre-unlock its credential store at a
# unique test path. Returns {orch, path}. Caller is responsible for
# removing the path file via _remove_path() in cleanup if it cares.
func _make_orch_with_unlocked_store() -> Dictionary:
	var orch: Node = OrchestratorScript.new()
	add_child_autofree(orch)
	var path: String = _unique_store_path()
	var r: Dictionary = orch.credential_store.unlock("test-pass", path)
	assert_true(bool(r.get("success", false)),
		"precondition: pre-unlock should succeed against fresh path")
	return {"orch": orch, "path": path}


func _make_editor() -> Node:
	var ed: Node = CredentialEditorScript.new()
	add_child_autofree(ed)
	return ed


# ---------- Build / structure ----------

func test_editor_builds_top_level_pieces():
	var ed: Node = _make_editor()
	# These exist regardless of whether show_dialog() has been called yet.
	assert_not_null(ed._panel, "_panel not built")
	assert_not_null(ed._vbox, "_vbox not built")
	assert_not_null(ed._header_label, "_header_label not built")
	assert_not_null(ed._status_label, "_status_label not built")
	assert_not_null(ed._rows_container, "_rows_container not built")
	assert_eq(ed._header_label.text, "Manage Credentials")

func test_editor_starts_hidden():
	var ed: Node = _make_editor()
	assert_false(ed.visible, "editor should start hidden until show_dialog()")


# ---------- Locked-store branch ----------

func test_locked_store_renders_lock_message_and_unlock_button():
	# Build an Orchestrator but DON'T unlock its credential store.
	var orch: Node = OrchestratorScript.new()
	add_child_autofree(orch)
	assert_false(orch.credential_store.is_unlocked(),
		"precondition: store should start locked")

	var ed: Node = _make_editor()
	ed.bind(orch)
	ed.show_dialog()
	assert_true(ed.visible)
	assert_true("locked" in ed._status_label.text.to_lower(),
		"expected lock message; got: %s" % ed._status_label.text)
	# No plugin rows when locked.
	assert_eq(ed._rows.size(), 0,
		"locked branch should not render plugin rows")
	# Unlock button should exist in the locked branch.
	assert_not_null(ed._unlock_button, "Unlock button missing in locked branch")

func test_locked_unlock_button_emits_unlock_requested():
	var orch: Node = OrchestratorScript.new()
	add_child_autofree(orch)
	var ed: Node = _make_editor()
	ed.bind(orch)
	ed.show_dialog()
	watch_signals(ed)
	ed._on_unlock_pressed()
	assert_signal_emitted(ed, "unlock_requested",
		"clicking Unlock in the locked branch must emit unlock_requested")
	assert_false(ed.visible, "editor should hide when delegating to unlock dialog")


# ---------- Unlocked / row rendering ----------

func test_unlocked_renders_one_row_per_known_plugin():
	var ctx: Dictionary = _make_orch_with_unlocked_store()
	var ed: Node = _make_editor()
	ed.bind(ctx["orch"])
	ed.show_dialog()
	# Every plugin in the registry should have a row.
	for plugin_name in PluginRegistryScript.names():
		assert_true(ed._rows.has(plugin_name),
			"missing row for plugin '%s'" % plugin_name)
	# Inputs default to secret.
	for plugin_name in ed._rows.keys():
		var row: Dictionary = ed._rows[plugin_name]
		assert_true((row["input"] as LineEdit).secret,
			"row '%s' input should default to secret mode" % plugin_name)
	_remove_path(ctx["path"])

func test_unlocked_prefills_existing_credentials():
	var ctx: Dictionary = _make_orch_with_unlocked_store()
	var orch: Node = ctx["orch"]
	# Seed one plugin's api_key before opening the editor.
	orch.credential_store.set_credential("claude", "api_key", "sk-pre-existing")

	var ed: Node = _make_editor()
	ed.bind(orch)
	ed.show_dialog()

	var row: Dictionary = ed._rows["claude"]
	assert_eq((row["input"] as LineEdit).text, "sk-pre-existing",
		"row should pre-fill from credential store")
	assert_eq(str(row["initial_value"]), "sk-pre-existing",
		"initial_value snapshot should match prefill")
	# Unsaved plugin: empty input, empty initial.
	var tripo_row: Dictionary = ed._rows["tripo"]
	assert_eq((tripo_row["input"] as LineEdit).text, "")
	assert_eq(str(tripo_row["initial_value"]), "")
	_remove_path(ctx["path"])


# ---------- Save persists ----------

func test_save_writes_changed_rows_only():
	var ctx: Dictionary = _make_orch_with_unlocked_store()
	var orch: Node = ctx["orch"]
	orch.credential_store.set_credential("claude", "api_key", "sk-original")

	var ed: Node = _make_editor()
	ed.bind(orch)
	ed.show_dialog()

	# Edit one row, leave the others alone.
	(ed._rows["claude"]["input"] as LineEdit).text = "sk-edited"
	# tripo and elevenlabs untouched.

	watch_signals(ed)
	ed._on_save_pressed()
	assert_signal_emitted(ed, "saved")
	assert_false(ed.visible, "editor should hide after Save")

	# Verify only claude was updated.
	var claude_get: Dictionary = orch.credential_store.get_credential("claude", "api_key")
	assert_true(bool(claude_get.get("success", false)))
	assert_eq(claude_get["value"], "sk-edited", "claude should have new value")
	# tripo never had a key — still doesn't.
	var tripo_get: Dictionary = orch.credential_store.get_credential("tripo", "api_key")
	assert_false(bool(tripo_get.get("success", false)),
		"unedited tripo row should not have introduced a credential")
	_remove_path(ctx["path"])

func test_save_emptying_a_field_removes_the_credential():
	var ctx: Dictionary = _make_orch_with_unlocked_store()
	var orch: Node = ctx["orch"]
	orch.credential_store.set_credential("claude", "api_key", "sk-to-clear")

	var ed: Node = _make_editor()
	ed.bind(orch)
	ed.show_dialog()
	# User clears the text without using the Delete button — same effect.
	(ed._rows["claude"]["input"] as LineEdit).text = ""
	ed._on_save_pressed()

	var g: Dictionary = orch.credential_store.get_credential("claude", "api_key")
	assert_false(bool(g.get("success", false)),
		"clearing a field should drop the credential, not save '' as the value")
	_remove_path(ctx["path"])


# ---------- Cancel discards ----------

func test_cancel_does_not_persist_edits():
	var ctx: Dictionary = _make_orch_with_unlocked_store()
	var orch: Node = ctx["orch"]
	orch.credential_store.set_credential("claude", "api_key", "sk-keepme")

	var ed: Node = _make_editor()
	ed.bind(orch)
	ed.show_dialog()
	(ed._rows["claude"]["input"] as LineEdit).text = "sk-DISCARD-ME"
	watch_signals(ed)
	ed._on_cancel_pressed()
	assert_signal_emitted(ed, "cancelled")
	assert_false(ed.visible)
	# Original value still in the store.
	var g: Dictionary = orch.credential_store.get_credential("claude", "api_key")
	assert_eq(g["value"], "sk-keepme", "Cancel must not persist edits")
	_remove_path(ctx["path"])


# ---------- Delete row ----------

func test_delete_row_marks_for_removal_and_save_removes():
	var ctx: Dictionary = _make_orch_with_unlocked_store()
	var orch: Node = ctx["orch"]
	orch.credential_store.set_credential("claude", "api_key", "sk-target")

	var ed: Node = _make_editor()
	ed.bind(orch)
	ed.show_dialog()
	# Sanity: row prefilled.
	assert_eq((ed._rows["claude"]["input"] as LineEdit).text, "sk-target")

	ed._on_delete_pressed("claude")
	# Field should now be empty and the marked_delete flag flipped.
	assert_eq((ed._rows["claude"]["input"] as LineEdit).text, "",
		"delete should clear the input visually")
	assert_true(bool(ed._rows["claude"]["marked_delete"]),
		"delete should set marked_delete on the row")

	ed._on_save_pressed()
	var g: Dictionary = orch.credential_store.get_credential("claude", "api_key")
	assert_false(bool(g.get("success", false)),
		"deleted row should be removed from the store on Save")
	_remove_path(ctx["path"])

func test_delete_row_then_cancel_does_not_remove():
	var ctx: Dictionary = _make_orch_with_unlocked_store()
	var orch: Node = ctx["orch"]
	orch.credential_store.set_credential("claude", "api_key", "sk-survive")

	var ed: Node = _make_editor()
	ed.bind(orch)
	ed.show_dialog()
	ed._on_delete_pressed("claude")
	# Cancel before saving — original key should survive.
	ed._on_cancel_pressed()
	var g: Dictionary = orch.credential_store.get_credential("claude", "api_key")
	assert_true(bool(g.get("success", false)),
		"Cancel after Delete should NOT remove the credential")
	assert_eq(g["value"], "sk-survive")
	_remove_path(ctx["path"])


# ---------- Re-show rebuilds rows ----------

# ---------- Esc-to-close (Phase 14) ----------

func test_escape_acts_like_cancel_when_visible():
	var ctx: Dictionary = _make_orch_with_unlocked_store()
	var ed: Node = _make_editor()
	ed.bind(ctx["orch"])
	ed.show_dialog()
	watch_signals(ed)
	var ev := InputEventKey.new()
	ev.keycode = KEY_ESCAPE
	ev.pressed = true
	ed._unhandled_input(ev)
	assert_signal_emitted(ed, "cancelled",
		"Esc should trigger Cancel when the editor is visible")
	assert_false(ed.visible)
	_remove_path(ctx["path"])

func test_escape_is_noop_when_hidden():
	var ed: Node = _make_editor()
	# Editor is built but never shown. Esc should be ignored.
	watch_signals(ed)
	var ev := InputEventKey.new()
	ev.keycode = KEY_ESCAPE
	ev.pressed = true
	ed._unhandled_input(ev)
	assert_signal_not_emitted(ed, "cancelled")


func test_show_dialog_rebuilds_rows_from_current_store_state():
	# A user can save, change something externally (or in another session),
	# and reopen — the editor should reflect the latest state, not its
	# stale snapshot from the first show.
	var ctx: Dictionary = _make_orch_with_unlocked_store()
	var orch: Node = ctx["orch"]
	orch.credential_store.set_credential("claude", "api_key", "v1")

	var ed: Node = _make_editor()
	ed.bind(orch)
	ed.show_dialog()
	assert_eq((ed._rows["claude"]["input"] as LineEdit).text, "v1")

	# Mutate the store under the editor's feet, then re-show.
	orch.credential_store.set_credential("claude", "api_key", "v2")
	ed.show_dialog()
	assert_eq((ed._rows["claude"]["input"] as LineEdit).text, "v2",
		"re-showing the editor must re-read the store")
	_remove_path(ctx["path"])
