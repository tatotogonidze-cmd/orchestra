# scene_panel.gd
# Modal overlay for the Scene Tester (Phase 23 / ADR 023). Surfaces
# from the cost_footer's "Scenes" button and gives the user:
#
#   - The list of scenes the SceneManager knows about.
#   - A "New scene" affordance with a name input.
#   - For the selected scene: a SubViewport preview of every 3D
#     asset it contains, plus a side list of all asset_ids with
#     remove buttons, plus a Delete-scene button.
#
# Adding assets to a scene happens primarily through asset_preview's
# "Add to Scene" affordance — we don't duplicate the flow here. The
# asset list inside the panel is read-only-ish: you can REMOVE
# assets, but adding goes through the gallery → preview flow.
#
# The 3D preview reuses the same SubViewport + Camera3D + lights
# scaffolding documented in ADR 021. We re-render on every scene
# selection — no caching, the scene preview is always in sync with
# the SceneManager + AssetManager state at the moment of click.
#
# Test hooks (same idiom as the other overlays):
#   - `_scenes_list`, `_new_name_input`, `_new_scene_button`,
#     `_delete_scene_button`, `_scene_assets_list`, `_close_button`.
#   - `_preview_subviewport`, `_preview_camera` — set when a scene
#     is selected and at least one renderable child exists.
#   - `_selected_scene_id: String` — currently focused scene.
#   - `_scene_ids: Array` — parallel index for `_scenes_list`.
#   - Internal handlers `_on_new_scene_pressed`, `_on_scene_selected`,
#     `_on_delete_scene_pressed`, `_on_close_pressed` are callable
#     directly.

extends Control

signal closed()
signal scene_selected(scene_id: String)
signal scene_deleted(scene_id: String)

var _orch: Node = null
var _selected_scene_id: String = ""

# Top-level pieces.
var _panel: PanelContainer
var _vbox: VBoxContainer
var _header_label: Label
var _status_label: Label
var _close_button: Button

# Left column.
var _scenes_list: ItemList
var _new_name_input: LineEdit
var _new_scene_button: Button

# Right column.
var _preview_container: SubViewportContainer
var _preview_subviewport: SubViewport
var _preview_camera: Camera3D
var _scene_assets_list: ItemList
var _delete_scene_button: Button
var _empty_preview_label: Label

# `_scenes_list` doesn't carry rich metadata — we store the scene_ids
# in this parallel array, indexed by the same int the ItemList uses.
var _scene_ids: Array = []

# The asset_ids list mirrors `_scene_assets_list`. Removing an asset
# uses the index back into this array.
var _displayed_asset_ids: Array = []

# Orbital camera state — same shape as ADR 021's _render_3d. We don't
# wire input here (yet); the preview is read-only fixed angle for MVP.
const _DEFAULT_YAW: float = 0.0
const _DEFAULT_PITCH: float = -0.3
const _DEFAULT_DISTANCE: float = 5.0


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
	_panel.custom_minimum_size = Vector2(720, 480)
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
	_header_label.text = "Scene Tester"
	_header_label.add_theme_font_size_override("font_size", 18)
	_vbox.add_child(_header_label)

	_status_label = Label.new()
	_status_label.text = ""
	_status_label.modulate = Color(0.85, 0.85, 0.85, 1.0)
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_vbox.add_child(_status_label)

	# Two-column body — left for the list, right for the preview.
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 10)
	_vbox.add_child(body)

	# ---------- Left column ----------
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(240, 0)
	left.add_theme_constant_override("separation", 6)
	body.add_child(left)

	var left_header := Label.new()
	left_header.text = "Scenes"
	left_header.add_theme_font_size_override("font_size", 14)
	left.add_child(left_header)

	_scenes_list = ItemList.new()
	_scenes_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scenes_list.custom_minimum_size = Vector2(0, 200)
	_scenes_list.item_selected.connect(_on_scene_selected)
	left.add_child(_scenes_list)

	var new_row := HBoxContainer.new()
	new_row.add_theme_constant_override("separation", 4)
	left.add_child(new_row)

	_new_name_input = LineEdit.new()
	_new_name_input.placeholder_text = "new scene name…"
	_new_name_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	new_row.add_child(_new_name_input)

	_new_scene_button = Button.new()
	_new_scene_button.text = "+ New"
	_new_scene_button.pressed.connect(_on_new_scene_pressed)
	new_row.add_child(_new_scene_button)

	# ---------- Right column ----------
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 6)
	body.add_child(right)

	var preview_header := Label.new()
	preview_header.text = "Preview"
	preview_header.add_theme_font_size_override("font_size", 14)
	right.add_child(preview_header)

	# Placeholder shown when no scene is selected. Replaced with a
	# SubViewportContainer when _refresh_preview runs.
	_empty_preview_label = Label.new()
	_empty_preview_label.text = "(no scene selected)"
	_empty_preview_label.modulate = Color(0.7, 0.7, 0.7, 1.0)
	_empty_preview_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_empty_preview_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(_empty_preview_label)

	var assets_header := Label.new()
	assets_header.text = "Assets in scene"
	assets_header.add_theme_font_size_override("font_size", 14)
	right.add_child(assets_header)

	_scene_assets_list = ItemList.new()
	_scene_assets_list.custom_minimum_size = Vector2(0, 100)
	_scene_assets_list.item_activated.connect(_on_scene_asset_activated)
	right.add_child(_scene_assets_list)

	# Delete-scene button + close button live in a footer row.
	var footer := HBoxContainer.new()
	footer.alignment = BoxContainer.ALIGNMENT_END
	footer.add_theme_constant_override("separation", 8)
	_vbox.add_child(footer)

	_delete_scene_button = Button.new()
	_delete_scene_button.text = "Delete scene"
	_delete_scene_button.tooltip_text = "Remove the selected scene from the index"
	_delete_scene_button.disabled = true
	_delete_scene_button.pressed.connect(_on_delete_scene_pressed)
	footer.add_child(_delete_scene_button)

	_close_button = Button.new()
	_close_button.text = "Close"
	_close_button.pressed.connect(_on_close_pressed)
	footer.add_child(_close_button)

	visible = false


# ---------- Public API ----------

func bind(orch: Node) -> void:
	_orch = orch

func show_dialog() -> void:
	_refresh_scenes_list()
	visible = true


# ---------- Internals ----------

func _refresh_scenes_list() -> void:
	_scenes_list.clear()
	_scene_ids.clear()
	if _orch == null or _orch.scene_manager == null:
		_status_label.text = "(no orchestrator bound)"
		_status_label.modulate = Color(1.0, 0.45, 0.45, 1.0)
		return
	var scenes: Array = _orch.scene_manager.list_scenes()
	if scenes.is_empty():
		_status_label.text = "No scenes yet — create one with the New button."
		_status_label.modulate = Color(0.7, 0.7, 0.7, 1.0)
	else:
		_status_label.text = ""
	for s in scenes:
		var asset_count: int = (s.get("asset_ids", []) as Array).size() \
			if s.get("asset_ids", []) is Array else 0
		_scenes_list.add_item("%s (%d)" % [str(s.get("name", "")), asset_count])
		_scene_ids.append(str(s.get("id", "")))
	# Re-select the currently-selected scene if it still exists.
	var idx: int = _scene_ids.find(_selected_scene_id)
	if idx >= 0:
		_scenes_list.select(idx)
		_refresh_preview(_selected_scene_id)
	else:
		_selected_scene_id = ""
		_clear_preview()
		_delete_scene_button.disabled = true

func _refresh_preview(scene_id: String) -> void:
	_clear_preview()
	if _orch == null or _orch.scene_manager == null \
			or _orch.asset_manager == null:
		return
	var scene: Dictionary = _orch.scene_manager.get_scene(scene_id)
	if scene.is_empty():
		return
	# Build the asset list — every asset_id, regardless of type, with
	# a status note when the underlying asset has been deleted.
	_displayed_asset_ids.clear()
	for aid in (scene.get("asset_ids", []) as Array):
		var meta: Dictionary = _orch.asset_manager.get_asset(str(aid))
		var label: String = ""
		if meta.is_empty():
			label = "[missing] %s" % str(aid)
		else:
			label = "[%s] %s" % [str(meta.get("asset_type", "?")), str(aid)]
		_scene_assets_list.add_item(label)
		_displayed_asset_ids.append(str(aid))

	# Build the SubViewport preview. We always build the scaffolding,
	# then add a child Node3D per 3D asset. Other types stay listed in
	# the side panel but don't render — a follow-up will give them
	# spatial representations.
	_build_preview_scaffolding()
	var added_3d: int = 0
	for aid in (scene.get("asset_ids", []) as Array):
		var meta: Dictionary = _orch.asset_manager.get_asset(str(aid))
		if meta.is_empty():
			continue
		if str(meta.get("asset_type", "")) != "3d":
			continue
		var path: String = str(meta.get("local_path", ""))
		if path.is_empty() or not FileAccess.file_exists(path):
			continue
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		var err: Error = doc.append_from_file(path, state)
		if err != OK:
			continue
		var node: Node = doc.generate_scene(state)
		if node != null:
			_preview_subviewport.add_child(node)
			added_3d += 1
	if added_3d == 0:
		_overlay_preview_message("No 3D assets in this scene to preview.")
	_delete_scene_button.disabled = false

# Drop the previous preview node tree. We use immediate `free()` for
# the same orphan-tracker reasons documented in ADR 011 / 012 / 021 —
# `queue_free` would leave dangling rendered nodes between selections.
func _clear_preview() -> void:
	_scene_assets_list.clear()
	_displayed_asset_ids.clear()
	_preview_subviewport = null
	_preview_camera = null
	if _preview_container != null and is_instance_valid(_preview_container):
		# _preview_container is a child of `right` VBoxContainer; we
		# let GUT clean up via tree teardown but eagerly evict here.
		var parent: Node = _preview_container.get_parent()
		if parent != null:
			parent.remove_child(_preview_container)
		_preview_container.free()
		_preview_container = null
	# Show the empty placeholder again until the next selection.
	if _empty_preview_label != null:
		_empty_preview_label.visible = true

func _build_preview_scaffolding() -> void:
	# Hide the empty-state label and build the SubViewport stack just
	# above it in the right column. We insert at the correct index so
	# the layout doesn't reshuffle.
	_empty_preview_label.visible = false
	var right: Node = _empty_preview_label.get_parent()

	_preview_container = SubViewportContainer.new()
	_preview_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preview_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_preview_container.stretch = true
	_preview_container.custom_minimum_size = Vector2(360, 240)
	right.add_child(_preview_container)
	right.move_child(_preview_container, _empty_preview_label.get_index())

	_preview_subviewport = SubViewport.new()
	_preview_subviewport.size = Vector2i(640, 480)
	_preview_subviewport.own_world_3d = true
	_preview_container.add_child(_preview_subviewport)

	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.4, 0.4, 0.5, 1.0)
	env.ambient_light_energy = 1.0
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.05, 0.05, 0.07, 1.0)
	env_node.environment = env
	_preview_subviewport.add_child(env_node)

	var key_light := DirectionalLight3D.new()
	key_light.rotation = Vector3(deg_to_rad(-45.0), deg_to_rad(30.0), 0.0)
	key_light.light_energy = 1.0
	_preview_subviewport.add_child(key_light)

	_preview_camera = Camera3D.new()
	_preview_camera.current = true
	# IMPORTANT: add_child BEFORE look_at — Camera3D.look_at requires
	# the node to be inside the scene tree (it uses world transforms),
	# and calling it on a fresh-from-new() Node3D pushes the engine
	# error "Condition !is_inside_tree() is true". Phase 21's asset_preview
	# already establishes this pattern; matching it here.
	_preview_subviewport.add_child(_preview_camera)
	# Fixed angle for MVP — orbital input is documented as a follow-up
	# in ADR 023 (the Phase 21 single-asset previewer has it).
	var x: float = cos(_DEFAULT_PITCH) * sin(_DEFAULT_YAW) * _DEFAULT_DISTANCE
	var y: float = sin(_DEFAULT_PITCH) * _DEFAULT_DISTANCE
	var z: float = cos(_DEFAULT_PITCH) * cos(_DEFAULT_YAW) * _DEFAULT_DISTANCE
	_preview_camera.position = Vector3(x, y, z)
	_preview_camera.look_at(Vector3.ZERO, Vector3.UP)

func _overlay_preview_message(msg: String) -> void:
	if _preview_container == null:
		return
	var lbl := Label.new()
	lbl.text = msg
	lbl.modulate = Color(0.85, 0.85, 0.85, 1.0)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_preview_container.add_child(lbl)


# ---------- Handlers ----------

func _on_new_scene_pressed() -> void:
	if _orch == null or _orch.scene_manager == null:
		_status_label.text = "no orchestrator bound (internal error)"
		_status_label.modulate = Color(1.0, 0.45, 0.45, 1.0)
		return
	var name: String = _new_name_input.text.strip_edges()
	if name.is_empty():
		_status_label.text = "type a scene name first"
		_status_label.modulate = Color(1.0, 0.7, 0.2, 1.0)
		return
	var r: Dictionary = _orch.scene_manager.create_scene(name, [], null)
	if not bool(r.get("success", false)):
		_status_label.text = "create failed: %s" % str(r.get("error", "unknown"))
		_status_label.modulate = Color(1.0, 0.45, 0.45, 1.0)
		return
	_new_name_input.text = ""
	_selected_scene_id = str(r["scene_id"])
	_refresh_scenes_list()
	_status_label.text = "Created '%s'" % name
	_status_label.modulate = Color(0.5, 0.9, 0.5, 1.0)

func _on_scene_selected(idx: int) -> void:
	if idx < 0 or idx >= _scene_ids.size():
		return
	_selected_scene_id = str(_scene_ids[idx])
	_refresh_preview(_selected_scene_id)
	emit_signal("scene_selected", _selected_scene_id)

# Double-click on an asset in the side list = remove it from the
# scene. We use item_activated (double-click) instead of an inline ×
# button to keep the row layout simple. Single-click selects but
# doesn't act — leaves room for a future "expand to inspect" affordance.
func _on_scene_asset_activated(idx: int) -> void:
	if _orch == null or _orch.scene_manager == null:
		return
	if idx < 0 or idx >= _displayed_asset_ids.size():
		return
	if _selected_scene_id.is_empty():
		return
	var asset_id: String = str(_displayed_asset_ids[idx])
	_orch.scene_manager.remove_asset_from_scene(_selected_scene_id, asset_id)
	_refresh_preview(_selected_scene_id)

func _on_delete_scene_pressed() -> void:
	if _orch == null or _orch.scene_manager == null:
		return
	if _selected_scene_id.is_empty():
		return
	var sid: String = _selected_scene_id
	_orch.scene_manager.delete_scene(sid)
	_selected_scene_id = ""
	_refresh_scenes_list()
	_status_label.text = "Deleted scene"
	_status_label.modulate = Color(0.85, 0.85, 0.85, 1.0)
	emit_signal("scene_deleted", sid)

func _on_close_pressed() -> void:
	_clear_preview()
	visible = false
	emit_signal("closed")

# Esc dismisses, same convention as the other overlays.
func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey:
		var key: InputEventKey = event as InputEventKey
		if key.pressed and not key.echo and key.keycode == KEY_ESCAPE:
			get_viewport().set_input_as_handled()
			_on_close_pressed()
