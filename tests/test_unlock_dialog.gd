# Structural tests for the credential unlock dialog.
#
# We don't simulate clicks — GUT runs headless and faking input events is
# brittle. Instead we drive the dialog through its internal handlers
# (`_on_unlock_pressed`, `_on_skip_pressed`) and observe its state and
# signals. The dialog's docstring documents these handlers as test hooks
# for exactly this reason.
#
# We use a `FakeOrch` stub for orchestrator interactions so each test can
# pin a specific unlock_and_register return shape without standing up a
# real plugin manager / credential store / asset manager. The end-to-end
# Orchestrator unlock flow is covered separately in test_orchestrator.gd
# and test_credential_store.gd.

extends GutTest

const UnlockDialogScript = preload("res://scripts/ui/unlock_dialog.gd")


# A minimal stand-in for Orchestrator. Captures the password it was given
# (so tests can assert it was passed through verbatim) and returns
# whatever `_outcome` is set to.
class FakeOrch extends Node:
	var _outcome: Dictionary = {"success": true, "registered": []}
	var calls: Array = []

	func unlock_and_register(password: String) -> Dictionary:
		calls.append(password)
		return _outcome

	func register_all_available() -> Array:
		return []

	func plugin_names() -> Array:
		return []


func _make_dialog() -> Node:
	var dlg: Node = UnlockDialogScript.new()
	add_child_autofree(dlg)
	return dlg


func _make_fake_orch() -> Node:
	var fake: Node = FakeOrch.new()
	add_child_autofree(fake)
	return fake


# Returns a path under user:// that is guaranteed not to exist when tests
# start. Each call returns a different path so concurrent test runs don't
# step on each other.
func _unique_missing_path() -> String:
	return "user://_test_unlock_no_file_%d_%d.enc" % [
		Time.get_ticks_msec(), randi() % 100000]


# Creates a small placeholder file on disk at a unique path and returns
# that path. The dialog only checks file existence to pick helper text,
# so the contents don't have to be a valid encrypted store.
func _create_placeholder_store() -> String:
	var path: String = "user://_test_unlock_placeholder_%d_%d.enc" % [
		Time.get_ticks_msec(), randi() % 100000]
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	f.store_string("not a real store")
	f.close()
	return path


func _remove_path(path: String) -> void:
	var abs_path: String = ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(abs_path)


# ---------- Build / structure ----------

func test_dialog_builds_its_children():
	var dlg: Node = _make_dialog()
	# All the input-relevant children should exist after _ready.
	assert_not_null(dlg._password_input, "_password_input not built")
	assert_not_null(dlg._unlock_button, "_unlock_button not built")
	assert_not_null(dlg._skip_button, "_skip_button not built")
	assert_not_null(dlg._error_label, "_error_label not built")
	assert_not_null(dlg._helper_label, "_helper_label not built")
	# Password field must be in secret mode — never plaintext on screen.
	assert_true(dlg._password_input.secret,
		"password input should be in secret mode")

func test_dialog_starts_hidden():
	var dlg: Node = _make_dialog()
	assert_false(dlg.visible, "dialog should start hidden until show_dialog()")


# ---------- Helper text branches ----------

func test_helper_text_first_run():
	var dlg: Node = _make_dialog()
	dlg.store_path = _unique_missing_path()
	dlg.show_dialog()
	# First-run text should mention "No credential store yet".
	assert_true("No credential store" in dlg._helper_label.text,
		"first-run helper text not shown; got: %s" % dlg._helper_label.text)

func test_helper_text_existing_store():
	var dlg: Node = _make_dialog()
	var path: String = _create_placeholder_store()
	dlg.store_path = path
	dlg.show_dialog()
	assert_true("encrypted credential store exists" in dlg._helper_label.text,
		"existing-store helper text not shown; got: %s" % dlg._helper_label.text)
	_remove_path(path)


# ---------- Empty / missing-orch error paths ----------

func test_unlock_with_no_orch_shows_error():
	var dlg: Node = _make_dialog()
	dlg.show_dialog()
	dlg._password_input.text = "hunter2"
	dlg._on_unlock_pressed()
	assert_true("no orchestrator" in dlg._error_label.text,
		"expected error about missing orchestrator; got: %s" % dlg._error_label.text)
	assert_true(dlg.visible, "dialog should stay up on internal error")

func test_unlock_with_empty_password_shows_error():
	var dlg: Node = _make_dialog()
	var fake: Node = _make_fake_orch()
	dlg.bind(fake)
	dlg.show_dialog()
	dlg._password_input.text = ""
	watch_signals(dlg)
	dlg._on_unlock_pressed()
	assert_true("password required" in dlg._error_label.text,
		"expected empty-password error; got: %s" % dlg._error_label.text)
	assert_signal_not_emitted(dlg, "unlocked")
	assert_eq((fake as FakeOrch).calls.size(), 0,
		"orch.unlock_and_register should not have been called for empty pw")
	assert_true(dlg.visible, "dialog should stay up when input is invalid")


# ---------- Success path ----------

func test_unlock_success_emits_signal_and_hides():
	var dlg: Node = _make_dialog()
	var fake: Node = _make_fake_orch()
	(fake as FakeOrch)._outcome = {"success": true, "registered": ["claude", "elevenlabs"]}
	dlg.bind(fake)
	dlg.show_dialog()
	dlg._password_input.text = "hunter2"
	watch_signals(dlg)
	dlg._on_unlock_pressed()
	assert_signal_emitted(dlg, "unlocked", "unlocked signal not emitted on success")
	assert_false(dlg.visible, "dialog should hide after successful unlock")
	# The password we typed should have made it down to orch unchanged.
	assert_eq((fake as FakeOrch).calls, ["hunter2"],
		"orch.unlock_and_register did not receive the typed password")
	# Error label cleared.
	assert_eq(dlg._error_label.text, "")

func test_unlock_failure_keeps_dialog_open_and_shows_error():
	var dlg: Node = _make_dialog()
	var fake: Node = _make_fake_orch()
	(fake as FakeOrch)._outcome = {"success": false, "error": "bad password"}
	dlg.bind(fake)
	dlg.show_dialog()
	dlg._password_input.text = "wrong"
	watch_signals(dlg)
	dlg._on_unlock_pressed()
	assert_signal_not_emitted(dlg, "unlocked")
	assert_true(dlg.visible, "dialog should stay up on unlock failure")
	assert_true("bad password" in dlg._error_label.text,
		"error message from orch should surface in the label; got: %s"
			% dlg._error_label.text)
	# We deliberately clear the password so the user retypes from scratch.
	assert_eq(dlg._password_input.text, "",
		"password should be cleared after a failed attempt")


# ---------- Skip path ----------

func test_skip_emits_signal_and_hides():
	var dlg: Node = _make_dialog()
	var fake: Node = _make_fake_orch()
	dlg.bind(fake)
	dlg.show_dialog()
	watch_signals(dlg)
	dlg._on_skip_pressed()
	assert_signal_emitted(dlg, "skipped", "skipped signal not emitted")
	assert_false(dlg.visible, "dialog should hide after Skip")
	assert_eq((fake as FakeOrch).calls.size(), 0,
		"Skip must not call unlock_and_register")


# ---------- Enter-key submit ----------

func test_text_submitted_acts_like_unlock():
	# Pressing Enter on the password field calls _on_password_submitted,
	# which delegates to _on_unlock_pressed. Verify the routing.
	var dlg: Node = _make_dialog()
	var fake: Node = _make_fake_orch()
	(fake as FakeOrch)._outcome = {"success": true, "registered": []}
	dlg.bind(fake)
	dlg.show_dialog()
	dlg._password_input.text = "hunter2"
	watch_signals(dlg)
	dlg._on_password_submitted("hunter2")
	assert_signal_emitted(dlg, "unlocked")
	assert_eq((fake as FakeOrch).calls, ["hunter2"])


# ---------- Esc-to-close (Phase 14) ----------

func test_escape_acts_like_skip_when_visible():
	var dlg: Node = _make_dialog()
	var fake: Node = _make_fake_orch()
	dlg.bind(fake)
	dlg.show_dialog()
	watch_signals(dlg)
	var ev := InputEventKey.new()
	ev.keycode = KEY_ESCAPE
	ev.pressed = true
	dlg._unhandled_input(ev)
	assert_signal_emitted(dlg, "skipped",
		"Esc should trigger Skip when the dialog is visible")
	assert_false(dlg.visible)

func test_escape_is_noop_when_hidden():
	var dlg: Node = _make_dialog()
	# Don't show — dialog stays hidden. Esc should be ignored.
	watch_signals(dlg)
	var ev := InputEventKey.new()
	ev.keycode = KEY_ESCAPE
	ev.pressed = true
	dlg._unhandled_input(ev)
	assert_signal_not_emitted(dlg, "skipped",
		"Esc on a hidden overlay must not fire its close handler")

func test_non_escape_keys_are_ignored():
	var dlg: Node = _make_dialog()
	var fake: Node = _make_fake_orch()
	dlg.bind(fake)
	dlg.show_dialog()
	watch_signals(dlg)
	var ev := InputEventKey.new()
	ev.keycode = KEY_A
	ev.pressed = true
	dlg._unhandled_input(ev)
	assert_signal_not_emitted(dlg, "skipped")
