# Structural tests for the UI shell. We don't render pixels — GUT runs
# headless. The goal is to verify:
#   - The shell builds its children.
#   - Panels bind to an Orchestrator without crashing.
#   - Signal hookups fire the right UI updates.
#
# We stand up an isolated Orchestrator instead of reaching for the
# /root/Orchestrator autoload. That keeps tests hermetic and lets us emit
# fake signals directly against each Orchestrator's own PluginManager /
# AssetManager.

extends GutTest

const MainShellScript = preload("res://scripts/ui/main_shell.gd")
const PluginPanelScript = preload("res://scripts/ui/plugin_panel.gd")
const GenerateFormScript = preload("res://scripts/ui/generate_form.gd")
const TaskListScript = preload("res://scripts/ui/task_list.gd")
const AssetGalleryScript = preload("res://scripts/ui/asset_gallery.gd")
const OrchestratorScript = preload("res://scripts/orchestrator.gd")


func _make_orch() -> Node:
	var orch: Node = OrchestratorScript.new()
	add_child_autofree(orch)
	# Pin AssetManager to a unique test root so we never touch real data.
	if orch.asset_manager != null:
		var test_root: String = "user://test_ui_assets_%d_%d" % [
			Time.get_ticks_msec(), randi() % 10000]
		orch.asset_manager.configure(test_root)
	return orch


# ---------- main_shell assembly ----------

func test_main_shell_builds_its_panels():
	var shell: Control = MainShellScript.new()
	add_child_autofree(shell)
	# _ready runs on add_child; panels should now exist.
	assert_not_null(shell.plugin_panel, "plugin_panel not built")
	assert_not_null(shell.generate_form, "generate_form not built")
	assert_not_null(shell.task_list, "task_list not built")
	assert_not_null(shell.asset_gallery, "asset_gallery not built")
	# Unlock dialog is built but starts hidden — only the autoload path
	# in _ready calls show_dialog(), and tests that bind their own orch
	# don't trigger that branch. Either way it should exist as a child.
	assert_not_null(shell.unlock_dialog, "unlock_dialog not built")
	# Credential editor overlay — same lifecycle as unlock_dialog. Stays
	# hidden until plugin_panel emits manage_credentials_requested.
	assert_not_null(shell.credential_editor, "credential_editor not built")
	# Asset preview overlay — same lifecycle, surfaced on a row click in
	# asset_gallery.
	assert_not_null(shell.asset_preview, "asset_preview not built")
	# Cost footer + Budget HUD (Phase 13). Footer is the always-visible
	# status bar at the bottom; HUD is a modal overlay.
	assert_not_null(shell.cost_footer, "cost_footer not built")
	assert_not_null(shell.budget_hud, "budget_hud not built")
	# GDD panel overlay (Phase 16). Surfaces from cost_footer's GDD
	# button; same hidden-by-default lifecycle.
	assert_not_null(shell.gdd_panel, "gdd_panel not built")
	# Scene panel overlay (Phase 23). Surfaces from cost_footer's
	# Scenes button or asset_preview's "Add to scene" affordance.
	assert_not_null(shell.scene_panel, "scene_panel not built")

func test_main_shell_binds_panels_to_orchestrator():
	var shell: Control = MainShellScript.new()
	add_child_autofree(shell)
	var orch: Node = _make_orch()
	shell.bind_orchestrator(orch)
	# After binding, generate_form should NOT be in "(no orchestrator)" state.
	# We peek at the internal dropdown.
	var dropdown: OptionButton = shell.generate_form._plugin_dropdown
	assert_not_null(dropdown)
	# Empty registered list → dropdown shows "(no plugins registered)".
	assert_gt(dropdown.get_item_count(), 0)


# ---------- plugin_panel ----------

func test_plugin_panel_lists_known_plugins():
	var orch: Node = _make_orch()
	var panel: Node = PluginPanelScript.new()
	add_child_autofree(panel)
	panel.bind(orch)
	# The registry ships with claude/elevenlabs/tripo/mock_3d/mock_audio.
	# Each of those should render a row. Rows with zero plugins would show
	# a single disabled placeholder, which we explicitly don't expect.
	var list: ItemList = panel._list
	assert_gt(list.item_count, 0, "no plugin rows rendered")

func test_plugin_panel_marks_registered_plugin_active():
	var orch: Node = _make_orch()
	orch.register_plugin_with_config("claude", {"api_key": "sk-ant-test"})
	var panel: Node = PluginPanelScript.new()
	add_child_autofree(panel)
	panel.bind(orch)
	# One of the rows should contain "[active] claude".
	var list: ItemList = panel._list
	var found: bool = false
	for i in range(list.item_count):
		if "[active]" in list.get_item_text(i) and "claude" in list.get_item_text(i):
			found = true
			break
	assert_true(found, "[active] claude row not found")

func test_plugin_panel_refreshes_on_eventbus_signal():
	# Regression test for: bind first, then register. The panel should
	# auto-refresh when EventBus.plugin_enabled fires — at the time the
	# signal arrives, plugin_manager state is in sync (orchestrator's
	# _registered is set later, so we deliberately query plugin_manager).
	var orch: Node = _make_orch()
	var panel: Node = PluginPanelScript.new()
	add_child_autofree(panel)
	panel.bind(orch)
	# At this point the panel rendered every plugin as [unregistered].
	orch.register_plugin_with_config("claude", {"api_key": "sk-ant-test"})
	# Signal emission is synchronous in Godot — but we yield a frame as
	# belt-and-braces in case any deferred call sneaks in.
	await get_tree().process_frame
	var list: ItemList = panel._list
	var found: bool = false
	for i in range(list.item_count):
		if "[active]" in list.get_item_text(i) and "claude" in list.get_item_text(i):
			found = true
			break
	assert_true(found,
		"panel didn't repaint to [active] claude after EventBus signal")


# ---------- generate_form ----------

func test_generate_form_populates_dropdown_from_orchestrator():
	var orch: Node = _make_orch()
	orch.register_plugin_with_config("claude", {"api_key": "sk-ant-x"})
	var form: Node = GenerateFormScript.new()
	add_child_autofree(form)
	form.bind(orch)
	var dropdown: OptionButton = form._plugin_dropdown
	# Dropdown should now have exactly one real entry (claude).
	assert_eq(dropdown.get_item_count(), 1)
	assert_eq(dropdown.get_item_text(0), "claude")
	assert_false(form._submit_button.disabled,
		"submit button should be enabled when a plugin is registered")

func test_generate_form_empty_dropdown_when_no_plugins():
	var orch: Node = _make_orch()
	var form: Node = GenerateFormScript.new()
	add_child_autofree(form)
	form.bind(orch)
	# Placeholder row, submit disabled.
	assert_true(form._submit_button.disabled,
		"submit button should be disabled with no registered plugins")

func test_generate_form_ctrl_enter_invokes_submit():
	# Phase 14: Ctrl+Enter on the prompt should fire the same code path
	# as clicking Generate. We verify by giving the form an empty prompt
	# and asserting the "prompt is empty" status text — that's reachable
	# only via _on_submit, so seeing it proves the keybind worked.
	var orch: Node = _make_orch()
	orch.register_plugin_with_config("claude", {"api_key": "sk-ant-test"})
	var form: Node = GenerateFormScript.new()
	add_child_autofree(form)
	form.bind(orch)
	form._prompt_input.text = ""  # explicit — no whitespace either
	var ev := InputEventKey.new()
	ev.keycode = KEY_ENTER
	ev.pressed = true
	ev.ctrl_pressed = true
	form._on_prompt_input(ev)
	assert_true("prompt is empty" in form._status_label.text,
		"Ctrl+Enter should route into _on_submit; got status: '%s'" % form._status_label.text)

func test_generate_form_param_form_populated_from_selected_plugin():
	# Phase 15: when a plugin is registered and selected, the param
	# form should reflect that plugin's schema. claude's schema
	# declares model / max_tokens / temperature / system / stop_sequences.
	# We just verify a couple of those keys land in _rows.
	var orch: Node = _make_orch()
	orch.register_plugin_with_config("claude", {"api_key": "sk-ant-test"})
	var form: Node = GenerateFormScript.new()
	add_child_autofree(form)
	form.bind(orch)
	# Dropdown auto-selected claude on add_item, refresh_plugins called
	# _refresh_param_form_for_selection, so the param form should now
	# carry claude's fields.
	var pf: Node = form._param_form
	assert_true(pf._rows.has("model"),
		"param form should include claude's 'model' field")
	assert_true(pf._rows.has("max_tokens"),
		"param form should include claude's 'max_tokens' field")

func test_generate_form_param_form_clears_when_no_plugins():
	# With nothing registered, the dropdown shows the disabled
	# placeholder row, _refresh_param_form_for_selection bails out via
	# the is_item_disabled branch, and the form clears any prior schema.
	var orch: Node = _make_orch()
	var form: Node = GenerateFormScript.new()
	add_child_autofree(form)
	form.bind(orch)
	var pf: Node = form._param_form
	assert_eq(pf._rows.size(), 0,
		"param form should be empty when no plugin is registered")

func test_generate_form_plain_enter_does_not_submit():
	# Plain Enter should be a TextEdit newline, not a submit. We verify
	# by checking the status label stays empty after a plain Enter event.
	var orch: Node = _make_orch()
	orch.register_plugin_with_config("claude", {"api_key": "sk-ant-test"})
	var form: Node = GenerateFormScript.new()
	add_child_autofree(form)
	form.bind(orch)
	form._prompt_input.text = ""
	var ev := InputEventKey.new()
	ev.keycode = KEY_ENTER
	ev.pressed = true
	ev.ctrl_pressed = false
	form._on_prompt_input(ev)
	assert_eq(form._status_label.text, "",
		"plain Enter should NOT trigger submit; status should stay empty")

func test_generate_form_refreshes_on_eventbus_signal():
	# Regression test: bind first (empty dropdown), then register.
	# The dropdown should pick up the new plugin via the EventBus
	# plugin_enabled signal, NOT just on initial bind.
	var orch: Node = _make_orch()
	var form: Node = GenerateFormScript.new()
	add_child_autofree(form)
	form.bind(orch)
	assert_true(form._submit_button.disabled, "precondition: no plugins yet")
	orch.register_plugin_with_config("claude", {"api_key": "sk-ant-test"})
	await get_tree().process_frame
	var dropdown: OptionButton = form._plugin_dropdown
	assert_eq(dropdown.get_item_count(), 1)
	assert_eq(dropdown.get_item_text(0), "claude")
	assert_false(form._submit_button.disabled,
		"submit should be enabled after plugin_enabled signal")


# ---------- task_list ----------

func test_task_list_creates_row_on_progress_signal():
	var orch: Node = _make_orch()
	var list: Node = TaskListScript.new()
	add_child_autofree(list)
	list.bind(orch)
	orch.plugin_manager.plugin_task_progress.emit(
		"claude", "claude:fake-1", 0.5, "half done")
	assert_true(list.has_row("claude:fake-1"))
	assert_eq(list.row_count(), 1)

func test_task_list_updates_row_on_completion():
	var orch: Node = _make_orch()
	var list: Node = TaskListScript.new()
	add_child_autofree(list)
	list.bind(orch)
	var tid: String = "claude:fake-2"
	orch.plugin_manager.plugin_task_progress.emit("claude", tid, 0.3, "")
	orch.plugin_manager.plugin_task_completed.emit(
		"claude", tid, {"asset_type": "text", "text": "hi"})
	assert_eq(list.row_count(), 1, "completion should update, not duplicate")
	# The row's modulate should now be "greenish" — value between red/green/blue.
	# We just assert it's not the default white.
	var row: Dictionary = list._rows[tid]
	assert_ne((row["row"] as Control).modulate, Color(1, 1, 1, 1),
		"row modulate not updated on completion")

func test_task_list_marks_failed_row_red():
	var orch: Node = _make_orch()
	var list: Node = TaskListScript.new()
	add_child_autofree(list)
	list.bind(orch)
	var tid: String = "claude:fake-3"
	orch.plugin_manager.plugin_task_failed.emit("claude", tid,
		{"code": "NETWORK", "message": "down"})
	assert_true(list.has_row(tid))
	var row: Dictionary = list._rows[tid]
	# Red tint has a high R channel.
	assert_gt((row["row"] as Control).modulate.r, 0.8)


# ---------- asset_gallery ----------

func test_asset_gallery_reflects_ingested_asset():
	var orch: Node = _make_orch()
	var gallery: Node = AssetGalleryScript.new()
	add_child_autofree(gallery)
	gallery.bind(orch)
	assert_eq(gallery.item_count(), 0)
	# Ingest one text asset via AssetManager directly.
	await orch.asset_manager.ingest("claude", "claude:x",
		{"asset_type": "text", "format": "plain", "text": "hello from test"},
		"say hi")
	# asset_ingested signal should have triggered gallery.refresh().
	assert_eq(gallery.item_count(), 1, "gallery didn't refresh on ingest")

func test_asset_gallery_filters_by_type():
	var orch: Node = _make_orch()
	var gallery: Node = AssetGalleryScript.new()
	add_child_autofree(gallery)
	gallery.bind(orch)
	await orch.asset_manager.ingest("claude", "t1",
		{"asset_type": "text", "format": "plain", "text": "a"})
	await orch.asset_manager.ingest("claude", "t2",
		{"asset_type": "text", "format": "plain", "text": "b"})
	assert_eq(gallery.item_count(), 2)
	# Switch filter to "audio" — neither row should appear.
	gallery._current_filter = "audio"
	gallery.refresh()
	assert_eq(gallery.item_count(), 0)

func test_asset_gallery_empty_when_unbound():
	var gallery: Node = AssetGalleryScript.new()
	add_child_autofree(gallery)
	# No bind() — item_count should be 0, not crash.
	assert_eq(gallery.item_count(), 0)
