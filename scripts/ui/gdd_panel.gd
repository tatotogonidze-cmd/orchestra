# gdd_panel.gd
# Modal overlay that surfaces the Game Design Document.
#
# Phase 16 shipped read-only viewing:
#   - Pick a path and Load a GDD from disk.
#   - See the top-level fields (game_title, genres, core_loop summary).
#   - See entity counts (mechanics / assets / tasks / scenes / chars /
#     dialogues), with a click-through reveal of each list.
#   - See the snapshot timeline and roll back to any prior version.
#
# Phase 17 added Claude chat-edit (ADR 017):
#   - Type a natural-language instruction ("add a stealth mechanic").
#   - We compose a prompt with the current GDD + schema + instruction and
#     dispatch through Orchestrator.generate("claude", ..., params).
#   - On task_completed we parse Claude's JSON reply, compute a small
#     diff summary, and show a side-by-side preview.
#   - Approve → snapshot the pre-state, then save_gdd the new state
#     (giving us two snapshots: the rollback target + the applied edit).
#   - Reject → drop the proposed GDD, the disk is untouched.
#
# Chat-edit state machine:
#   IDLE      → DISPATCHED  (Submit pressed)
#   DISPATCHED → PREVIEW    (parse succeeds)
#   DISPATCHED → IDLE       (parse fails — show error, allow retry)
#   PREVIEW   → IDLE        (Approve writes; Reject discards)
#
# Test hooks (same idiom as the other overlays):
#   - Layout: `_path_input`, `_load_button`, `_close_button`,
#     `_status_label`, `_summary_label`, `_entities_container`,
#     `_snapshots_container`.
#   - Chat-edit: `_chat_edit_input`, `_chat_edit_submit`,
#     `_chat_edit_status`, `_diff_section`, `_diff_summary_label`,
#     `_diff_before_view`, `_diff_after_view`, `_approve_button`,
#     `_reject_button`.
#   - State: `_current_gdd: Dictionary`, `_current_gdd_path: String`,
#     `_chat_edit_task_id: String`, `_pending_gdd: Dictionary`.
#   - Handlers: `_on_load_pressed`, `_on_close_pressed`,
#     `_on_chat_edit_submit_pressed`, `_on_chat_edit_completed`,
#     `_on_chat_edit_failed`, `_on_approve_pressed`,
#     `_on_reject_pressed`.

extends Control

const GddEditFormScript = preload("res://scripts/ui/gdd_edit_form.gd")

const _ENTITY_KEYS: Array = [
	"mechanics", "assets", "tasks", "scenes", "characters", "dialogues",
]

signal closed()
signal gdd_loaded(path: String)
signal rollback_performed(version: int)
signal chat_edit_dispatched(task_id: String)
signal chat_edit_applied(version: int)
signal chat_edit_rejected()
# Phase 18: form-based edit signals.
signal edit_mode_entered()
signal edit_saved(version: int)
signal edit_cancelled()

var _orch: Node = null

# Top-level layout pieces.
var _panel: PanelContainer
var _vbox: VBoxContainer
var _header_label: Label
var _path_input: LineEdit
var _load_button: Button
var _edit_button: Button
var _status_label: Label
# Phase 29 (ADR 029): "Auto-fix" affordance, visible only when the
# currently-loaded GDD has dangling cross-references. One click runs
# clean_dangling_references + save_gdd.
var _autofix_button: Button
var _summary_label: Label
var _entities_container: VBoxContainer
var _snapshots_header: Label
var _snapshots_container: VBoxContainer
var _close_button: Button

# Phase 18: form-based edit. The form is its own sub-component and is
# hidden by default; entering edit mode shows it and hides the
# view-only sections so the panel doesn't double up on the same
# information.
var _edit_form: Node
# Wrapper around the view-only widgets we need to hide in edit mode.
# Built from the existing children — see _build_view_section_handles.
var _view_only_nodes: Array = []
var _edit_mode: bool = false

# Chat-edit section (Phase 17). Always built; visibility gated on
# whether a GDD is loaded AND claude is registered.
var _chat_edit_section: VBoxContainer
var _chat_edit_input: TextEdit
var _chat_edit_submit: Button
var _chat_edit_status: Label

# Diff preview section (Phase 17). Built once; shown only while a
# pending chat-edit awaits Approve / Reject.
var _diff_section: VBoxContainer
var _diff_summary_label: Label
var _diff_before_view: TextEdit
var _diff_after_view: TextEdit
var _approve_button: Button
var _reject_button: Button

# Last loaded GDD. Empty dict when nothing has been loaded yet (or after
# a load failure). Tests poke at this directly to verify the load
# pipeline.
var _current_gdd: Dictionary = {}

# Path we loaded from. Approve writes back to this path so the chat-edit
# replaces the same file the user opened.
var _current_gdd_path: String = ""

# Active chat-edit task — non-empty between Submit and the matching
# task_completed / task_failed. Lets us ignore unrelated Claude task
# signals (other features could dispatch claude calls; we only react to
# our own).
var _chat_edit_task_id: String = ""

# Proposed GDD coming back from Claude. Empty when we're not in PREVIEW.
var _pending_gdd: Dictionary = {}

# Phase 31 (ADR 031): conversation-mode chat-edit. Tracks how many
# turns have been dispatched in the current refinement session. 0 =
# no edit in flight. 1+ = user submitted at least once. Reset on
# Approve / Reject. Surfaced in the status banner ("turn 2: editing…")
# so the user can see they're in a refinement loop.
var _conversation_turn: int = 0

# Path the user typed. Default points at the conventional location;
# users can override before clicking Load.
const DEFAULT_PATH: String = "user://gdd.json"

# Phase 24: persist the last successfully-loaded path so the next
# show_dialog prefills it. The setting key lives under the gdd
# namespace so it doesn't collide with other subsystems.
const SETTING_LAST_PATH: String = "gdd.last_path"

# Tight params for the chat-edit dispatch. Low temperature so Claude
# doesn't reinterpret existing fields creatively; high enough max_tokens
# to fit a reasonably large GDD.
const _CHAT_EDIT_PARAMS: Dictionary = {
	"max_tokens": 4096,
	"temperature": 0.2,
	"system": "You are a game design assistant editing a structured Game Design Document. Apply the requested edit precisely. Return ONLY the updated JSON document. No prose, no code fences, no commentary.",
}


func _ready() -> void:
	anchor_right = 1.0
	anchor_bottom = 1.0
	mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.anchor_right = 1.0
	dim.anchor_bottom = 1.0
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(620, 0)
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
	_header_label.text = "Game Design Document"
	_header_label.add_theme_font_size_override("font_size", 18)
	_vbox.add_child(_header_label)

	# Path input + Load button row.
	var path_row := HBoxContainer.new()
	path_row.add_theme_constant_override("separation", 6)
	_vbox.add_child(path_row)

	var path_label := Label.new()
	path_label.text = "Path:"
	path_row.add_child(path_label)

	_path_input = LineEdit.new()
	_path_input.text = DEFAULT_PATH
	_path_input.placeholder_text = DEFAULT_PATH
	_path_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	path_row.add_child(_path_input)

	_load_button = Button.new()
	_load_button.text = "Load"
	_load_button.pressed.connect(_on_load_pressed)
	path_row.add_child(_load_button)

	# Edit button (Phase 18) — toggles into form-based edit mode. Disabled
	# until a GDD is loaded; refresh updates this state.
	_edit_button = Button.new()
	_edit_button.text = "Edit"
	_edit_button.tooltip_text = "Open the form-based editor"
	_edit_button.disabled = true
	_edit_button.pressed.connect(_on_edit_pressed)
	path_row.add_child(_edit_button)

	# Status / error feedback. The Auto-fix button (Phase 29 / ADR
	# 029) sits next to the label and surfaces only when the loaded
	# GDD has cross-reference issues — a click runs
	# clean_dangling_references + save_gdd.
	var status_row := HBoxContainer.new()
	status_row.add_theme_constant_override("separation", 6)
	_vbox.add_child(status_row)

	_status_label = Label.new()
	_status_label.text = "(no GDD loaded yet)"
	_status_label.modulate = Color(0.85, 0.85, 0.85, 1.0)
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_row.add_child(_status_label)

	_autofix_button = Button.new()
	_autofix_button.text = "Auto-fix"
	_autofix_button.tooltip_text = "Remove dangling cross-references and save the cleaned GDD"
	_autofix_button.visible = false
	_autofix_button.pressed.connect(_on_autofix_pressed)
	status_row.add_child(_autofix_button)

	# Summary of top-level fields. Single Label, multi-line.
	_summary_label = Label.new()
	_summary_label.text = ""
	_summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_vbox.add_child(_summary_label)

	# Entity rows (one per entity type, with a count).
	var entities_header := Label.new()
	entities_header.text = "Entities"
	entities_header.add_theme_font_size_override("font_size", 14)
	_vbox.add_child(entities_header)

	_entities_container = VBoxContainer.new()
	_entities_container.add_theme_constant_override("separation", 4)
	_vbox.add_child(_entities_container)

	# Snapshot timeline.
	_snapshots_header = Label.new()
	_snapshots_header.text = "Snapshots"
	_snapshots_header.add_theme_font_size_override("font_size", 14)
	_vbox.add_child(_snapshots_header)

	_snapshots_container = VBoxContainer.new()
	_snapshots_container.add_theme_constant_override("separation", 4)
	_vbox.add_child(_snapshots_container)

	# ---------- Phase 17: chat-edit section ----------
	_chat_edit_section = VBoxContainer.new()
	_chat_edit_section.add_theme_constant_override("separation", 6)
	_vbox.add_child(_chat_edit_section)

	var chat_header := Label.new()
	chat_header.text = "Chat-edit"
	chat_header.add_theme_font_size_override("font_size", 14)
	_chat_edit_section.add_child(chat_header)

	_chat_edit_input = TextEdit.new()
	_chat_edit_input.placeholder_text = "describe the change… e.g. \"add a stealth mechanic\""
	_chat_edit_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_edit_input.custom_minimum_size = Vector2(0, 60)
	_chat_edit_section.add_child(_chat_edit_input)

	var chat_row := HBoxContainer.new()
	chat_row.alignment = BoxContainer.ALIGNMENT_END
	_chat_edit_section.add_child(chat_row)

	_chat_edit_status = Label.new()
	_chat_edit_status.text = ""
	_chat_edit_status.modulate = Color(0.7, 0.7, 0.7, 1.0)
	_chat_edit_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chat_row.add_child(_chat_edit_status)

	_chat_edit_submit = Button.new()
	_chat_edit_submit.text = "Submit"
	_chat_edit_submit.tooltip_text = "Send to Claude with the current GDD + schema as context"
	_chat_edit_submit.pressed.connect(_on_chat_edit_submit_pressed)
	chat_row.add_child(_chat_edit_submit)

	# ---------- Phase 17: diff preview section ----------
	# Built once; shown only when _pending_gdd is non-empty.
	_diff_section = VBoxContainer.new()
	_diff_section.add_theme_constant_override("separation", 6)
	_vbox.add_child(_diff_section)

	var diff_header := Label.new()
	diff_header.text = "Proposed change"
	diff_header.add_theme_font_size_override("font_size", 14)
	_diff_section.add_child(diff_header)

	_diff_summary_label = Label.new()
	_diff_summary_label.text = ""
	_diff_summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_diff_section.add_child(_diff_summary_label)

	var diff_panes := HBoxContainer.new()
	diff_panes.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	diff_panes.add_theme_constant_override("separation", 6)
	_diff_section.add_child(diff_panes)

	var before_box := VBoxContainer.new()
	before_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	diff_panes.add_child(before_box)
	var before_label := Label.new()
	before_label.text = "Before"
	before_label.modulate = Color(0.7, 0.7, 0.7, 1.0)
	before_box.add_child(before_label)
	_diff_before_view = TextEdit.new()
	_diff_before_view.editable = false
	_diff_before_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_diff_before_view.custom_minimum_size = Vector2(0, 200)
	before_box.add_child(_diff_before_view)

	var after_box := VBoxContainer.new()
	after_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	diff_panes.add_child(after_box)
	var after_label := Label.new()
	after_label.text = "After"
	after_label.modulate = Color(0.7, 0.7, 0.7, 1.0)
	after_box.add_child(after_label)
	_diff_after_view = TextEdit.new()
	_diff_after_view.editable = false
	_diff_after_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_diff_after_view.custom_minimum_size = Vector2(0, 200)
	after_box.add_child(_diff_after_view)

	var diff_actions := HBoxContainer.new()
	diff_actions.alignment = BoxContainer.ALIGNMENT_END
	diff_actions.add_theme_constant_override("separation", 8)
	_diff_section.add_child(diff_actions)

	_reject_button = Button.new()
	_reject_button.text = "Reject"
	_reject_button.pressed.connect(_on_reject_pressed)
	diff_actions.add_child(_reject_button)

	_approve_button = Button.new()
	_approve_button.text = "Approve"
	_approve_button.tooltip_text = "Snapshot the current state, then save the proposed GDD"
	_approve_button.pressed.connect(_on_approve_pressed)
	diff_actions.add_child(_approve_button)

	_diff_section.visible = false  # hidden until a chat-edit lands

	# ---------- Phase 18: form-based edit ----------
	# The form lives at the bottom of the vbox. While in edit mode we
	# hide the view-only widgets above so the panel doesn't display
	# the same data twice.
	_edit_form = GddEditFormScript.new()
	_edit_form.visible = false
	_edit_form.saved.connect(_on_edit_form_saved)
	_edit_form.cancelled.connect(_on_edit_form_cancelled)
	_vbox.add_child(_edit_form)

	# Capture the view-only widgets we want to toggle as a group when
	# entering / leaving edit mode. We build this list AFTER everything
	# is in the tree so we don't have to keep updating it as we add
	# new view widgets.
	_view_only_nodes = [
		_summary_label,
		_entities_container,
		_snapshots_header,
		_snapshots_container,
		_chat_edit_section,
		_diff_section,
	]

	# Footer.
	var footer := HBoxContainer.new()
	footer.alignment = BoxContainer.ALIGNMENT_END
	_vbox.add_child(footer)

	_close_button = Button.new()
	_close_button.text = "Close"
	_close_button.pressed.connect(_on_close_pressed)
	footer.add_child(_close_button)

	visible = false


# ---------- Public API ----------

func bind(orch: Node) -> void:
	_orch = orch
	# Subscribe to PluginManager's task signals so we can pick up our
	# own chat-edit task's completion. We filter to our task id inside
	# the handler, so other Claude calls in the app don't trigger
	# diff previews.
	if orch != null and orch.plugin_manager != null:
		var pm: Node = orch.plugin_manager
		if pm.has_signal("plugin_task_completed") \
				and not pm.plugin_task_completed.is_connected(_on_chat_edit_completed):
			pm.plugin_task_completed.connect(_on_chat_edit_completed)
		if pm.has_signal("plugin_task_failed") \
				and not pm.plugin_task_failed.is_connected(_on_chat_edit_failed):
			pm.plugin_task_failed.connect(_on_chat_edit_failed)

func show_dialog() -> void:
	# Phase 24: prefill the path input from the last-used path if we
	# haven't loaded anything yet this session. We only override the
	# default — user mid-edit input is preserved across show/hide.
	if _current_gdd_path.is_empty():
		var saved: String = _read_last_path()
		if not saved.is_empty():
			_path_input.text = saved
	# Always refresh on open — the snapshot timeline can change between
	# views (a chat-edit flow that lands while the panel was closed,
	# etc) and we want to reflect it.
	_refresh()
	visible = true

# Helper: read the persisted last-used path, if any. Returns "" when
# settings_manager is unavailable or the setting is unset.
func _read_last_path() -> String:
	if _orch == null or not ("settings_manager" in _orch):
		return ""
	var settings: Node = _orch.settings_manager
	if settings == null or not settings.has_method("get_value"):
		return ""
	return str(settings.call("get_value", SETTING_LAST_PATH, ""))

func _persist_last_path(path: String) -> void:
	if _orch == null or not ("settings_manager" in _orch):
		return
	var settings: Node = _orch.settings_manager
	if settings == null or not settings.has_method("set_value"):
		return
	settings.call("set_value", SETTING_LAST_PATH, path)


# ---------- Internals ----------

func _refresh() -> void:
	_render_summary()
	_render_entities()
	_render_snapshots()
	_refresh_chat_edit_visibility()
	# Edit button is enabled only when there's a GDD to edit.
	_edit_button.disabled = _current_gdd.is_empty()

# Chat-edit is only meaningful when (a) we have a GDD loaded so there's
# something to edit, AND (b) the claude plugin is registered so we have
# something to dispatch to. Otherwise we hide the section entirely
# rather than show a permanently-disabled affordance.
func _refresh_chat_edit_visibility() -> void:
	if _chat_edit_section == null:
		return
	var has_gdd: bool = not _current_gdd.is_empty()
	var has_claude: bool = _is_claude_registered()
	_chat_edit_section.visible = has_gdd and has_claude
	# Phase 31 (ADR 031): Submit is disabled ONLY mid-flight. PREVIEW
	# state (has_pending) keeps Submit enabled so the user can refine
	# the proposal in subsequent turns instead of having to Approve /
	# Reject first.
	var in_flight: bool = not _chat_edit_task_id.is_empty()
	var has_pending: bool = not _pending_gdd.is_empty()
	_chat_edit_submit.disabled = in_flight
	if has_pending and not in_flight:
		_chat_edit_status.text = "preview shown — type a refinement and Submit, or Approve / Reject"
	elif in_flight:
		_chat_edit_status.text = "turn %d: editing… task %s" % [
			_conversation_turn, _chat_edit_task_id]
	elif has_gdd and not has_claude:
		# Section is hidden, but if it ever becomes visible the status
		# is still meaningful.
		_chat_edit_status.text = "claude plugin not registered"
	else:
		_chat_edit_status.text = ""

func _is_claude_registered() -> bool:
	if _orch == null or _orch.plugin_manager == null:
		return false
	var pm: Node = _orch.plugin_manager
	if not ("active_plugins" in pm):
		return false
	return (pm.active_plugins as Dictionary).has("claude")

func _render_summary() -> void:
	if _current_gdd.is_empty():
		_summary_label.text = ""
		return
	var lines: Array = []
	var title: String = str(_current_gdd.get("game_title", ""))
	if not title.is_empty():
		lines.append("Title: %s" % title)
	var genres = _current_gdd.get("genres", [])
	if genres is Array and (genres as Array).size() > 0:
		lines.append("Genres: %s" % ", ".join(genres))
	var loop = _current_gdd.get("core_loop", {})
	if loop is Dictionary and not (loop as Dictionary).is_empty():
		var goal: String = str((loop as Dictionary).get("goal", ""))
		if not goal.is_empty():
			lines.append("Core loop: %s" % goal)
	var meta = _current_gdd.get("metadata", {})
	if meta is Dictionary:
		var version: String = str((meta as Dictionary).get("document_version", ""))
		if not version.is_empty():
			lines.append("Document version: %s" % version)
	_summary_label.text = "\n".join(lines)

func _render_entities() -> void:
	# Free old rows immediately (same orphan-tracker discipline as the
	# other overlay rebuilders).
	for child in _entities_container.get_children():
		_entities_container.remove_child(child)
		child.free()
	if _current_gdd.is_empty():
		return
	for key in _ENTITY_KEYS:
		var arr = _current_gdd.get(key, [])
		var count: int = (arr as Array).size() if arr is Array else 0
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var name_lbl := Label.new()
		name_lbl.text = key
		name_lbl.custom_minimum_size = Vector2(120, 0)
		row.add_child(name_lbl)
		var count_lbl := Label.new()
		count_lbl.text = "%d" % count
		count_lbl.modulate = Color(0.7, 0.85, 1.0, 1.0) if count > 0 else Color(0.5, 0.5, 0.5, 1.0)
		row.add_child(count_lbl)
		_entities_container.add_child(row)

func _render_snapshots() -> void:
	for child in _snapshots_container.get_children():
		_snapshots_container.remove_child(child)
		child.free()
	if _orch == null or _orch.gdd_manager == null:
		return
	var snapshots: Array = _orch.gdd_manager.list_snapshots()
	if snapshots.is_empty():
		var empty := Label.new()
		empty.text = "(no snapshots)"
		empty.modulate = Color(0.5, 0.5, 0.5, 1.0)
		_snapshots_container.add_child(empty)
		return
	# Sort by version descending — newest first.
	snapshots.sort_custom(func(a, b) -> bool:
		return int(a.get("version", 0)) > int(b.get("version", 0)))
	for s in snapshots:
		var version: int = int(s.get("version", 0))
		var path: String = str(s.get("path", ""))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var name_lbl := Label.new()
		name_lbl.text = "v%d" % version
		name_lbl.custom_minimum_size = Vector2(60, 0)
		row.add_child(name_lbl)
		var path_lbl := Label.new()
		path_lbl.text = path
		path_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		path_lbl.modulate = Color(0.7, 0.7, 0.7, 1.0)
		row.add_child(path_lbl)
		var rollback_btn := Button.new()
		rollback_btn.text = "Rollback"
		rollback_btn.tooltip_text = "Restore this snapshot to disk"
		rollback_btn.pressed.connect(func() -> void:
			_on_rollback_pressed(version))
		row.add_child(rollback_btn)
		_snapshots_container.add_child(row)


# ---------- Handlers ----------

func _on_load_pressed() -> void:
	if _orch == null or _orch.gdd_manager == null:
		_status_label.text = "no orchestrator bound (internal error)"
		_status_label.modulate = Color(1.0, 0.45, 0.45, 1.0)
		return
	var path: String = _path_input.text.strip_edges()
	if path.is_empty():
		_status_label.text = "path required"
		_status_label.modulate = Color(1.0, 0.45, 0.45, 1.0)
		return
	var result: Dictionary = _orch.gdd_manager.load_gdd(path)
	if not bool(result.get("success", false)):
		_current_gdd = {}
		_current_gdd_path = ""
		_status_label.text = "load failed: %s" % str(result.get("error", "unknown"))
		_status_label.modulate = Color(1.0, 0.45, 0.45, 1.0)
		_refresh()
		return
	_current_gdd = (result.get("gdd", {}) as Dictionary).duplicate(true)
	_current_gdd_path = path
	# Phase 24: persist the loaded path so the next show_dialog opens
	# pre-filled. Validation may still flag issues — we save the path
	# regardless because what the user wanted to load is what they
	# should see next time.
	_persist_last_path(path)
	# Surface validation issues without blocking the view — even an
	# invalid GDD is useful to look at.
	var v: Dictionary = _orch.gdd_manager.validate(_current_gdd)
	if bool(v.get("valid", false)):
		_status_label.text = "Loaded: %s" % path
		_status_label.modulate = Color(0.5, 0.9, 0.5, 1.0)
	else:
		var errors: Array = v.get("errors", []) as Array
		_status_label.text = "Loaded with %d validation issue(s): %s" % [
			errors.size(),
			", ".join(errors.slice(0, min(3, errors.size())))]
		_status_label.modulate = Color(1.0, 0.7, 0.2, 1.0)
	# A fresh load wipes any pending chat-edit — the diff would be
	# meaningful only against the GDD we computed it from.
	_clear_pending_edit()
	# Phase 29: surface Auto-fix only when we can actually fix
	# something. Probe the GDD for dangling refs WITHOUT mutating —
	# clean_dangling_references is a pure function so we just check
	# the count.
	_refresh_autofix_visibility()
	_refresh()
	emit_signal("gdd_loaded", path)

# Probe the loaded GDD for dangling cross-refs and toggle the
# Auto-fix button visibility accordingly. Re-probes after every
# load / rollback / chat-edit-applied / form-save.
func _refresh_autofix_visibility() -> void:
	if _autofix_button == null:
		return
	if _orch == null or _orch.gdd_manager == null \
			or _current_gdd.is_empty():
		_autofix_button.visible = false
		return
	var preview: Dictionary = _orch.gdd_manager.clean_dangling_references(_current_gdd)
	var n: int = int(preview.get("removed_count", 0))
	if n > 0:
		_autofix_button.text = "Auto-fix (%d)" % n
		_autofix_button.visible = true
	else:
		_autofix_button.visible = false

# Auto-fix click handler. Runs clean_dangling_references on the
# currently-loaded GDD, then save_gdd to commit the cleaned version
# (which also creates a fresh snapshot — same rollback discipline
# as every other write).
func _on_autofix_pressed() -> void:
	if _orch == null or _orch.gdd_manager == null:
		return
	if _current_gdd.is_empty() or _current_gdd_path.is_empty():
		return
	var cleaned: Dictionary = _orch.gdd_manager.clean_dangling_references(_current_gdd)
	if not bool(cleaned.get("success", false)):
		_status_label.text = "Auto-fix failed: %s" % str(cleaned.get("error", "unknown"))
		_status_label.modulate = Color(1.0, 0.45, 0.45, 1.0)
		return
	var n: int = int(cleaned.get("removed_count", 0))
	var new_gdd: Dictionary = cleaned["gdd"] as Dictionary
	var save: Dictionary = _orch.gdd_manager.save_gdd(new_gdd, _current_gdd_path)
	if not bool(save.get("success", false)):
		_status_label.text = "Auto-fix save failed: %s" % str(save.get("error", "unknown"))
		_status_label.modulate = Color(1.0, 0.45, 0.45, 1.0)
		return
	_current_gdd = new_gdd
	_status_label.text = "Auto-fix removed %d dangling reference(s)" % n
	_status_label.modulate = Color(0.5, 0.9, 0.5, 1.0)
	_refresh_autofix_visibility()
	_refresh()

func _on_rollback_pressed(version: int) -> void:
	if _orch == null or _orch.gdd_manager == null:
		return
	var result: Dictionary = _orch.gdd_manager.rollback(version)
	if bool(result.get("success", false)):
		_status_label.text = "Rolled back to v%d" % version
		_status_label.modulate = Color(0.5, 0.9, 0.5, 1.0)
		# Refresh from the rollback target — the caller of rollback()
		# is responsible for re-reading; we just reflect what was returned.
		if result.has("gdd") and result["gdd"] is Dictionary:
			_current_gdd = (result["gdd"] as Dictionary).duplicate(true)
		_refresh()
		emit_signal("rollback_performed", version)
	else:
		_status_label.text = "Rollback failed: %s" % str(result.get("error", "unknown"))
		_status_label.modulate = Color(1.0, 0.45, 0.45, 1.0)

func _on_close_pressed() -> void:
	visible = false
	emit_signal("closed")

# Esc closes the panel — same convention as the other overlays.
func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey:
		var key: InputEventKey = event as InputEventKey
		if key.pressed and not key.echo and key.keycode == KEY_ESCAPE:
			get_viewport().set_input_as_handled()
			_on_close_pressed()


# ---------- Chat-edit handlers (Phase 17) ----------

func _on_chat_edit_submit_pressed() -> void:
	# Pre-conditions. We've already disabled the button in most of these
	# states via _refresh_chat_edit_visibility, but be defensive — the
	# button could be invoked from a synthetic test path.
	if _orch == null or _orch.gdd_manager == null:
		_chat_edit_status.text = "no orchestrator bound (internal error)"
		_chat_edit_status.modulate = Color(1.0, 0.45, 0.45, 1.0)
		return
	if _current_gdd.is_empty():
		_chat_edit_status.text = "load a GDD first"
		_chat_edit_status.modulate = Color(1.0, 0.45, 0.45, 1.0)
		return
	if not _is_claude_registered():
		_chat_edit_status.text = "claude plugin not registered"
		_chat_edit_status.modulate = Color(1.0, 0.45, 0.45, 1.0)
		return
	if not _chat_edit_task_id.is_empty():
		# Mid-flight — refresh logic should have disabled the button,
		# but guard anyway.
		return
	var instruction: String = _chat_edit_input.text.strip_edges()
	if instruction.is_empty():
		_chat_edit_status.text = "describe what to change first"
		_chat_edit_status.modulate = Color(1.0, 0.7, 0.2, 1.0)
		return

	var schema: Dictionary = _orch.gdd_manager.get_schema()
	# Phase 31 (ADR 031): refinement uses the LATEST proposed GDD as
	# the basis when we're in PREVIEW state — that's the cumulative
	# state the user is iterating on. First turn falls back to the
	# saved baseline.
	var basis: Dictionary = _resolve_chat_edit_basis()
	var prompt: String = _compose_chat_edit_prompt(basis, schema, instruction)

	var tid: String = str(_orch.generate("claude", prompt, _CHAT_EDIT_PARAMS))
	if tid.is_empty():
		_chat_edit_status.text = "dispatch failed (see logs)"
		_chat_edit_status.modulate = Color(1.0, 0.45, 0.45, 1.0)
		return
	_chat_edit_task_id = tid
	_conversation_turn += 1
	_chat_edit_status.text = "turn %d: editing… task %s" % [_conversation_turn, tid]
	_chat_edit_status.modulate = Color(0.85, 0.85, 0.85, 1.0)
	_chat_edit_submit.disabled = true
	emit_signal("chat_edit_dispatched", tid)


# Compose the prompt sent to Claude. Public-ish for tests — naming with
# leading underscore by convention but tests call it directly.
func _compose_chat_edit_prompt(gdd: Dictionary, schema: Dictionary, instruction: String) -> String:
	# Pretty-print so Claude can echo the structure back without
	# whitespace surprises. We're spending tokens for clarity; the
	# alternative (compact JSON) is harder to read in any logs.
	var gdd_json: String = JSON.stringify(gdd, "  ")
	var schema_json: String = JSON.stringify(schema, "  ")
	return ("You are editing a Game Design Document. Apply the requested change "
		+ "and return ONLY the updated JSON document.\n\n"
		+ "The document conforms to this JSON Schema:\n"
		+ "```json\n%s\n```\n\n"
		+ "The current document is:\n"
		+ "```json\n%s\n```\n\n"
		+ "Apply this edit:\n"
		+ "%s\n\n"
		+ "Return ONLY the updated JSON document. No prose, no code fences, no commentary."
	) % [schema_json, gdd_json, instruction]


# Routed via PluginManager.plugin_task_completed. We filter to our own
# task id so other Claude calls in the app don't trigger us.
func _on_chat_edit_completed(plugin_name: String, task_id: String, result: Dictionary) -> void:
	if task_id != _chat_edit_task_id:
		return
	_chat_edit_task_id = ""
	# Result shape mirrors plugin_task_completed: a dict with at least
	# `text`. We don't need cost / tokens here — those are handled by
	# the cost_tracker via cost_incurred.
	var text: String = str(result.get("text", ""))
	var parse: Dictionary = _parse_chat_edit_response(text)
	if not bool(parse.get("success", false)):
		_chat_edit_status.text = "parse failed: %s" % str(parse.get("error", "unknown"))
		_chat_edit_status.modulate = Color(1.0, 0.45, 0.45, 1.0)
		_chat_edit_submit.disabled = false
		return
	var proposed: Dictionary = parse["gdd"] as Dictionary
	_pending_gdd = proposed
	_render_diff_preview(_current_gdd, proposed)
	_chat_edit_status.text = "review the proposal below — Approve or Reject to continue"
	_chat_edit_status.modulate = Color(0.5, 0.9, 0.5, 1.0)


func _on_chat_edit_failed(plugin_name: String, task_id: String, error: Dictionary) -> void:
	if task_id != _chat_edit_task_id:
		return
	_chat_edit_task_id = ""
	_chat_edit_submit.disabled = false
	var msg: String = str(error.get("message", error.get("code", "unknown")))
	_chat_edit_status.text = "edit failed: %s" % msg
	_chat_edit_status.modulate = Color(1.0, 0.45, 0.45, 1.0)


# Parse Claude's reply text into a Dictionary. We tolerate a leading
# code-fence in case Claude ignores the "no code fences" instruction —
# this is the single most common deviation in practice. Returns
# {success, gdd?, error?}.
#
# Implementation note: JSON.parse_string() raises an engine-level
# push_error on malformed input, which GUT treats as a test failure.
# We use the JSON.new().parse() instance API instead so a parse failure
# is just a returned error code with no engine-level chatter.
func _parse_chat_edit_response(raw: String) -> Dictionary:
	var text: String = raw.strip_edges()
	# Strip a ```json fence if present.
	if text.begins_with("```"):
		var first_newline: int = text.find("\n")
		if first_newline >= 0:
			text = text.substr(first_newline + 1)
		if text.ends_with("```"):
			text = text.substr(0, text.length() - 3)
		text = text.strip_edges()
	if text.is_empty():
		return {"success": false, "error": "empty response"}
	var parser: JSON = JSON.new()
	var err: Error = parser.parse(text)
	if err != OK:
		return {"success": false,
				"error": "JSON parse error at line %d: %s" % [
					parser.get_error_line(), parser.get_error_message()]}
	var parsed: Variant = parser.data
	if not (parsed is Dictionary):
		return {"success": false, "error": "response is not a JSON object"}
	return {"success": true, "gdd": parsed}


# Build a short summary line + populate the side-by-side TextEdits +
# paint per-line backgrounds (red on removed lines in the before view,
# green on added lines in the after view). See ADR 020.
func _render_diff_preview(before: Dictionary, after: Dictionary) -> void:
	_diff_summary_label.text = _compute_diff_summary(before, after)
	var before_text: String = JSON.stringify(before, "  ")
	var after_text: String = JSON.stringify(after, "  ")
	_diff_before_view.text = before_text
	_diff_after_view.text = after_text
	# Apply per-line highlights via the LCS diff. Default is no
	# background; we only set the colour on removed / added lines.
	var marks: Dictionary = _compute_line_diff(before_text, after_text)
	_apply_line_marks(_diff_before_view,
		marks["before_marks"] as Array,
		"removed",
		Color(1.0, 0.3, 0.3, 0.3))
	_apply_line_marks(_diff_after_view,
		marks["after_marks"] as Array,
		"added",
		Color(0.3, 1.0, 0.3, 0.3))
	_diff_section.visible = true


# LCS-based line diff. Returns a Dictionary with two Arrays the same
# length as their respective input line lists:
#
#   {
#     "before_marks": ["context" | "removed", ...],   # one per before line
#     "after_marks":  ["context" | "added", ...],      # one per after line
#   }
#
# Performance: O(N*M) time + space for the DP table. Real GDDs land
# at ≤ ~500 lines pretty-printed, so an 500×500 int table is fine —
# under a millisecond on any machine that runs Godot. If this ever
# shows up in a profile we'll switch to Hunt-McIlroy or Myers.
#
# Implementation note: we build the DP table forward, then walk back
# to mark each line. Equal lines walk diagonally; otherwise we move
# along the side with the larger remaining LCS length, marking the
# off-axis line as added (right side) or removed (left side).
func _compute_line_diff(before_text: String, after_text: String) -> Dictionary:
	var a: PackedStringArray = before_text.split("\n")
	var b: PackedStringArray = after_text.split("\n")
	var n: int = a.size()
	var m: int = b.size()

	# Build the LCS-length DP table. dp[i][j] = LCS length of
	# a[0..i-1] vs b[0..j-1]. Stored row-major in a flat Array for
	# cheap indexing (a[i*M + j]).
	var stride: int = m + 1
	var dp: PackedInt32Array = PackedInt32Array()
	dp.resize((n + 1) * stride)
	# Implicit zero init from PackedInt32Array.

	for i in range(1, n + 1):
		for j in range(1, m + 1):
			if a[i - 1] == b[j - 1]:
				dp[i * stride + j] = dp[(i - 1) * stride + (j - 1)] + 1
			else:
				var up: int = dp[(i - 1) * stride + j]
				var left: int = dp[i * stride + (j - 1)]
				dp[i * stride + j] = up if up >= left else left

	# Default both arrays to "context"; we'll overwrite as we walk back.
	var before_marks: Array = []
	var after_marks: Array = []
	before_marks.resize(n)
	after_marks.resize(m)
	for k in range(n):
		before_marks[k] = "context"
	for k in range(m):
		after_marks[k] = "context"

	# Walk back from (n, m) to (0, 0).
	var i: int = n
	var j: int = m
	while i > 0 or j > 0:
		if i > 0 and j > 0 and a[i - 1] == b[j - 1]:
			# Lines match — both stay "context".
			i -= 1
			j -= 1
		elif j > 0 and (i == 0 or dp[i * stride + (j - 1)] >= dp[(i - 1) * stride + j]):
			# Best to come from the left → b[j-1] was inserted.
			after_marks[j - 1] = "added"
			j -= 1
		else:
			# Best to come from above → a[i-1] was deleted.
			before_marks[i - 1] = "removed"
			i -= 1

	return {"before_marks": before_marks, "after_marks": after_marks}


# Apply background colour to every line whose mark equals `target_kind`.
# Lines not matching the kind are left at the TextEdit default (no
# background). We don't reset other lines explicitly because each
# render builds a fresh TextEdit content — the previous render's
# colours are wiped when the text is reassigned.
func _apply_line_marks(view: TextEdit, marks: Array, target_kind: String,
		bg: Color) -> void:
	for idx in range(marks.size()):
		if str(marks[idx]) == target_kind:
			view.set_line_background_color(idx, bg)


# Cheap, semantic-ish summary: per-entity-array count delta + a hint
# when top-level fields changed + a word-diff suffix (Phase 30 / ADR
# 030) so the user sees how much PROSE changed even when only one
# field's text was edited.
func _compute_diff_summary(before: Dictionary, after: Dictionary) -> String:
	var lines: Array = []
	for key in _ENTITY_KEYS:
		var b_arr = before.get(key, [])
		var a_arr = after.get(key, [])
		var b: int = (b_arr as Array).size() if b_arr is Array else 0
		var a: int = (a_arr as Array).size() if a_arr is Array else 0
		if b != a:
			lines.append("%s: %d → %d" % [key, b, a])
	# Top-level scalar / array changes (game_title, genres, core_loop).
	for key in ["game_title", "genres", "core_loop"]:
		if before.get(key, null) != after.get(key, null):
			lines.append("~%s" % key)
	# Phase 30: append word-diff stats. Operates on the pretty-printed
	# JSON so it captures intra-line edits the structural list above
	# doesn't (e.g. tweaking a description string).
	var before_text: String = JSON.stringify(before, "  ")
	var after_text: String = JSON.stringify(after, "  ")
	var word_stats: Dictionary = _compute_word_diff(before_text, after_text)
	var removed: int = int(word_stats.get("removed", 0))
	var added: int = int(word_stats.get("added", 0))
	var word_suffix: String = ""
	if removed > 0 or added > 0:
		word_suffix = " — words: -%d +%d" % [removed, added]
	if lines.is_empty():
		return "No structural changes (entity counts unchanged, top-level fields identical)%s" % word_suffix
	return "Changes: " + ", ".join(lines) + word_suffix


# Word-granularity diff (Phase 30 / ADR 030). Reuses the same DP-LCS
# shape as `_compute_line_diff` but at whitespace-token granularity.
# Splits both texts on any whitespace run (so newlines, multiple
# spaces, tabs all behave the same) and counts how many tokens are
# unique to before vs after.
#
# Returns:
#   {
#     "removed": int,   # words in before that don't appear in the LCS
#     "added":   int,   # words in after  that don't appear in the LCS
#     "common":  int,   # LCS length
#   }
#
# Performance: O(N*M) DP, same caveat as line diff — fine for any
# JSON document a human is going to author.
func _compute_word_diff(before_text: String, after_text: String) -> Dictionary:
	# `split` with maxsplit=0 behaves like Python's str.split() with
	# no separator: collapses any whitespace run.
	var a_words: PackedStringArray = before_text.split(" ", false)
	var b_words: PackedStringArray = after_text.split(" ", false)
	# Strip empty tokens that escape the above (newlines, etc).
	var a: Array = _flatten_whitespace_tokens(a_words)
	var b: Array = _flatten_whitespace_tokens(b_words)
	var n: int = a.size()
	var m: int = b.size()
	if n == 0 and m == 0:
		return {"removed": 0, "added": 0, "common": 0}
	var stride: int = m + 1
	var dp: PackedInt32Array = PackedInt32Array()
	dp.resize((n + 1) * stride)
	for i in range(1, n + 1):
		for j in range(1, m + 1):
			if a[i - 1] == b[j - 1]:
				dp[i * stride + j] = dp[(i - 1) * stride + (j - 1)] + 1
			else:
				var up: int = dp[(i - 1) * stride + j]
				var left: int = dp[i * stride + (j - 1)]
				dp[i * stride + j] = up if up >= left else left
	var common: int = dp[n * stride + m]
	return {
		"removed": n - common,
		"added":   m - common,
		"common":  common,
	}

# Helper: split each string-with-whitespace token further so the
# diff actually compares words. Without this, "a\nb" gets treated as
# one token because split(" ") doesn't split on newlines.
func _flatten_whitespace_tokens(tokens: PackedStringArray) -> Array:
	var out: Array = []
	for t in tokens:
		var stripped: String = (t as String).strip_edges()
		if stripped.is_empty():
			continue
		# Split further on any embedded whitespace.
		for piece in stripped.split("\n", false):
			var p: String = (piece as String).strip_edges()
			if not p.is_empty():
				# Tabs and other whitespace inside `p` — split them too.
				for w in p.split("\t", false):
					var wt: String = (w as String).strip_edges()
					if not wt.is_empty():
						out.append(wt)
	return out


# Approve flow — write a snapshot of the current state, then save the
# proposed state. Two saves means two snapshots: the rollback target +
# the applied edit.
func _on_approve_pressed() -> void:
	if _orch == null or _orch.gdd_manager == null:
		_chat_edit_status.text = "no orchestrator bound (internal error)"
		_chat_edit_status.modulate = Color(1.0, 0.45, 0.45, 1.0)
		return
	if _pending_gdd.is_empty():
		return
	if _current_gdd_path.is_empty():
		_chat_edit_status.text = "no GDD path set — Load before Approve"
		_chat_edit_status.modulate = Color(1.0, 0.45, 0.45, 1.0)
		return
	# Snapshot the pre-state by saving it back to its own path. This
	# both refreshes the metadata.updated_at timestamp and creates a
	# rollback target. The user can roll back to this version if they
	# regret the chat-edit.
	var pre: Dictionary = _orch.gdd_manager.save_gdd(_current_gdd, _current_gdd_path)
	if not bool(pre.get("success", false)):
		_chat_edit_status.text = "pre-snapshot failed: %s" % str(pre.get("error", "unknown"))
		_chat_edit_status.modulate = Color(1.0, 0.45, 0.45, 1.0)
		return
	# Apply the proposed change.
	var post: Dictionary = _orch.gdd_manager.save_gdd(_pending_gdd, _current_gdd_path)
	if not bool(post.get("success", false)):
		var errors_text: String = ""
		if post.has("errors"):
			errors_text = ": " + ", ".join((post["errors"] as Array).slice(0, min(3, (post["errors"] as Array).size())))
		_chat_edit_status.text = "save failed%s" % errors_text
		_chat_edit_status.modulate = Color(1.0, 0.45, 0.45, 1.0)
		return
	# Promote the proposed GDD into the current one — the user is
	# now editing on top of the new state.
	_current_gdd = _pending_gdd.duplicate(true)
	var version: int = int(post.get("snapshot_version", -1))
	_clear_pending_edit()
	_chat_edit_input.text = ""
	_chat_edit_status.text = "applied — saved as snapshot v%d" % version
	_chat_edit_status.modulate = Color(0.5, 0.9, 0.5, 1.0)
	_refresh()
	emit_signal("chat_edit_applied", version)


func _on_reject_pressed() -> void:
	_clear_pending_edit()
	_chat_edit_status.text = "rejected — original GDD untouched"
	_chat_edit_status.modulate = Color(0.85, 0.85, 0.85, 1.0)
	_refresh_chat_edit_visibility()
	emit_signal("chat_edit_rejected")


func _clear_pending_edit() -> void:
	_pending_gdd = {}
	# Phase 31: any time we drop the pending preview (Reject, fresh
	# Load, Edit-mode entry, successful Approve) we also end the
	# conversation. Next Submit starts at turn 1 from the saved baseline.
	_conversation_turn = 0
	if _diff_section != null:
		_diff_section.visible = false
		_diff_before_view.text = ""
		_diff_after_view.text = ""
		_diff_summary_label.text = ""

# Phase 31: resolve the basis for the next chat-edit dispatch.
# In PREVIEW state (_pending_gdd populated) we iterate on the
# latest proposal — that's the user's cumulative state. Otherwise
# we start fresh from the saved baseline.
#
# Public-ish (no leading-underscore in spirit) for tests; the
# leading underscore indicates "internal helper" by convention.
func _resolve_chat_edit_basis() -> Dictionary:
	if not _pending_gdd.is_empty():
		return _pending_gdd
	return _current_gdd


# ---------- Form-based edit handlers (Phase 18) ----------

# Toggle the panel from view mode into form-based edit mode. Hides the
# view-only widgets, populates the form with a deep copy of the
# currently-loaded GDD, and reveals the form. We also drop any pending
# chat-edit preview — it would conflict with form-based edits made on
# top of the same baseline.
func _on_edit_pressed() -> void:
	if _current_gdd.is_empty():
		# Defensive — the button is disabled in this state, but a
		# synthetic test path could still call here.
		return
	_clear_pending_edit()
	_edit_form.set_gdd(_current_gdd)
	_set_edit_mode(true)
	emit_signal("edit_mode_entered")


func _set_edit_mode(on: bool) -> void:
	_edit_mode = on
	for n in _view_only_nodes:
		if n != null:
			(n as Control).visible = not on
	_edit_form.visible = on
	# Disable Load while in edit mode — switching documents mid-edit
	# would silently throw away the working buffer.
	_load_button.disabled = on
	_edit_button.disabled = on or _current_gdd.is_empty()


# Form Save → validate, snapshot the pre-state (so the user can roll
# back to where they were), then save the new state. Same two-snapshot
# discipline as the chat-edit Approve flow.
func _on_edit_form_saved(edited: Dictionary) -> void:
	if _orch == null or _orch.gdd_manager == null:
		_status_label.text = "no orchestrator bound (internal error)"
		_status_label.modulate = Color(1.0, 0.45, 0.45, 1.0)
		return
	if _current_gdd_path.is_empty():
		_status_label.text = "no GDD path set — Load before Save"
		_status_label.modulate = Color(1.0, 0.45, 0.45, 1.0)
		return
	# Pre-state snapshot.
	var pre: Dictionary = _orch.gdd_manager.save_gdd(_current_gdd, _current_gdd_path)
	if not bool(pre.get("success", false)):
		_status_label.text = "pre-snapshot failed: %s" % str(pre.get("error", "unknown"))
		_status_label.modulate = Color(1.0, 0.45, 0.45, 1.0)
		return
	# Apply.
	var post: Dictionary = _orch.gdd_manager.save_gdd(edited, _current_gdd_path)
	if not bool(post.get("success", false)):
		var errors: Array = post.get("errors", []) as Array
		var hint: String = ""
		if errors.size() > 0:
			hint = ": " + ", ".join(errors.slice(0, min(3, errors.size())))
		_status_label.text = "save failed%s" % hint
		_status_label.modulate = Color(1.0, 0.45, 0.45, 1.0)
		# Stay in edit mode so the user can correct and retry.
		return
	_current_gdd = edited.duplicate(true)
	var version: int = int(post.get("snapshot_version", -1))
	_status_label.text = "Saved — snapshot v%d" % version
	_status_label.modulate = Color(0.5, 0.9, 0.5, 1.0)
	_set_edit_mode(false)
	_refresh()
	emit_signal("edit_saved", version)


func _on_edit_form_cancelled() -> void:
	_set_edit_mode(false)
	# Refresh so per-section visibility (e.g. chat-edit gating on
	# claude-registered) re-computes correctly. _set_edit_mode forces
	# every view-only node visible; refresh re-imposes the proper rules.
	_refresh()
	_status_label.text = "Edit cancelled — no changes written"
	_status_label.modulate = Color(0.85, 0.85, 0.85, 1.0)
	emit_signal("edit_cancelled")
