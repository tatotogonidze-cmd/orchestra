# main_shell.gd
# Root Control of the Orchestrator UI. Hosts three panels side-by-side:
#
#   [ Plugin Panel ][ Generate Form + Task List ][ Asset Gallery ]
#
# The shell's sole responsibility is layout + wiring — it asks Orchestrator
# for its children (PluginManager, AssetManager), hands them to the panels,
# and gets out of the way. Each panel owns its own signal hookups.
#
# We build the tree programmatically rather than in a .tscn so that:
#   1. Everything is version-controlled as text (diffable).
#   2. Headless UI tests can instantiate the shell directly without the
#      editor's scene-packing pipeline.
#   3. Panel layout/sizing is one place to change.
#
# The Orchestrator autoload is expected at /root/Orchestrator. If absent
# (e.g. a test that stands the shell up in isolation) the panels stay in
# their "empty" state — they don't crash.

extends Control

const PluginPanelScript = preload("res://scripts/ui/plugin_panel.gd")
const GenerateFormScript = preload("res://scripts/ui/generate_form.gd")
const TaskListScript = preload("res://scripts/ui/task_list.gd")
const AssetGalleryScript = preload("res://scripts/ui/asset_gallery.gd")
const UnlockDialogScript = preload("res://scripts/ui/unlock_dialog.gd")
const CredentialEditorScript = preload("res://scripts/ui/credential_editor.gd")
const AssetPreviewScript = preload("res://scripts/ui/asset_preview.gd")
const CostFooterScript = preload("res://scripts/ui/cost_footer.gd")
const BudgetHudScript = preload("res://scripts/ui/budget_hud.gd")
const GddPanelScript = preload("res://scripts/ui/gdd_panel.gd")

# Direct references to the sub-panels so tests (and future UI code) can
# poke at them without walking the node tree by name.
var plugin_panel: Node
var generate_form: Node
var task_list: Node
var asset_gallery: Node
var unlock_dialog: Node
var credential_editor: Node
var asset_preview: Node
var cost_footer: Node
var budget_hud: Node
var gdd_panel: Node

# The Orchestrator instance we're bound to. Usually /root/Orchestrator;
# tests inject a fresh Orchestrator via `bind_orchestrator()`.
var _orch: Node = null


func _ready() -> void:
	_build_layout()
	# Fill the viewport.
	anchor_right = 1.0
	anchor_bottom = 1.0
	# Auto-bind to the autoload if one exists. Tests that pre-bind via
	# bind_orchestrator() skip this.
	if _orch == null:
		var tree: SceneTree = get_tree()
		if tree != null and tree.root != null and tree.root.has_node("Orchestrator"):
			var orch: Node = tree.root.get_node("Orchestrator")
			# Surface registration failures during the auto-register pass
			# below — without this hookup a plugin that initializes / health-
			# checks badly would just disappear silently from the dropdown.
			if orch.has_signal("plugin_registration_failed") \
					and not orch.plugin_registration_failed.is_connected(_on_registration_failed):
				orch.plugin_registration_failed.connect(_on_registration_failed)
			bind_orchestrator(orch)
			# Show the unlock dialog. The user types a master password and
			# we call orch.unlock_and_register(); on Skip we fall back to
			# env-vars only via register_all_available. Either path produces
			# the same downstream state — plugins registered, panels live.
			# Tests bypass this by binding their own Orchestrator (the
			# autoload branch isn't taken when bind_orchestrator was already
			# called externally).
			# bind_orchestrator already called unlock_dialog.bind(orch); we
			# only need to hook the dialog's outcome signals here, since
			# they're specific to the autoload-bootstrapped flow.
			if not unlock_dialog.unlocked.is_connected(_on_dialog_unlocked):
				unlock_dialog.unlocked.connect(_on_dialog_unlocked)
			if not unlock_dialog.skipped.is_connected(_on_dialog_skipped):
				unlock_dialog.skipped.connect(_on_dialog_skipped)
			unlock_dialog.show_dialog()


# ---------- Public API ----------

# Wire this shell to a specific Orchestrator instance. Called either by
# _ready() (autoload path) or by tests (isolated instance).
func bind_orchestrator(orch: Node) -> void:
	_orch = orch
	plugin_panel.bind(orch)
	generate_form.bind(orch)
	task_list.bind(orch)
	asset_gallery.bind(orch)
	# The two overlays don't render rows from orch state, so they don't
	# subscribe to anything in bind() — but they DO need the orch on hand
	# to call unlock_and_register / credential_store CRUD when the user
	# acts on them. We push it through the same path so callers don't
	# have to worry about wiring the overlays separately.
	unlock_dialog.bind(orch)
	credential_editor.bind(orch)
	asset_preview.bind(orch)
	# Footer + HUD bind directly to cost_tracker (a child of orch). They
	# don't need the full orchestrator surface — only the tracker — so
	# we hand them just that. Keeps each overlay's dependency surface
	# narrow.
	var tracker: Node = orch.cost_tracker if "cost_tracker" in orch else null
	cost_footer.bind(tracker)
	budget_hud.bind(tracker)
	if not cost_footer.hud_requested.is_connected(_on_hud_requested):
		cost_footer.hud_requested.connect(_on_hud_requested)
	if not cost_footer.lock_requested.is_connected(_on_lock_requested):
		cost_footer.lock_requested.connect(_on_lock_requested)
	if not cost_footer.gdd_requested.is_connected(_on_gdd_requested):
		cost_footer.gdd_requested.connect(_on_gdd_requested)
	gdd_panel.bind(orch)
	# Plugin panel "Manage credentials…" → open the editor. We connect
	# here (rather than in _build_layout) because the panel is a long-
	# lived child and we want the connection to point at THIS shell's
	# credential_editor instance even if bind_orchestrator is called
	# multiple times.
	if not plugin_panel.manage_credentials_requested.is_connected(_on_manage_credentials_requested):
		plugin_panel.manage_credentials_requested.connect(_on_manage_credentials_requested)
	# Editor → unlock_dialog: clicking "Unlock" inside the editor when
	# the store is locked re-shows the unlock dialog. Same handler chain
	# as a fresh launch — _on_dialog_unlocked logs diagnostics.
	if not credential_editor.unlock_requested.is_connected(_on_editor_unlock_requested):
		credential_editor.unlock_requested.connect(_on_editor_unlock_requested)
	# Editor saved → re-register plugins so any newly-saved api_key flips
	# its plugin to [active] without the user having to relaunch.
	if not credential_editor.saved.is_connected(_on_editor_saved):
		credential_editor.saved.connect(_on_editor_saved)
	# Asset gallery click → asset preview overlay.
	if not asset_gallery.asset_clicked.is_connected(_on_asset_clicked):
		asset_gallery.asset_clicked.connect(_on_asset_clicked)
	# Preview "Delete" → AssetManager.delete_asset. The gallery refreshes
	# itself off AssetManager.asset_deleted so we don't have to nudge it.
	if not asset_preview.delete_requested.is_connected(_on_preview_delete_requested):
		asset_preview.delete_requested.connect(_on_preview_delete_requested)


# ---------- Layout ----------

func _build_layout() -> void:
	# Outer VBox so the cost_footer can sit at the bottom while the
	# three-panel HBox takes the remaining vertical space. The shell
	# itself is anchored to fill the viewport and the VBox follows.
	var outer_vbox := VBoxContainer.new()
	outer_vbox.name = "OuterVBox"
	outer_vbox.anchor_right = 1.0
	outer_vbox.anchor_bottom = 1.0
	outer_vbox.add_theme_constant_override("separation", 0)
	add_child(outer_vbox)

	var hbox := HBoxContainer.new()
	hbox.name = "HBox"
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hbox.add_theme_constant_override("separation", 8)
	outer_vbox.add_child(hbox)

	# Left: plugin status panel (narrow sidebar).
	plugin_panel = PluginPanelScript.new()
	plugin_panel.name = "PluginPanel"
	plugin_panel.custom_minimum_size = Vector2(220, 0)
	hbox.add_child(plugin_panel)

	# Center: generate form on top, task list below, stacked in a VBox.
	var center_vbox := VBoxContainer.new()
	center_vbox.name = "CenterVBox"
	center_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(center_vbox)

	generate_form = GenerateFormScript.new()
	generate_form.name = "GenerateForm"
	center_vbox.add_child(generate_form)

	task_list = TaskListScript.new()
	task_list.name = "TaskList"
	task_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	center_vbox.add_child(task_list)

	# Right: asset gallery.
	asset_gallery = AssetGalleryScript.new()
	asset_gallery.name = "AssetGallery"
	asset_gallery.custom_minimum_size = Vector2(280, 0)
	hbox.add_child(asset_gallery)

	# Bottom: persistent cost footer. Fixed height (no v-expand) so it
	# always sits below the panel HBox.
	cost_footer = CostFooterScript.new()
	cost_footer.name = "CostFooter"
	cost_footer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer_vbox.add_child(cost_footer)

	# Modal overlay for credential-store unlock. Added LAST so it draws on
	# top of everything else and intercepts mouse input while visible.
	# Starts hidden — only the autoload path in _ready calls show_dialog().
	unlock_dialog = UnlockDialogScript.new()
	unlock_dialog.name = "UnlockDialog"
	unlock_dialog.anchor_right = 1.0
	unlock_dialog.anchor_bottom = 1.0
	add_child(unlock_dialog)

	# Credential editor overlay. Same shape as unlock_dialog (full-screen
	# Control with dim layer + centered panel). Starts hidden; the panel
	# panel's "Manage credentials…" button surfaces it on demand. Added
	# AFTER unlock_dialog so they don't fight for z-order if both happen
	# to be visible at the same instant — though normal flow only ever
	# shows one at a time.
	credential_editor = CredentialEditorScript.new()
	credential_editor.name = "CredentialEditor"
	credential_editor.anchor_right = 1.0
	credential_editor.anchor_bottom = 1.0
	add_child(credential_editor)

	# Asset preview overlay. Same modal shape; surfaces on row click in
	# asset_gallery.
	asset_preview = AssetPreviewScript.new()
	asset_preview.name = "AssetPreview"
	asset_preview.anchor_right = 1.0
	asset_preview.anchor_bottom = 1.0
	add_child(asset_preview)

	# Budget HUD overlay. Surfaces from the cost_footer's click /
	# "Budget HUD" button.
	budget_hud = BudgetHudScript.new()
	budget_hud.name = "BudgetHud"
	budget_hud.anchor_right = 1.0
	budget_hud.anchor_bottom = 1.0
	add_child(budget_hud)

	# GDD panel overlay. Read-only viewer for the Game Design Document;
	# surfaces from the cost_footer's "GDD" button.
	gdd_panel = GddPanelScript.new()
	gdd_panel.name = "GddPanel"
	gdd_panel.anchor_right = 1.0
	gdd_panel.anchor_bottom = 1.0
	add_child(gdd_panel)


# ---------- Diagnostics ----------

# When auto-register finishes with zero plugins, dump the env vars we saw
# so the user can tell at a glance whether it's a "no key set" problem or
# a "key was set but registration rejected it" problem. We deliberately
# only print the first 8 chars of any value — never the full key.
func _log_register_diagnostics(orch: Node) -> void:
	var registered: Array = orch.plugin_names() if orch.has_method("plugin_names") else []
	if registered.size() > 0:
		print("[main_shell] auto-registered plugins: %s" % str(registered))
		return
	print("[main_shell] no plugins auto-registered.")
	print("[main_shell] env vars visible to Godot (prefix-only):")
	for v in ["ANTHROPIC_API_KEY", "ELEVENLABS_API_KEY", "TRIPO_API_KEY"]:
		var val: String = OS.get_environment(v)
		if val.is_empty():
			print("  %s = (unset)" % v)
		else:
			var prefix: String = val.substr(0, 8) if val.length() > 8 else val
			print("  %s = %s... (len=%d)" % [v, prefix, val.length()])
	print("[main_shell] If a key shows (unset) but you set it in your shell,")
	print("[main_shell] the editor wasn't launched from that shell session.")
	print("[main_shell] Close the editor, then re-launch from the SAME PowerShell:")
	print("[main_shell]   $env:ANTHROPIC_API_KEY = \"sk-ant-...\"")
	print("[main_shell]   & \"C:\\Godot\\Godot_v4.6.2-stable_mono_win64.exe\" --path C:\\orchestra")

func _on_registration_failed(plugin_name: String, error: String) -> void:
	push_warning("[main_shell] plugin '%s' failed to register: %s" % [plugin_name, error])


# ---------- Dialog callbacks ----------

# Fired when the unlock dialog reports a successful unlock. unlock_and_register
# already registered every plugin reachable from the credential store + env
# vars, so we just log what landed.
func _on_dialog_unlocked(_registered: Array) -> void:
	if _orch != null:
		_log_register_diagnostics(_orch)

# Fired when the user dismisses the dialog without entering a password.
# Fall back to env-var-only registration so users who never want to manage
# the credential store can still drive the app.
func _on_dialog_skipped() -> void:
	if _orch == null:
		return
	if _orch.has_method("register_all_available"):
		_orch.call("register_all_available")
	_log_register_diagnostics(_orch)


# ---------- Credential editor wiring ----------

# Plugin panel "Manage credentials…" → show editor.
func _on_manage_credentials_requested() -> void:
	credential_editor.show_dialog()

# Editor's Unlock button (only present in the locked-store branch). We
# pop the unlock dialog. After it resolves the user can re-open the
# editor and see their saved keys.
func _on_editor_unlock_requested() -> void:
	# Hook the same outcome handlers used by the launch path. Guarded so
	# repeated unlocks don't stack duplicate connections.
	if not unlock_dialog.unlocked.is_connected(_on_dialog_unlocked):
		unlock_dialog.unlocked.connect(_on_dialog_unlocked)
	if not unlock_dialog.skipped.is_connected(_on_dialog_skipped):
		unlock_dialog.skipped.connect(_on_dialog_skipped)
	unlock_dialog.show_dialog()

# Editor saved → kick off another register pass. A previously-skipped or
# previously-unset plugin whose api_key was just saved should flip to
# [active] without forcing a relaunch.
func _on_editor_saved(_changed_plugins: Array) -> void:
	if _orch == null:
		return
	if _orch.has_method("register_all_available"):
		_orch.call("register_all_available")
	_log_register_diagnostics(_orch)


# ---------- Asset preview wiring ----------

# Asset gallery row clicked → show preview overlay.
func _on_asset_clicked(asset_id: String) -> void:
	asset_preview.show_for_asset(asset_id)

# Preview Delete → drive AssetManager. Gallery refresh is handled by the
# asset_deleted signal it already subscribes to in bind().
func _on_preview_delete_requested(asset_id: String) -> void:
	if _orch == null or _orch.asset_manager == null:
		return
	_orch.asset_manager.delete_asset(asset_id)


# ---------- Budget HUD wiring ----------

# Cost footer clicked → show the HUD modal.
func _on_hud_requested() -> void:
	budget_hud.show_dialog()

# "Lock now" pressed in the footer. Lock the credential store and pop
# the unlock dialog. We hook the dialog outcome handlers if they aren't
# already connected — same chain as the autoload boot path so that
# unlock-after-lock re-registers any plugins that were just dropped.
func _on_lock_requested() -> void:
	if _orch == null or _orch.credential_store == null:
		return
	_orch.credential_store.lock()
	if not unlock_dialog.unlocked.is_connected(_on_dialog_unlocked):
		unlock_dialog.unlocked.connect(_on_dialog_unlocked)
	if not unlock_dialog.skipped.is_connected(_on_dialog_skipped):
		unlock_dialog.skipped.connect(_on_dialog_skipped)
	unlock_dialog.show_dialog()

# "GDD" pressed in the footer → show the Game Design Document overlay.
func _on_gdd_requested() -> void:
	gdd_panel.show_dialog()
