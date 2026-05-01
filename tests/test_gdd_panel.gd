# Tests for gdd_panel.gd. We drive a real Orchestrator (so gdd_manager
# is available) and write fixture GDDs to user:// per test, then point
# the panel's path input at those files.

extends GutTest

const GddPanelScript = preload("res://scripts/ui/gdd_panel.gd")
const OrchestratorScript = preload("res://scripts/orchestrator.gd")

var _orch: Node
var _panel: Node
var _fixture_dir: String


func before_each() -> void:
	_fixture_dir = "user://_test_gdd_panel_%d_%d" % [
		Time.get_ticks_msec(), randi() % 100000]
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(_fixture_dir))
	_orch = OrchestratorScript.new()
	add_child_autofree(_orch)
	# Redirect snapshot dir so we never touch real user data.
	_orch.gdd_manager.snapshot_dir = "%s/snapshots" % _fixture_dir
	# Phase 24: redirect settings to a per-test path so tests that
	# write through settings_manager don't pollute user://settings.json.
	_orch.settings_manager.configure("%s/settings.json" % _fixture_dir)
	_panel = GddPanelScript.new()
	add_child_autofree(_panel)
	_panel.bind(_orch)


func after_each() -> void:
	_rm_rf(ProjectSettings.globalize_path(_fixture_dir))


func _minimal_gdd() -> Dictionary:
	return {
		"schema_version": "1.0.0",
		"game_title": "Test Game",
		"genres": ["RPG", "Action"],
		"core_loop": {
			"goal": "survive the night",
			"actions": ["explore", "fight"],
			"rewards": ["xp"],
		},
		"mechanics": [
			{"id": "mech_combat", "description": "turn-based combat"},
			{"id": "mech_inventory", "description": "limited slots"},
		],
		"assets": [],
		"tasks": [
			{"id": "task_intro", "description": "tutorial flow"},
		],
		"metadata": {
			"document_version": "0.1.0",
			"created_at": "2026-04-25T10:00:00Z",
		},
	}


func _write_gdd(gdd: Dictionary) -> String:
	var path: String = "%s/gdd_%d.json" % [_fixture_dir, randi() % 100000]
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(gdd))
	f.close()
	return path


# ---------- Build / structure ----------

func test_panel_builds_top_level_pieces():
	assert_not_null(_panel._panel)
	assert_not_null(_panel._path_input)
	assert_not_null(_panel._load_button)
	assert_not_null(_panel._status_label)
	assert_not_null(_panel._summary_label)
	assert_not_null(_panel._entities_container)
	assert_not_null(_panel._snapshots_container)
	assert_not_null(_panel._close_button)

func test_panel_starts_hidden():
	assert_false(_panel.visible)

func test_path_input_defaults_to_user_gdd_json():
	assert_eq(_panel._path_input.text, "user://gdd.json",
		"path input should pre-fill with the conventional path")


# ---------- Load: error paths ----------

func test_load_with_empty_path_shows_error():
	_panel.show_dialog()
	_panel._path_input.text = ""
	_panel._on_load_pressed()
	assert_true("path required" in _panel._status_label.text,
		"empty path should produce a clear error; got: %s" % _panel._status_label.text)
	assert_eq(_panel._current_gdd.size(), 0,
		"failed load should leave _current_gdd empty")

func test_load_nonexistent_file_shows_error():
	_panel.show_dialog()
	_panel._path_input.text = "%s/does_not_exist.json" % _fixture_dir
	_panel._on_load_pressed()
	assert_true("load failed" in _panel._status_label.text,
		"missing file should produce 'load failed'; got: %s" % _panel._status_label.text)
	assert_eq(_panel._current_gdd.size(), 0)


# ---------- Load: success ----------

func test_load_valid_gdd_populates_summary():
	var path: String = _write_gdd(_minimal_gdd())
	_panel.show_dialog()
	_panel._path_input.text = path
	watch_signals(_panel)
	_panel._on_load_pressed()
	assert_signal_emitted(_panel, "gdd_loaded")
	assert_eq(_panel._current_gdd.get("game_title", ""), "Test Game")
	# Summary should reflect title and genres.
	assert_true("Test Game" in _panel._summary_label.text,
		"summary should include game title; got: %s" % _panel._summary_label.text)
	assert_true("RPG" in _panel._summary_label.text)
	# Status label flips green-ish on a clean load.
	assert_true("Loaded" in _panel._status_label.text)

func test_load_renders_entity_counts():
	var path: String = _write_gdd(_minimal_gdd())
	_panel.show_dialog()
	_panel._path_input.text = path
	_panel._on_load_pressed()
	# Six rows (mechanics, assets, tasks, scenes, characters, dialogues).
	assert_eq(_panel._entities_container.get_child_count(), 6,
		"entities container should render one row per known entity type")
	# First row should be 'mechanics' with count 2.
	var first_row: Node = _panel._entities_container.get_child(0)
	assert_true(first_row is HBoxContainer)
	# The row has [name_label, count_label] — name should be "mechanics".
	var first_name: Label = first_row.get_child(0) as Label
	assert_eq(first_name.text, "mechanics")
	var first_count: Label = first_row.get_child(1) as Label
	assert_eq(first_count.text, "2",
		"mechanics count should match the fixture (2 entries)")

func test_load_invalid_gdd_shows_warning_but_still_displays():
	# Drop a required field (game_title) and verify the panel surfaces
	# the validation issue without refusing to render.
	var bad: Dictionary = _minimal_gdd()
	bad.erase("game_title")
	var path: String = _write_gdd(bad)
	_panel.show_dialog()
	_panel._path_input.text = path
	_panel._on_load_pressed()
	# Status label calls out the validation issues.
	assert_true("validation issue" in _panel._status_label.text,
		"invalid GDD should surface validation issues; got: %s" % _panel._status_label.text)
	# But the GDD is still loaded — the user gets to look at it.
	assert_true(_panel._current_gdd.has("genres"),
		"invalid GDD should still populate _current_gdd")


# ---------- Snapshots ----------

func test_snapshots_empty_renders_placeholder():
	_panel.show_dialog()
	# No snapshots saved yet → placeholder row.
	assert_eq(_panel._snapshots_container.get_child_count(), 1)
	assert_true(_panel._snapshots_container.get_child(0) is Label)

func test_snapshots_render_after_save():
	# Save twice to produce v1 + v2 snapshots, then reopen the panel.
	var path: String = "%s/saved_gdd.json" % _fixture_dir
	_orch.gdd_manager.save_gdd(_minimal_gdd(), path)
	_orch.gdd_manager.save_gdd(_minimal_gdd(), path)
	_panel.show_dialog()
	# Phase 39 (ADR 039): with ≥2 snapshots the pair-wise picker
	# appears as the first child, then one row per snapshot. So
	# child layout is [picker, v2_row, v1_row] — three children
	# total, top snapshot row at index 1.
	assert_eq(_panel._snapshots_container.get_child_count(), 3,
		"two saves should produce one picker + two snapshot rows")
	var top_row: Node = _panel._snapshots_container.get_child(1)
	assert_true(top_row is HBoxContainer)
	var version_lbl: Label = top_row.get_child(0) as Label
	assert_eq(version_lbl.text, "v2",
		"newest snapshot should be at the top of the snapshot rows")


# ---------- Close + Esc ----------

func test_close_button_emits_signal_and_hides():
	_panel.show_dialog()
	watch_signals(_panel)
	_panel._on_close_pressed()
	assert_signal_emitted(_panel, "closed")
	assert_false(_panel.visible)

func test_escape_closes_when_visible():
	_panel.show_dialog()
	watch_signals(_panel)
	var ev := InputEventKey.new()
	ev.keycode = KEY_ESCAPE
	ev.pressed = true
	_panel._unhandled_input(ev)
	assert_signal_emitted(_panel, "closed")
	assert_false(_panel.visible)

func test_escape_is_noop_when_hidden():
	# Don't show the panel. Esc should be ignored.
	watch_signals(_panel)
	var ev := InputEventKey.new()
	ev.keycode = KEY_ESCAPE
	ev.pressed = true
	_panel._unhandled_input(ev)
	assert_signal_not_emitted(_panel, "closed")


# ---------- Chat-edit (Phase 17) ----------

func _load_minimal() -> String:
	# Convenience: write a minimal GDD, point the panel at it, click Load.
	var path: String = _write_gdd(_minimal_gdd())
	_panel.show_dialog()
	_panel._path_input.text = path
	_panel._on_load_pressed()
	return path

func _register_claude() -> void:
	# Register the real claude plugin with a fake api_key. We never
	# actually dispatch a Claude call in these tests — we drive the
	# completion handler directly — but the plugin must be in
	# active_plugins for the visibility / preconditions code paths to
	# treat the chat-edit affordance as available.
	_orch.register_plugin_with_config("claude", {"api_key": "sk-ant-test"})


# Build / structure
func test_chat_edit_section_built():
	assert_not_null(_panel._chat_edit_input, "_chat_edit_input not built")
	assert_not_null(_panel._chat_edit_submit, "_chat_edit_submit not built")
	assert_not_null(_panel._chat_edit_status, "_chat_edit_status not built")
	assert_not_null(_panel._diff_section, "_diff_section not built")
	assert_not_null(_panel._approve_button, "_approve_button not built")
	assert_not_null(_panel._reject_button, "_reject_button not built")

func test_diff_section_starts_hidden():
	assert_false(_panel._diff_section.visible,
		"diff section is only visible during a pending preview")


# Visibility gating
func test_chat_edit_section_hidden_without_gdd():
	# No GDD loaded yet; show_dialog refresh should hide the section.
	_panel.show_dialog()
	assert_false(_panel._chat_edit_section.visible,
		"chat-edit section should be hidden until a GDD is loaded")

func test_chat_edit_section_hidden_without_claude():
	_load_minimal()
	# claude not registered → still hidden.
	assert_false(_panel._chat_edit_section.visible,
		"chat-edit needs claude registered to make sense")

func test_chat_edit_section_visible_with_gdd_and_claude():
	_register_claude()
	_load_minimal()
	assert_true(_panel._chat_edit_section.visible,
		"section should surface once both preconditions are met")
	assert_false(_panel._chat_edit_submit.disabled,
		"submit should be enabled in the IDLE state")


# Compose prompt
func test_compose_chat_edit_prompt_includes_gdd_and_instruction():
	var gdd: Dictionary = _minimal_gdd()
	var schema: Dictionary = {"type": "object", "properties": {"x": {"type": "string"}}}
	var prompt: String = _panel._compose_chat_edit_prompt(gdd, schema, "add stealth")
	assert_true("Test Game" in prompt,
		"prompt should include the current GDD's title")
	assert_true("add stealth" in prompt,
		"prompt should include the user's instruction verbatim")
	assert_true("JSON Schema" in prompt,
		"prompt should reference the schema as context")
	assert_true("ONLY the updated JSON document" in prompt,
		"prompt should command return-only-JSON")


# Parse response
func test_parse_chat_edit_response_valid_json():
	var raw: String = '{"game_title": "X", "genres": ["RPG"]}'
	var r: Dictionary = _panel._parse_chat_edit_response(raw)
	assert_true(bool(r["success"]))
	assert_eq(r["gdd"]["game_title"], "X")

func test_parse_chat_edit_response_strips_code_fence():
	# Claude sometimes ignores the no-code-fence directive.
	var raw: String = "```json\n{\"game_title\": \"Y\"}\n```"
	var r: Dictionary = _panel._parse_chat_edit_response(raw)
	assert_true(bool(r["success"]),
		"parser should tolerate a leading ```json fence")
	assert_eq(r["gdd"]["game_title"], "Y")

func test_parse_chat_edit_response_invalid_json():
	var raw: String = "this is not JSON"
	var r: Dictionary = _panel._parse_chat_edit_response(raw)
	assert_false(bool(r["success"]))
	assert_true("error" in r)

func test_parse_chat_edit_response_empty():
	var r: Dictionary = _panel._parse_chat_edit_response("")
	assert_false(bool(r["success"]))


# Diff summary
func test_diff_summary_no_changes():
	var g: Dictionary = _minimal_gdd()
	var s: String = _panel._compute_diff_summary(g, g.duplicate(true))
	assert_true("No structural changes" in s,
		"identical GDDs should report no changes; got: %s" % s)

func test_diff_summary_entity_count_change():
	var before: Dictionary = _minimal_gdd()
	var after: Dictionary = before.duplicate(true)
	(after["mechanics"] as Array).append({"id": "mech_stealth", "description": "sneak"})
	var s: String = _panel._compute_diff_summary(before, after)
	assert_true("mechanics: 2 → 3" in s,
		"summary should report entity count delta; got: %s" % s)

func test_diff_summary_top_level_field_change():
	var before: Dictionary = _minimal_gdd()
	var after: Dictionary = before.duplicate(true)
	after["game_title"] = "New Title"
	var s: String = _panel._compute_diff_summary(before, after)
	assert_true("~game_title" in s,
		"changed top-level field should be marked with ~; got: %s" % s)


# Submit preconditions
func test_submit_with_no_gdd_loaded_warns():
	_register_claude()
	_panel.show_dialog()
	_panel._chat_edit_input.text = "add stealth"
	_panel._on_chat_edit_submit_pressed()
	assert_true("load a GDD" in _panel._chat_edit_status.text or "first" in _panel._chat_edit_status.text,
		"submit without GDD should explain; got: %s" % _panel._chat_edit_status.text)
	assert_eq(_panel._chat_edit_task_id, "",
		"no task should have been dispatched")

func test_submit_with_empty_instruction_warns():
	_register_claude()
	_load_minimal()
	_panel._chat_edit_input.text = ""
	_panel._on_chat_edit_submit_pressed()
	assert_true("describe" in _panel._chat_edit_status.text,
		"submit with blank instruction should prompt for one; got: %s"
			% _panel._chat_edit_status.text)
	assert_eq(_panel._chat_edit_task_id, "")


# Completion handler — happy path
func test_completion_with_valid_json_renders_preview():
	_register_claude()
	_load_minimal()
	# Simulate a dispatch by setting the task id directly. We then
	# feed a synthetic completion result through the handler.
	_panel._chat_edit_task_id = "claude:fake-1"
	var proposed: Dictionary = _minimal_gdd()
	proposed["game_title"] = "Edited Title"
	(proposed["mechanics"] as Array).append({"id": "mech_stealth", "description": "sneak"})
	_panel._on_chat_edit_completed("claude", "claude:fake-1",
		{"text": JSON.stringify(proposed)})
	assert_eq(_panel._chat_edit_task_id, "",
		"task id should clear once completion was handled")
	assert_false(_panel._pending_gdd.is_empty(),
		"_pending_gdd should hold the proposed document")
	assert_true(_panel._diff_section.visible,
		"diff section should surface after a successful parse")
	assert_true("Edited Title" in _panel._diff_after_view.text,
		"after-view should show the proposed JSON")

# Completion handler — unrelated task id
func test_completion_for_unrelated_task_id_is_ignored():
	_register_claude()
	_load_minimal()
	_panel._chat_edit_task_id = "claude:our-task"
	var proposed: Dictionary = _minimal_gdd()
	_panel._on_chat_edit_completed("claude", "claude:someone-else",
		{"text": JSON.stringify(proposed)})
	assert_eq(_panel._chat_edit_task_id, "claude:our-task",
		"task id should NOT be cleared by an unrelated completion")
	assert_true(_panel._pending_gdd.is_empty(),
		"pending GDD must not be set by an unrelated completion")
	assert_false(_panel._diff_section.visible)

# Completion handler — bad JSON
func test_completion_with_bad_json_surfaces_error():
	_register_claude()
	_load_minimal()
	_panel._chat_edit_task_id = "claude:fake-2"
	_panel._on_chat_edit_completed("claude", "claude:fake-2",
		{"text": "this is not JSON, sorry"})
	assert_true("parse failed" in _panel._chat_edit_status.text,
		"status should call out parse failure; got: %s" % _panel._chat_edit_status.text)
	assert_true(_panel._pending_gdd.is_empty())
	assert_false(_panel._diff_section.visible)
	# Submit re-enabled so the user can retry with a tweaked instruction.
	assert_false(_panel._chat_edit_submit.disabled)


# Failure handler
func test_failure_handler_surfaces_error_for_our_task():
	_register_claude()
	_load_minimal()
	_panel._chat_edit_task_id = "claude:fake-3"
	_panel._on_chat_edit_failed("claude", "claude:fake-3",
		{"code": "AUTH_FAILED", "message": "bad key"})
	assert_eq(_panel._chat_edit_task_id, "")
	assert_true("bad key" in _panel._chat_edit_status.text,
		"failure message should surface; got: %s" % _panel._chat_edit_status.text)
	assert_false(_panel._chat_edit_submit.disabled)


# Reject — no save
func test_reject_clears_pending_without_writing():
	_register_claude()
	_load_minimal()
	_panel._pending_gdd = _minimal_gdd()
	_panel._diff_section.visible = true
	watch_signals(_panel)
	_panel._on_reject_pressed()
	assert_signal_emitted(_panel, "chat_edit_rejected")
	assert_true(_panel._pending_gdd.is_empty())
	assert_false(_panel._diff_section.visible)


# Approve — pre-snapshot + save
func test_approve_writes_two_snapshots():
	_register_claude()
	var path: String = _load_minimal()
	# Cook up a "proposed" change.
	var proposed: Dictionary = _panel._current_gdd.duplicate(true)
	proposed["game_title"] = "Approved Title"
	_panel._pending_gdd = proposed
	# Pre-approve: zero snapshots in the dir.
	assert_eq(_orch.gdd_manager.list_snapshots().size(), 0)
	watch_signals(_panel)
	_panel._on_approve_pressed()
	assert_signal_emitted(_panel, "chat_edit_applied")
	# Two snapshots created: pre-state then post-state.
	var snaps: Array = _orch.gdd_manager.list_snapshots()
	assert_eq(snaps.size(), 2,
		"approve should create snapshots for pre-state AND post-state")
	# Disk now reflects the proposed GDD.
	var loaded: Dictionary = _orch.gdd_manager.load_gdd(path)
	assert_eq(loaded["gdd"]["game_title"], "Approved Title")
	# Pending state cleared, panel promoted the new GDD.
	assert_true(_panel._pending_gdd.is_empty())
	assert_eq(_panel._current_gdd["game_title"], "Approved Title")


# ---------- Conversation-mode chat-edit (Phase 31 / ADR 031) ----------

func test_resolve_basis_returns_current_when_no_pending():
	# Before any chat-edit lands, the basis is the saved baseline.
	_panel._current_gdd = {"game_title": "saved"}
	_panel._pending_gdd = {}
	var basis: Dictionary = _panel._resolve_chat_edit_basis()
	assert_eq(basis["game_title"], "saved",
		"with no pending preview, basis should be the saved baseline")

func test_resolve_basis_returns_pending_when_set():
	# In PREVIEW state, the basis is the latest proposed GDD —
	# this is what the user is iterating on.
	_panel._current_gdd = {"game_title": "saved"}
	_panel._pending_gdd = {"game_title": "proposed (turn 1)"}
	var basis: Dictionary = _panel._resolve_chat_edit_basis()
	assert_eq(basis["game_title"], "proposed (turn 1)",
		"with a pending preview, refinement should iterate on it, not the baseline")

func test_first_submit_increments_turn_to_one():
	_register_claude()
	_load_minimal()
	_panel._chat_edit_input.text = "add stealth"
	assert_eq(_panel._conversation_turn, 0,
		"counter starts at 0 before any dispatch")
	_panel._on_chat_edit_submit_pressed()
	assert_eq(_panel._conversation_turn, 1,
		"first submit should bump the turn counter to 1")

func test_refinement_submit_increments_turn():
	_register_claude()
	_load_minimal()
	# Simulate first dispatch + completion landing.
	_panel._chat_edit_input.text = "add stealth"
	_panel._on_chat_edit_submit_pressed()
	_panel._on_chat_edit_completed("claude", _panel._chat_edit_task_id,
		{"text": JSON.stringify(_minimal_gdd())})
	# Now in PREVIEW state. Submit a refinement.
	_panel._chat_edit_input.text = "make it more cinematic"
	_panel._on_chat_edit_submit_pressed()
	assert_eq(_panel._conversation_turn, 2,
		"second submit during PREVIEW should reach turn 2")

func test_submit_in_preview_uses_pending_as_basis():
	_register_claude()
	_load_minimal()
	# Land a first proposal.
	_panel._chat_edit_input.text = "add stealth"
	_panel._on_chat_edit_submit_pressed()
	var proposed: Dictionary = _minimal_gdd()
	proposed["game_title"] = "proposed-after-turn-1"
	_panel._on_chat_edit_completed("claude", _panel._chat_edit_task_id,
		{"text": JSON.stringify(proposed)})
	# Verify the basis the form would use NOW is the proposed one.
	var basis: Dictionary = _panel._resolve_chat_edit_basis()
	assert_eq(basis["game_title"], "proposed-after-turn-1",
		"after first turn lands, refinements iterate on the proposal")

func test_approve_resets_turn_counter():
	_register_claude()
	var path: String = _load_minimal()
	# Synthesize a pending preview.
	_panel._pending_gdd = _panel._current_gdd.duplicate(true)
	_panel._pending_gdd["game_title"] = "Approved"
	_panel._conversation_turn = 3
	_panel._on_approve_pressed()
	assert_eq(_panel._conversation_turn, 0,
		"approving the proposal should end the conversation (turn reset)")

func test_reject_resets_turn_counter():
	_register_claude()
	_load_minimal()
	_panel._pending_gdd = _minimal_gdd()
	_panel._conversation_turn = 4
	_panel._on_reject_pressed()
	assert_eq(_panel._conversation_turn, 0,
		"rejecting the proposal should end the conversation (turn reset)")

func test_submit_stays_enabled_in_preview_state():
	# Phase 31 changes the disabled-button policy. Mid-flight still
	# disables (so the user can't double-dispatch), but PREVIEW
	# state keeps Submit enabled for refinement.
	_register_claude()
	_load_minimal()
	_panel._pending_gdd = _minimal_gdd()
	_panel._chat_edit_task_id = ""  # not in flight
	_panel._refresh_chat_edit_visibility()
	assert_false(_panel._chat_edit_submit.disabled,
		"Submit should be enabled in PREVIEW state for refinement turns")


# ---------- Auto-fix cross-refs (Phase 29 / ADR 029) ----------

# Helper: build a minimal GDD with one dangling task dependency.
func _gdd_with_dangling_ref() -> Dictionary:
	var g: Dictionary = _minimal_gdd()
	# minimal_gdd has tasks: [{id: task_intro, ...}]. Append a
	# dangling dependency so clean_dangling_references has work to do.
	(g["tasks"] as Array)[0]["dependencies"] = ["task_phantom"]
	return g

func test_autofix_button_hidden_for_clean_gdd():
	var path: String = _write_gdd(_minimal_gdd())
	_panel.show_dialog()
	_panel._path_input.text = path
	_panel._on_load_pressed()
	assert_false(_panel._autofix_button.visible,
		"clean GDD should not surface the Auto-fix button")

func test_autofix_button_shown_with_count_when_refs_dangle():
	var path: String = _write_gdd(_gdd_with_dangling_ref())
	_panel.show_dialog()
	_panel._path_input.text = path
	_panel._on_load_pressed()
	assert_true(_panel._autofix_button.visible,
		"GDD with dangling refs should surface the Auto-fix button")
	assert_true("(1)" in _panel._autofix_button.text,
		"button label should advertise the fix count; got: %s"
			% _panel._autofix_button.text)

func test_autofix_pressed_cleans_and_saves():
	var path: String = _write_gdd(_gdd_with_dangling_ref())
	_panel.show_dialog()
	_panel._path_input.text = path
	_panel._on_load_pressed()
	# Sanity: the in-memory GDD has the dangling ref.
	assert_eq((_panel._current_gdd["tasks"][0]["dependencies"] as Array).size(), 1)
	_panel._on_autofix_pressed()
	# After auto-fix, the dependency array should be empty.
	assert_eq((_panel._current_gdd["tasks"][0]["dependencies"] as Array).size(), 0,
		"auto-fix should prune the dangling dependency")
	# Status surfaces the count.
	assert_true("removed 1" in _panel._status_label.text,
		"status should call out the removed count; got: %s"
			% _panel._status_label.text)
	# Disk reflects the clean GDD now.
	var loaded: Dictionary = _orch.gdd_manager.load_gdd(path)
	assert_eq((loaded["gdd"]["tasks"][0]["dependencies"] as Array).size(), 0,
		"on-disk GDD should be the cleaned version")
	# Button hides since there's nothing left to fix.
	assert_false(_panel._autofix_button.visible,
		"Auto-fix button should hide once all refs are clean")


# ---------- Settings persistence (Phase 24) ----------

func test_load_persists_path_to_settings():
	var path: String = _write_gdd(_minimal_gdd())
	_panel.show_dialog()
	_panel._path_input.text = path
	_panel._on_load_pressed()
	# settings_manager should now hold the path under the gdd
	# namespace.
	var saved: String = str(_orch.settings_manager.get_value(
		"gdd.last_path", ""))
	assert_eq(saved, path,
		"successful Load should persist the path through settings_manager")

func test_show_dialog_prefills_path_from_settings():
	# Pre-seed a saved path BEFORE the panel opens. Use a fresh panel
	# (the before_each one already mutated _current_gdd_path).
	_orch.settings_manager.set_value("gdd.last_path", "user://saved.json")
	var fresh: Node = GddPanelScript.new()
	add_child_autofree(fresh)
	fresh.bind(_orch)
	fresh.show_dialog()
	assert_eq(fresh._path_input.text, "user://saved.json",
		"show_dialog should prefill path from settings.gdd.last_path")

func test_show_dialog_keeps_input_after_user_typed_during_session():
	# Once the user has loaded something this session
	# (_current_gdd_path is non-empty), reopening the panel should
	# NOT overwrite the input — they may want to switch to a slightly-
	# different path manually. We respect their in-session edits.
	var path: String = _write_gdd(_minimal_gdd())
	_panel.show_dialog()
	_panel._path_input.text = path
	_panel._on_load_pressed()
	# Now the user types something else and re-shows.
	_panel._path_input.text = "user://manual_edit.json"
	_panel.visible = false
	_panel.show_dialog()
	assert_eq(_panel._path_input.text, "user://manual_edit.json",
		"in-session manual edits should survive a hide/show cycle")


# ---------- Per-line diff (Phase 20) ----------

func test_diff_identical_inputs_marks_all_context():
	var marks: Dictionary = _panel._compute_line_diff(
		"a\nb\nc",
		"a\nb\nc")
	assert_eq((marks["before_marks"] as Array).size(), 3)
	assert_eq((marks["after_marks"] as Array).size(), 3)
	for m in (marks["before_marks"] as Array):
		assert_eq(str(m), "context",
			"identical inputs should produce no removals")
	for m in (marks["after_marks"] as Array):
		assert_eq(str(m), "context",
			"identical inputs should produce no additions")

func test_diff_pure_addition_at_end():
	# a, b, c → a, b, c, d
	var marks: Dictionary = _panel._compute_line_diff(
		"a\nb\nc",
		"a\nb\nc\nd")
	# All before lines are context.
	for m in (marks["before_marks"] as Array):
		assert_eq(str(m), "context")
	# After: first three context, last is added.
	var after: Array = marks["after_marks"] as Array
	assert_eq(str(after[0]), "context")
	assert_eq(str(after[1]), "context")
	assert_eq(str(after[2]), "context")
	assert_eq(str(after[3]), "added",
		"the new last line should be marked added")

func test_diff_pure_deletion_at_start():
	# a, b, c → b, c
	var marks: Dictionary = _panel._compute_line_diff(
		"a\nb\nc",
		"b\nc")
	var before: Array = marks["before_marks"] as Array
	assert_eq(str(before[0]), "removed",
		"the deleted leading line should be marked removed")
	assert_eq(str(before[1]), "context")
	assert_eq(str(before[2]), "context")
	for m in (marks["after_marks"] as Array):
		assert_eq(str(m), "context")

func test_diff_replacement_marks_both_sides():
	# a, b, c → a, X, c — line 1 changes
	var marks: Dictionary = _panel._compute_line_diff(
		"a\nb\nc",
		"a\nX\nc")
	var before: Array = marks["before_marks"] as Array
	var after: Array = marks["after_marks"] as Array
	assert_eq(str(before[0]), "context")
	assert_eq(str(before[1]), "removed",
		"the removed middle line should be marked removed")
	assert_eq(str(before[2]), "context")
	assert_eq(str(after[0]), "context")
	assert_eq(str(after[1]), "added",
		"the inserted middle line should be marked added")
	assert_eq(str(after[2]), "context")

func test_diff_empty_before():
	# "" → "x\ny"
	# Note: split("\n") on empty string returns [""], so before has 1
	# empty-string line. Treating an empty document as a single empty
	# line is consistent with how the TextEdit views render it.
	var marks: Dictionary = _panel._compute_line_diff("", "x\ny")
	assert_eq((marks["before_marks"] as Array).size(), 1)
	assert_eq((marks["after_marks"] as Array).size(), 2)
	assert_eq(str((marks["before_marks"] as Array)[0]), "removed",
		"the empty-string line in before becomes 'removed' when after has any content")
	for m in (marks["after_marks"] as Array):
		assert_eq(str(m), "added")

func test_diff_empty_after():
	var marks: Dictionary = _panel._compute_line_diff("x\ny", "")
	assert_eq((marks["after_marks"] as Array).size(), 1)
	assert_eq(str((marks["after_marks"] as Array)[0]), "added",
		"the empty-string line in after becomes 'added' when before has content")
	for m in (marks["before_marks"] as Array):
		assert_eq(str(m), "removed")

func test_word_diff_identical_inputs_returns_zero():
	var d: Dictionary = _panel._compute_word_diff(
		"the quick brown fox",
		"the quick brown fox")
	assert_eq(int(d["removed"]), 0,
		"identical inputs should produce no removed words")
	assert_eq(int(d["added"]), 0)
	assert_eq(int(d["common"]), 4)

func test_word_diff_pure_addition():
	var d: Dictionary = _panel._compute_word_diff(
		"hello",
		"hello world")
	assert_eq(int(d["removed"]), 0)
	assert_eq(int(d["added"]), 1,
		"only 'world' was added; common is 'hello'")
	assert_eq(int(d["common"]), 1)

func test_word_diff_pure_removal():
	var d: Dictionary = _panel._compute_word_diff(
		"alpha beta gamma",
		"alpha gamma")
	assert_eq(int(d["removed"]), 1,
		"'beta' was removed")
	assert_eq(int(d["added"]), 0)
	assert_eq(int(d["common"]), 2)

func test_word_diff_replacement():
	var d: Dictionary = _panel._compute_word_diff(
		"the cat sat on the mat",
		"the dog sat on the rug")
	# Common: the, sat, on, the (4)
	# Removed: cat, mat (2). Added: dog, rug (2).
	assert_eq(int(d["removed"]), 2)
	assert_eq(int(d["added"]), 2)
	assert_eq(int(d["common"]), 4)

func test_word_diff_empty_inputs():
	var d: Dictionary = _panel._compute_word_diff("", "")
	assert_eq(int(d["removed"]), 0)
	assert_eq(int(d["added"]), 0)
	assert_eq(int(d["common"]), 0)

func test_word_diff_handles_newlines_and_tabs():
	# Whitespace runs (newlines, tabs, multiple spaces) should
	# all behave as token separators.
	var d: Dictionary = _panel._compute_word_diff(
		"a\nb\tc  d",
		"a c d e")
	# Tokens before: a b c d. Tokens after: a c d e.
	# Common: a c d (3). Removed: b. Added: e.
	assert_eq(int(d["removed"]), 1)
	assert_eq(int(d["added"]), 1)
	assert_eq(int(d["common"]), 3)

func test_summary_includes_word_diff_when_content_changes():
	var before: Dictionary = _minimal_gdd()
	var after: Dictionary = before.duplicate(true)
	# Edit the goal field — a structural-summary "no change"
	# (entity counts unchanged) but a word-level "yes change".
	(after["core_loop"] as Dictionary)["goal"] = "totally different goal"
	var s: String = _panel._compute_diff_summary(before, after)
	assert_true("words: -" in s and "+" in s,
		"summary should append word-diff stats; got: %s" % s)


func test_diff_mixed_changes():
	# a, b, c, d → a, X, c, Y, d
	# Common: a, c, d. b removed; X, Y added.
	var marks: Dictionary = _panel._compute_line_diff(
		"a\nb\nc\nd",
		"a\nX\nc\nY\nd")
	var before: Array = marks["before_marks"] as Array
	var after: Array = marks["after_marks"] as Array
	# before: a context, b removed, c context, d context
	assert_eq(str(before[0]), "context")
	assert_eq(str(before[1]), "removed")
	assert_eq(str(before[2]), "context")
	assert_eq(str(before[3]), "context")
	# after: a context, X added, c context, Y added, d context
	assert_eq(str(after[0]), "context")
	assert_eq(str(after[1]), "added")
	assert_eq(str(after[2]), "context")
	assert_eq(str(after[3]), "added")
	assert_eq(str(after[4]), "context")


# ---------- Form-based edit (Phase 18) ----------

func test_edit_button_disabled_without_gdd():
	_panel.show_dialog()
	# No GDD loaded yet — Edit should be disabled.
	assert_true(_panel._edit_button.disabled,
		"Edit should be disabled until a GDD is loaded")

func test_edit_button_enabled_after_load():
	_load_minimal()
	assert_false(_panel._edit_button.disabled,
		"Edit should be enabled once a GDD is loaded")

func test_edit_press_enters_edit_mode():
	_load_minimal()
	watch_signals(_panel)
	_panel._on_edit_pressed()
	assert_signal_emitted(_panel, "edit_mode_entered")
	assert_true(_panel._edit_mode,
		"_edit_mode should flip true after entering edit")
	assert_true(_panel._edit_form.visible,
		"edit form should be visible in edit mode")
	# View-only widgets should be hidden.
	assert_false(_panel._summary_label.visible,
		"summary label should be hidden in edit mode")
	assert_false(_panel._entities_container.visible)
	assert_false(_panel._snapshots_container.visible)
	# Load button is disabled while editing — switching documents
	# mid-edit would lose the working buffer.
	assert_true(_panel._load_button.disabled)

func test_edit_save_writes_two_snapshots_and_returns_to_view():
	_load_minimal()
	_panel._on_edit_pressed()
	# Mutate the form a little.
	_panel._edit_form._title_input.text = "Edited via Form"
	# Pre-save: zero snapshots.
	assert_eq(_orch.gdd_manager.list_snapshots().size(), 0)
	watch_signals(_panel)
	_panel._edit_form._on_save_pressed()  # routes through _on_edit_form_saved
	assert_signal_emitted(_panel, "edit_saved")
	# Two snapshots — pre + post.
	var snaps: Array = _orch.gdd_manager.list_snapshots()
	assert_eq(snaps.size(), 2,
		"form save should produce a pre-state and post-state snapshot")
	# Disk reflects the new title.
	var loaded: Dictionary = _orch.gdd_manager.load_gdd(_panel._current_gdd_path)
	assert_eq(loaded["gdd"]["game_title"], "Edited via Form")
	# Panel returned to view mode.
	assert_false(_panel._edit_mode)
	assert_false(_panel._edit_form.visible)
	assert_true(_panel._summary_label.visible)

func test_edit_cancel_does_not_save():
	_load_minimal()
	_panel._on_edit_pressed()
	_panel._edit_form._title_input.text = "Should Be Discarded"
	watch_signals(_panel)
	_panel._edit_form._on_cancel_pressed()  # routes through _on_edit_form_cancelled
	assert_signal_emitted(_panel, "edit_cancelled")
	# No snapshots — Cancel doesn't write anything.
	assert_eq(_orch.gdd_manager.list_snapshots().size(), 0)
	# View mode restored, _current_gdd unchanged.
	assert_false(_panel._edit_mode)
	assert_eq(_panel._current_gdd["game_title"], "Test Game",
		"_current_gdd should be untouched on Cancel")

func test_edit_save_with_invalid_gdd_stays_in_edit_mode():
	# GDDManager.validate enforces id-prefix patterns (mech_*, asset_*,
	# etc). Type a mechanic id that violates the prefix rule and the
	# post-state save fails — but the user stays in edit mode so they
	# can correct it.
	_load_minimal()
	_panel._on_edit_pressed()
	var mechanics: Dictionary = _panel._edit_form._entity_sections["mechanics"]
	var first_row: Dictionary = (mechanics["rows"] as Array)[0]
	# Phase 32: row inputs live under "inputs" keyed by field name.
	(first_row["inputs"]["id"] as LineEdit).text = "wrong_prefix"
	watch_signals(_panel)
	_panel._edit_form._on_save_pressed()
	# Apply (post-state) save_gdd should have failed; edit_saved
	# signal not emitted.
	assert_signal_not_emitted(_panel, "edit_saved")
	# Status surfaces the failure.
	assert_true("save failed" in _panel._status_label.text,
		"validation failure should surface 'save failed'; got: %s"
			% _panel._status_label.text)
	# Stay in edit mode so user can correct.
	assert_true(_panel._edit_mode,
		"failed save should leave the user in edit mode to retry")


# ---------- Onboarding empty-state polish (Phase 38 / ADR 038) ----------

func test_create_starter_button_visible_when_no_gdd_loaded():
	_panel.show_dialog()
	# No GDD loaded yet — button should be visible (inverse of Edit / Export).
	assert_true(_panel._create_starter_button.visible,
		"Create-starter should surface when there's no GDD loaded")

func test_create_starter_button_hidden_after_load():
	_load_minimal()
	assert_false(_panel._create_starter_button.visible,
		"Create-starter should hide once a GDD is loaded")

func test_create_starter_writes_starter_gdd_to_typed_path():
	_panel.show_dialog()
	var path: String = "%s/starter_%d.json" % [_fixture_dir, randi() % 100000]
	_panel._path_input.text = path
	_panel._on_create_starter_pressed()
	assert_true(FileAccess.file_exists(path),
		"create-starter should write a valid GDD at the typed path")
	# Loaded into _current_gdd by the auto-load step.
	assert_false(_panel._current_gdd.is_empty(),
		"after create-starter, the panel should have the starter loaded")

func test_create_starter_refuses_to_clobber_existing_file():
	_panel.show_dialog()
	# Pre-write any file at the target path so create-starter sees it.
	var path: String = "%s/preexists_%d.json" % [_fixture_dir, randi() % 100000]
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	f.store_string("{}")
	f.close()
	_panel._path_input.text = path
	_panel._on_create_starter_pressed()
	# File was unchanged (we don't overwrite). Status surfaces a guiding message.
	assert_true("already" in _panel._status_label.text,
		"refusal should be surfaced; got: %s" % _panel._status_label.text)
	assert_true(_panel._current_gdd.is_empty(),
		"refusal path should not load the pre-existing file")

func test_create_starter_with_empty_path_surfaces_warning():
	_panel.show_dialog()
	_panel._path_input.text = ""
	_panel._on_create_starter_pressed()
	assert_true("path" in _panel._status_label.text,
		"empty-path case should remind user to type a path; got: %s"
			% _panel._status_label.text)

func test_entities_empty_state_hint_visible_without_gdd():
	_panel.show_dialog()
	# entities_container should have exactly one child — the hint label.
	assert_eq(_panel._entities_container.get_child_count(), 1,
		"entities container should hold a single hint label without a GDD")
	var hint: Node = _panel._entities_container.get_child(0)
	assert_true(hint is Label,
		"entities empty state should be a Label, not silent emptiness")

func test_entities_hint_replaced_by_rows_after_load():
	_load_minimal()
	# After load the container has one row per entity type (6).
	assert_eq(_panel._entities_container.get_child_count(),
		_panel._ENTITY_KEYS.size(),
		"after load, entity rows should replace the hint")


# ---------- Snapshot annotations + pair picker (Phase 39 / ADR 039) ----------

func _make_three_snapshots() -> String:
	# Save thrice — three snapshots v1/v2/v3 — so the pair picker has
	# enough data to flex.
	var g: Dictionary = _minimal_gdd()
	g["game_title"] = "First"
	var path: String = _write_gdd(g)
	_panel.show_dialog()
	_panel._path_input.text = path
	_panel._on_load_pressed()
	_orch.gdd_manager.save_gdd(g, path)  # v1
	g["game_title"] = "Second"
	_orch.gdd_manager.save_gdd(g, path)  # v2
	g["game_title"] = "Third"
	_orch.gdd_manager.save_gdd(g, path)  # v3
	_panel._on_load_pressed()
	return path

func test_snapshot_row_has_annotation_lineedit():
	_make_two_snapshots()
	# Snapshots container layout: pair picker (when ≥2 snapshots)
	# followed by one row per version. Each row is HBox: name_lbl,
	# note_input, compare_btn, rollback_btn.
	# Find the first row with a LineEdit child (skipping the picker row).
	var found_lineedit: bool = false
	for child in _panel._snapshots_container.get_children():
		if not (child is HBoxContainer):
			continue
		for sub in (child as HBoxContainer).get_children():
			if sub is LineEdit:
				found_lineedit = true
				break
		if found_lineedit:
			break
	assert_true(found_lineedit,
		"snapshot row should expose a LineEdit for the annotation")

func test_annotation_persists_after_commit():
	_make_two_snapshots()
	_panel._on_annotation_committed(1, "before stealth refactor")
	assert_eq(_orch.gdd_manager.get_snapshot_annotation(1),
		"before stealth refactor",
		"committed annotation should round-trip through gdd_manager")

func test_annotation_renders_in_subsequent_rebuild():
	_make_two_snapshots()
	_orch.gdd_manager.set_snapshot_annotation(1, "labelled v1")
	# Force the panel to re-render snapshots.
	_panel._render_snapshots()
	# Find v1's row and confirm its LineEdit text matches.
	var found_text: String = ""
	for child in _panel._snapshots_container.get_children():
		if not (child is HBoxContainer):
			continue
		# Skip rows that don't start with the version label; pair picker
		# starts with a "Compare:" label, real rows start with "vN".
		var hb := child as HBoxContainer
		if hb.get_child_count() == 0:
			continue
		var first_child: Node = hb.get_child(0)
		if not (first_child is Label):
			continue
		var version_text: String = (first_child as Label).text
		if version_text != "v1":
			continue
		# Find the LineEdit in this row.
		for sub in hb.get_children():
			if sub is LineEdit:
				found_text = (sub as LineEdit).text
				break
	assert_eq(found_text, "labelled v1",
		"annotation should pre-fill the LineEdit on rebuild")

func test_pair_picker_hidden_with_fewer_than_two_snapshots():
	_load_minimal()
	# Single save → one snapshot. Pair picker should not be in the
	# container (the gating check in _render_snapshots requires ≥2).
	_orch.gdd_manager.save_gdd(_minimal_gdd(), _panel._current_gdd_path)
	_panel._render_snapshots()
	assert_null(_panel._pair_picker_a,
		"pair picker shouldn't be built with only one snapshot")

func test_pair_picker_visible_with_two_or_more_snapshots():
	_make_two_snapshots()
	assert_not_null(_panel._pair_picker_a,
		"pair picker A dropdown should exist when ≥2 snapshots")
	assert_not_null(_panel._pair_picker_b,
		"pair picker B dropdown should exist when ≥2 snapshots")
	# Each dropdown should be populated with one entry per snapshot.
	assert_eq(_panel._pair_picker_a.item_count, 2)
	assert_eq(_panel._pair_picker_b.item_count, 2)

func test_pair_picker_default_is_oldest_to_newest():
	_make_three_snapshots()
	# A defaults to oldest (v1), B to newest (v3).
	var id_a: int = _panel._pair_picker_a.get_item_id(_panel._pair_picker_a.selected)
	var id_b: int = _panel._pair_picker_b.get_item_id(_panel._pair_picker_b.selected)
	assert_eq(id_a, 1, "picker A should default to oldest version")
	assert_eq(id_b, 3, "picker B should default to newest version")

func test_pair_compare_drives_snapshot_diff_section():
	_make_three_snapshots()
	# Default is v1 → v3. Click Diff.
	_panel._on_pair_compare_pressed()
	assert_true(_panel._snapshot_diff_section.visible,
		"pair compare should surface the snapshot-diff section")
	assert_true("v1" in _panel._snapshot_diff_header.text,
		"header should call out version A; got: %s" % _panel._snapshot_diff_header.text)
	assert_true("v3" in _panel._snapshot_diff_header.text,
		"header should call out version B; got: %s" % _panel._snapshot_diff_header.text)


# ---------- Snapshot Diff Viewer (Phase 35 / ADR 035) ----------

func _make_two_snapshots() -> String:
	# Save twice — each save creates a snapshot. Returns the JSON path
	# the panel was pointed at.
	var g: Dictionary = _minimal_gdd()
	g["game_title"] = "Initial"
	var path: String = _write_gdd(g)
	# Drive through the panel so _current_gdd / _current_gdd_path are
	# in sync after the second save.
	_panel.show_dialog()
	_panel._path_input.text = path
	_panel._on_load_pressed()
	# First save → snapshot v1.
	_orch.gdd_manager.save_gdd(g, path)
	# Mutate + save → snapshot v2.
	g["game_title"] = "Second Pass"
	_orch.gdd_manager.save_gdd(g, path)
	# Reload so _current_gdd reflects the latest disk state.
	_panel._on_load_pressed()
	return path

func test_snapshot_diff_section_starts_hidden():
	assert_false(_panel._snapshot_diff_section.visible,
		"snapshot-diff section should start hidden")

func test_compare_button_renders_diff():
	_make_two_snapshots()
	# v1 is the first snapshot — _current_gdd is "Second Pass" content.
	_panel._on_compare_pressed(1)
	assert_true(_panel._snapshot_diff_section.visible,
		"snapshot-diff section should surface on Compare")
	assert_true("Initial" in _panel._snapshot_diff_before_view.text,
		"before pane should show the v1 title")
	assert_true("Second Pass" in _panel._snapshot_diff_after_view.text,
		"after pane should show the current title")

func test_compare_summary_reports_line_counts():
	_make_two_snapshots()
	_panel._on_compare_pressed(1)
	var summary: String = _panel._snapshot_diff_summary_label.text
	assert_true("lines:" in summary,
		"summary should mention line count; got: %s" % summary)

func test_compare_header_includes_version():
	_make_two_snapshots()
	_panel._on_compare_pressed(2)
	assert_true("v2" in _panel._snapshot_diff_header.text,
		"header should call out which version we're comparing; got: %s"
			% _panel._snapshot_diff_header.text)

func test_compare_close_button_hides_section():
	_make_two_snapshots()
	_panel._on_compare_pressed(1)
	assert_true(_panel._snapshot_diff_section.visible)
	_panel._on_snapshot_diff_close_pressed()
	assert_false(_panel._snapshot_diff_section.visible,
		"Close should hide the snapshot-diff section")

func test_compare_without_loaded_gdd_does_not_crash():
	_panel.show_dialog()
	_panel._on_compare_pressed(1)
	# Status updates, no exception, section stays hidden.
	assert_false(_panel._snapshot_diff_section.visible,
		"section should stay hidden when there's nothing to compare to")
	assert_true("load a GDD" in _panel._status_label.text,
		"status should guide the user; got: %s" % _panel._status_label.text)

func test_compare_missing_snapshot_surfaces_error():
	_load_minimal()
	# No snapshots created — Compare for v99 should fail cleanly.
	_panel._on_compare_pressed(99)
	assert_false(_panel._snapshot_diff_section.visible,
		"section should NOT show for a failed compare")
	assert_true("Compare failed" in _panel._status_label.text,
		"status should report the failure; got: %s" % _panel._status_label.text)


# ---------- Export → Markdown (Phase 34 / ADR 034) ----------

func test_export_button_disabled_without_gdd():
	_panel.show_dialog()
	assert_true(_panel._export_button.disabled,
		"Export should be disabled until a GDD is loaded")

func test_export_button_enabled_after_load():
	_load_minimal()
	assert_false(_panel._export_button.disabled,
		"Export should be enabled once a GDD is loaded")

func test_export_press_writes_md_sibling():
	var json_path: String = _load_minimal()
	# Default export target = sibling .md next to the loaded JSON.
	_panel._on_export_pressed()
	var expected_md: String = "%s.md" % json_path.get_basename()
	assert_true(FileAccess.file_exists(expected_md),
		"Export should write a .md sibling at %s; status: %s"
			% [expected_md, _panel._status_label.text])

func test_export_status_reports_byte_count_and_path():
	var json_path: String = _load_minimal()
	_panel._on_export_pressed()
	assert_true("Exported" in _panel._status_label.text,
		"status should announce success; got: %s" % _panel._status_label.text)
	assert_true("bytes" in _panel._status_label.text,
		"status should mention byte count; got: %s" % _panel._status_label.text)

func test_export_persists_last_export_path():
	var json_path: String = _load_minimal()
	_panel._on_export_pressed()
	# Settings should now have gdd.last_export_path set to the .md sibling.
	var persisted: String = str(_orch.settings_manager.get_value(
		"gdd.last_export_path", ""))
	var expected_md: String = "%s.md" % json_path.get_basename()
	assert_eq(persisted, expected_md,
		"first export should persist its target as gdd.last_export_path")

func test_export_uses_persisted_path_on_subsequent_clicks():
	_load_minimal()
	# Pre-set a custom export path; the next Export should write there
	# instead of computing a sibling.
	var custom: String = "%s/custom_export_%d.md" % [
		_fixture_dir, randi() % 100000]
	_orch.settings_manager.set_value("gdd.last_export_path", custom)
	_panel._on_export_pressed()
	assert_true(FileAccess.file_exists(custom),
		"persisted path should win over the JSON sibling default")

func test_export_without_loaded_gdd_does_not_crash():
	# Defensive: even if someone surfaces export before a load
	# (shouldn't happen via the button, but the handler must
	# tolerate it).
	_panel.show_dialog()
	_panel._on_export_pressed()  # no crash; status label updates.
	assert_true("load a GDD" in _panel._status_label.text,
		"empty-GDD path should produce a guiding message; got: %s"
			% _panel._status_label.text)


# ---------- Cleanup helpers (copied from test_asset_manager) ----------

func _rm_rf(absolute_dir: String) -> void:
	if not DirAccess.dir_exists_absolute(absolute_dir):
		return
	var entries: Dictionary = _list_dir_entries(absolute_dir)
	for f in (entries.get("files", []) as Array):
		DirAccess.remove_absolute(f)
	for sd in (entries.get("dirs", []) as Array):
		_rm_rf(sd)
	DirAccess.remove_absolute(absolute_dir)

func _list_dir_entries(absolute_dir: String) -> Dictionary:
	var files: Array = []
	var dirs: Array = []
	var d: DirAccess = DirAccess.open(absolute_dir)
	if d == null:
		return {"files": files, "dirs": dirs}
	d.list_dir_begin()
	var name: String = d.get_next()
	while name != "":
		var child: String = absolute_dir.path_join(name)
		if d.current_is_dir():
			dirs.append(child)
		else:
			files.append(child)
		name = d.get_next()
	d.list_dir_end()
	return {"files": files, "dirs": dirs}
