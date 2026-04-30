# Tests for scene_panel.gd. We drive a real Orchestrator (so its
# scene_manager + asset_manager are reachable) and pre-populate
# scenes via the manager directly. UI assertions check that the
# panel surfaces the expected list / preview / actions; we don't
# render pixels — GUT runs headless, same idiom as the other
# overlay tests.

extends GutTest

const ScenePanelScript = preload("res://scripts/ui/scene_panel.gd")
const OrchestratorScript = preload("res://scripts/orchestrator.gd")

var _orch: Node
var _panel: Node
var _root: String


func before_each() -> void:
	_root = "user://_test_scene_panel_%d_%d" % [
		Time.get_ticks_msec(), randi() % 100000]
	_orch = OrchestratorScript.new()
	add_child_autofree(_orch)
	# Per-test isolation for both managers.
	_orch.scene_manager.configure("%s/scenes" % _root)
	_orch.asset_manager.configure("%s/assets" % _root)
	_panel = ScenePanelScript.new()
	add_child_autofree(_panel)
	_panel.bind(_orch)


func after_each() -> void:
	_rm_rf(ProjectSettings.globalize_path(_root))


# ---------- Build / structure ----------

func test_panel_builds_top_level_pieces():
	assert_not_null(_panel._scenes_list)
	assert_not_null(_panel._new_name_input)
	assert_not_null(_panel._new_scene_button)
	assert_not_null(_panel._scene_assets_list)
	assert_not_null(_panel._delete_scene_button)
	assert_not_null(_panel._close_button)

func test_panel_starts_hidden():
	assert_false(_panel.visible)

func test_delete_button_disabled_until_scene_selected():
	_panel.show_dialog()
	assert_true(_panel._delete_scene_button.disabled,
		"Delete should be disabled when nothing is selected")


# ---------- Scenes list ----------

func test_show_dialog_renders_existing_scenes():
	_orch.scene_manager.create_scene("Alpha", [], null)
	_orch.scene_manager.create_scene("Beta", [], null)
	_panel.show_dialog()
	assert_eq(_panel._scenes_list.item_count, 2,
		"both pre-existing scenes should appear in the list")
	assert_eq(_panel._scene_ids.size(), 2,
		"_scene_ids parallel array should match list length")

func test_empty_status_when_no_scenes():
	_panel.show_dialog()
	assert_true("No scenes yet" in _panel._status_label.text,
		"empty list should display the 'no scenes yet' hint; got: %s"
			% _panel._status_label.text)


# ---------- New scene flow ----------

func test_new_scene_with_blank_name_warns():
	_panel.show_dialog()
	_panel._new_name_input.text = ""
	_panel._on_new_scene_pressed()
	assert_true("name" in _panel._status_label.text.to_lower(),
		"blank name should warn; got: %s" % _panel._status_label.text)
	assert_eq(_orch.scene_manager.count(), 0)

func test_new_scene_creates_record_and_selects_it():
	_panel.show_dialog()
	_panel._new_name_input.text = "Made via panel"
	_panel._on_new_scene_pressed()
	assert_eq(_orch.scene_manager.count(), 1,
		"+ New should create a scene")
	assert_false(_panel._selected_scene_id.is_empty(),
		"newly-created scene should be auto-selected")
	# Input cleared for the next entry.
	assert_eq(_panel._new_name_input.text, "")


# ---------- Scene selection + preview ----------

func test_selecting_scene_populates_assets_list():
	# Stand up a real text asset (cheap — no fixture file needed).
	var r: Dictionary = await _orch.asset_manager.ingest(
		"claude", "claude:t",
		{"asset_type": "text", "format": "plain", "text": "x"}, "")
	var asset_id: String = str(r["asset_id"])
	var c: Dictionary = _orch.scene_manager.create_scene(
		"With one asset", [asset_id], _orch.asset_manager)
	_panel.show_dialog()
	# Simulate clicking the (only) scene row.
	_panel._on_scene_selected(0)
	assert_eq(_panel._selected_scene_id, str(c["scene_id"]))
	assert_eq(_panel._scene_assets_list.item_count, 1,
		"selecting a scene should list its assets")
	# Delete-scene button enabled once a scene is focused.
	assert_false(_panel._delete_scene_button.disabled)

func test_selecting_scene_with_missing_asset_marks_it_missing():
	# Create a scene referencing a non-existent asset_id (skipping
	# validation by passing null asset_manager).
	var c: Dictionary = _orch.scene_manager.create_scene(
		"With phantom", ["asset_phantom"], null)
	_panel.show_dialog()
	_panel._on_scene_selected(0)
	assert_eq(_panel._scene_assets_list.item_count, 1)
	# The label should call out the missing asset.
	assert_true("[missing]" in _panel._scene_assets_list.get_item_text(0),
		"deleted-asset references should be flagged as missing")


# ---------- Remove asset (double-click) ----------

func test_double_click_asset_removes_it_from_scene():
	var r: Dictionary = await _orch.asset_manager.ingest(
		"claude", "claude:t2",
		{"asset_type": "text", "format": "plain", "text": "y"}, "")
	var asset_id: String = str(r["asset_id"])
	var c: Dictionary = _orch.scene_manager.create_scene(
		"To prune", [asset_id], _orch.asset_manager)
	_panel.show_dialog()
	_panel._on_scene_selected(0)
	assert_eq(_panel._scene_assets_list.item_count, 1)
	# item_activated fires on double-click — we route it to the
	# remove handler.
	_panel._on_scene_asset_activated(0)
	# Manager state reflects the removal.
	var s: Dictionary = _orch.scene_manager.get_scene(c["scene_id"])
	assert_eq((s["asset_ids"] as Array).size(), 0)
	assert_eq(_panel._scene_assets_list.item_count, 0,
		"asset list should refresh after removal")


# ---------- Delete scene ----------

func test_delete_scene_removes_from_manager_and_list():
	_orch.scene_manager.create_scene("Doomed", [], null)
	_panel.show_dialog()
	_panel._on_scene_selected(0)
	watch_signals(_panel)
	_panel._on_delete_scene_pressed()
	assert_signal_emitted(_panel, "scene_deleted")
	assert_eq(_orch.scene_manager.count(), 0)
	assert_eq(_panel._scenes_list.item_count, 0)
	# Selection cleared, button re-disabled.
	assert_eq(_panel._selected_scene_id, "")
	assert_true(_panel._delete_scene_button.disabled)


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
	watch_signals(_panel)
	var ev := InputEventKey.new()
	ev.keycode = KEY_ESCAPE
	ev.pressed = true
	_panel._unhandled_input(ev)
	assert_signal_not_emitted(_panel, "closed")


# ---------- Cleanup helpers ----------

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
