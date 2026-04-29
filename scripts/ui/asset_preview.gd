# asset_preview.gd
# Full-screen modal that previews one asset. Triggered when the user
# clicks a row in `asset_gallery`.
#
# The preview body is type-specific:
#   - text   → TextEdit, read-only, with the file's UTF-8 contents.
#   - image  → TextureRect with the image loaded via Image.load_from_file.
#   - audio  → AudioStreamPlayer + Play / Stop transport. mp3 only for
#              MVP; ElevenLabs is the only audio plugin that produces
#              real assets today and it returns mp3.
#   - 3d     → placeholder label. Real 3D preview needs a SubViewport,
#              GLTFDocument loader, and an orbital camera — punted to
#              the scene-import phase. See ADR 008 follow-up.
#
# Metadata column sits next to the renderer and shows the standard
# AssetManager fields (id, plugin, prompt, path, size, cost, created).
#
# Footer: Close (always), Delete (always — file or no file). Delete
# emits a signal so main_shell can drive AssetManager.delete_asset
# without the preview poking the manager directly. Same separation as
# the other overlays.
#
# Test hooks:
#   - `_content_holder`, `_metadata_label`, `_close_button`,
#     `_delete_button` are reachable for assertions.
#   - `_current_renderer_type: String` identifies which branch was taken
#     ("text" | "image" | "audio" | "3d" | "error" | "").
#   - Internal handlers `_on_close_pressed`, `_on_delete_pressed`,
#     `_on_play_pressed`, `_on_stop_pressed` are callable directly.

extends Control

const PluginRegistryScript = preload("res://scripts/plugin_registry.gd")

signal closed()
signal delete_requested(asset_id: String)

var _orch: Node = null

# Top-level pieces.
var _panel: PanelContainer
var _vbox: VBoxContainer
var _header_label: Label
var _body_hbox: HBoxContainer
var _content_holder: PanelContainer
var _metadata_panel: PanelContainer
var _metadata_label: Label
var _footer: HBoxContainer
var _close_button: Button
var _delete_button: Button

# Tracking the currently-displayed asset so Delete can address it
# without a fresh lookup.
var _current_asset_id: String = ""

# Last branch taken — useful for tests and for tearing down audio
# playback when we navigate away.
var _current_renderer_type: String = ""

# Audio is special: we keep a reference so Stop can address the player
# even if the renderer scrolls out of focus.
var _audio_player: AudioStreamPlayer = null

# Path of the currently-loaded audio file. Set by _render_audio, consumed
# lazily by _on_play_pressed. We deliberately defer reading the bytes
# into AudioStreamMP3.data until the user presses Play because the MP3
# decoder push_errors on malformed data on assignment — a problem for
# tests with fake fixtures, and a memory cost for large files we may
# never play.
var _audio_path: String = ""

# 3D renderer state (Phase 21 / ADR 021). Live only while
# _current_renderer_type == "3d"; cleared in _clear_renderer.
var _3d_subviewport: SubViewport = null
var _3d_camera: Camera3D = null
# Orbital-camera state in spherical coordinates around _3d_target.
# Defaults position the camera up-and-back from the origin so a
# typical centered model fills the viewport.
var _3d_yaw: float = 0.0
var _3d_pitch: float = -0.3
var _3d_distance: float = 5.0
var _3d_target: Vector3 = Vector3.ZERO


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

	# Centered panel — wide, because we put renderer + metadata
	# side-by-side and a 1024-px image needs some room.
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
	_header_label.text = "Asset Preview"
	_header_label.add_theme_font_size_override("font_size", 18)
	_vbox.add_child(_header_label)

	# Body: renderer on the left, metadata on the right.
	_body_hbox = HBoxContainer.new()
	_body_hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body_hbox.add_theme_constant_override("separation", 10)
	_vbox.add_child(_body_hbox)

	_content_holder = PanelContainer.new()
	_content_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content_holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body_hbox.add_child(_content_holder)

	_metadata_panel = PanelContainer.new()
	_metadata_panel.custom_minimum_size = Vector2(240, 0)
	_metadata_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body_hbox.add_child(_metadata_panel)

	_metadata_label = Label.new()
	_metadata_label.text = ""
	_metadata_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_metadata_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_metadata_panel.add_child(_metadata_label)

	# Footer.
	_footer = HBoxContainer.new()
	_footer.alignment = BoxContainer.ALIGNMENT_END
	_footer.add_theme_constant_override("separation", 8)
	_vbox.add_child(_footer)

	_close_button = Button.new()
	_close_button.text = "Close"
	_close_button.pressed.connect(_on_close_pressed)
	_footer.add_child(_close_button)

	_delete_button = Button.new()
	_delete_button.text = "Delete"
	_delete_button.pressed.connect(_on_delete_pressed)
	_footer.add_child(_delete_button)

	visible = false


# ---------- Public API ----------

func bind(orch: Node) -> void:
	_orch = orch

# Surface the preview for the given asset_id. If the lookup fails or
# the underlying file is missing, we render an error message rather
# than refusing to open — the user can at least see the metadata and
# Delete the orphaned row.
func show_for_asset(asset_id: String) -> void:
	_clear_renderer()
	_current_asset_id = asset_id
	_current_renderer_type = ""

	if _orch == null or _orch.asset_manager == null:
		_render_error("no asset manager bound (internal error)")
		visible = true
		return
	var asset: Dictionary = _orch.asset_manager.get_asset(asset_id)
	if asset.is_empty():
		_render_error("asset not found: %s" % asset_id)
		visible = true
		return

	_header_label.text = "%s / %s" % [
		str(asset.get("asset_type", "?")).to_upper(),
		str(asset.get("format", "?"))]
	_metadata_label.text = _format_metadata(asset)

	var asset_type: String = str(asset.get("asset_type", ""))
	var path: String = str(asset.get("local_path", ""))
	match asset_type:
		"text":
			_render_text(path)
		"image":
			_render_image(path)
		"audio":
			_render_audio(path, str(asset.get("format", "mp3")))
		"3d":
			_render_3d(path)
		_:
			_render_error("unknown asset type '%s'" % asset_type)
	visible = true


# ---------- Rendering ----------

func _clear_renderer() -> void:
	# Stop any in-flight audio before tearing the renderer down — losing
	# the player without stop() leaves the AudioServer holding a freed
	# stream reference until its own cleanup catches up.
	if _audio_player != null and _audio_player.playing:
		_audio_player.stop()
	_audio_player = null
	_audio_path = ""
	# 3D renderer state. Member references will dangle as soon as the
	# subviewport child is freed below, so null them first.
	_3d_subviewport = null
	_3d_camera = null
	# Free immediately (not queue_free) for the same orphan-tracker
	# reason ADR 011 documented for credential_editor.
	for child in _content_holder.get_children():
		_content_holder.remove_child(child)
		child.free()

func _render_error(message: String) -> void:
	var lbl := Label.new()
	lbl.text = message
	lbl.modulate = Color(1.0, 0.45, 0.45, 1.0)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content_holder.add_child(lbl)
	_current_renderer_type = "error"

func _render_text(path: String) -> void:
	if path.is_empty() or not FileAccess.file_exists(path):
		_render_error("text file not found: %s" % path)
		return
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		_render_error("cannot open text file: %s" % path)
		return
	var content: String = f.get_as_text()
	f.close()
	var view := TextEdit.new()
	view.text = content
	view.editable = false
	view.scroll_fit_content_height = false
	view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content_holder.add_child(view)
	_current_renderer_type = "text"

func _render_image(path: String) -> void:
	if path.is_empty() or not FileAccess.file_exists(path):
		_render_error("image file not found: %s" % path)
		return
	var img: Image = Image.new()
	var err: Error = img.load(path)
	if err != OK:
		_render_error("image decode failed (%s): %s" % [error_string(err), path])
		return
	var tex: ImageTexture = ImageTexture.create_from_image(img)
	var view := TextureRect.new()
	view.texture = tex
	view.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content_holder.add_child(view)
	_current_renderer_type = "image"

func _render_audio(path: String, fmt: String) -> void:
	if path.is_empty() or not FileAccess.file_exists(path):
		_render_error("audio file not found: %s" % path)
		return
	# AudioStreamMP3 covers ElevenLabs (the only real audio plugin
	# today). Other formats land as an error until we explicitly add
	# a renderer for them.
	if fmt.to_lower() != "mp3":
		_render_error("audio format '%s' not yet supported in preview" % fmt)
		return

	# Probe size without reading bytes. We defer the actual byte load
	# until Play — see _on_play_pressed and the _audio_path docstring.
	var size_bytes: int = 0
	var probe: FileAccess = FileAccess.open(path, FileAccess.READ)
	if probe != null:
		size_bytes = probe.get_length()
		probe.close()
	else:
		_render_error("cannot open audio file: %s" % path)
		return

	_audio_path = path

	var stream := AudioStreamMP3.new()
	# Intentionally do NOT assign stream.data here. The MP3 decoder
	# validates on assignment and push_errors on malformed input,
	# which a) trips GUT's error tracker for fixtures with fake bytes
	# and b) loads the whole file into memory the moment we open the
	# preview. _on_play_pressed populates stream.data lazily.

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content_holder.add_child(vbox)

	var info := Label.new()
	info.text = "Audio: %s\n%d bytes" % [path.get_file(), size_bytes]
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(info)

	_audio_player = AudioStreamPlayer.new()
	_audio_player.stream = stream
	vbox.add_child(_audio_player)

	var transport := HBoxContainer.new()
	transport.add_theme_constant_override("separation", 8)
	vbox.add_child(transport)

	var play_btn := Button.new()
	play_btn.text = "Play"
	play_btn.pressed.connect(_on_play_pressed)
	transport.add_child(play_btn)

	var stop_btn := Button.new()
	stop_btn.text = "Stop"
	stop_btn.pressed.connect(_on_stop_pressed)
	transport.add_child(stop_btn)

	_current_renderer_type = "audio"

func _render_3d(path: String) -> void:
	# Always build the SubViewport scaffolding even if the GLB is
	# missing — that way the viewport has a camera + lights ready
	# whenever a future "Reload" affordance lands, and a hint Label
	# can sit alongside the empty viewport.
	#
	# Reset orbital state so re-opening different assets doesn't
	# inherit the previous one's camera angles.
	_3d_yaw = 0.0
	_3d_pitch = -0.3
	_3d_distance = 5.0
	_3d_target = Vector3.ZERO

	var container := SubViewportContainer.new()
	container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	container.stretch = true
	container.custom_minimum_size = Vector2(320, 240)
	# Orbital-camera input on the container (the SubViewport itself
	# doesn't take Control input).
	container.gui_input.connect(_on_3d_gui_input)
	_content_holder.add_child(container)

	_3d_subviewport = SubViewport.new()
	_3d_subviewport.size = Vector2i(640, 480)
	# Own world so the scene we load doesn't leak into the rest of
	# the app (we don't have any other 3D world today, but we will
	# once scene-tester lands).
	_3d_subviewport.own_world_3d = true
	container.add_child(_3d_subviewport)

	# Ambient + a single directional key light. Enough to make a
	# vanilla glTF look reasonable without having to author a
	# lighting rig.
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.4, 0.4, 0.5, 1.0)
	env.ambient_light_energy = 1.0
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.05, 0.05, 0.07, 1.0)
	env_node.environment = env
	_3d_subviewport.add_child(env_node)

	var key_light := DirectionalLight3D.new()
	key_light.rotation = Vector3(deg_to_rad(-45.0), deg_to_rad(30.0), 0.0)
	key_light.light_energy = 1.0
	_3d_subviewport.add_child(key_light)

	_3d_camera = Camera3D.new()
	_3d_camera.current = true
	_3d_subviewport.add_child(_3d_camera)
	_update_3d_camera()

	# Try to load the .glb. We pre-check existence so a bogus path
	# doesn't drop into GLTFDocument's own error path (which can
	# push_error) — same defensive pattern as _render_audio.
	if path.is_empty() or not FileAccess.file_exists(path):
		_overlay_3d_message(container, "3D file not found:\n%s" % path)
	else:
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		var err: Error = doc.append_from_file(path, state)
		if err != OK:
			_overlay_3d_message(container,
				"GLTF load failed (%s): %s" % [error_string(err), path])
		else:
			var scene: Node = doc.generate_scene(state)
			if scene == null:
				_overlay_3d_message(container, "GLTF produced no scene")
			else:
				_3d_subviewport.add_child(scene)

	_current_renderer_type = "3d"

# Recompute camera position from spherical orbital state. Called on
# initial render and after every input event that mutates the angles.
func _update_3d_camera() -> void:
	if _3d_camera == null:
		return
	var x: float = cos(_3d_pitch) * sin(_3d_yaw) * _3d_distance
	var y: float = sin(_3d_pitch) * _3d_distance
	var z: float = cos(_3d_pitch) * cos(_3d_yaw) * _3d_distance
	_3d_camera.position = _3d_target + Vector3(x, y, z)
	_3d_camera.look_at(_3d_target, Vector3.UP)

# Drop a small Label on top of the viewport with a status / error
# message. Used when we can't actually render a model — the empty
# viewport behind it still works, so the user sees the lighting and
# can confirm the rest of the renderer is alive.
func _overlay_3d_message(parent: Control, msg: String) -> void:
	var lbl := Label.new()
	lbl.text = msg
	lbl.modulate = Color(1.0, 0.6, 0.6, 1.0)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# Place at the top of the viewport — without anchors we'd get
	# top-left at (0,0), which is what we want.
	parent.add_child(lbl)

# Orbital camera input handler. Called by the SubViewportContainer's
# gui_input signal. Mouse drag (left button) rotates; scroll zooms.
func _on_3d_gui_input(event: InputEvent) -> void:
	if _3d_camera == null:
		return
	if event is InputEventMouseMotion:
		var motion: InputEventMouseMotion = event
		if motion.button_mask & MOUSE_BUTTON_MASK_LEFT != 0:
			_3d_yaw -= motion.relative.x * 0.01
			# Clamp pitch so the camera never flips through the poles —
			# clamping at ~85° degrees keeps `look_at(UP)` stable.
			_3d_pitch = clamp(_3d_pitch + motion.relative.y * 0.01,
				deg_to_rad(-85.0), deg_to_rad(85.0))
			_update_3d_camera()
	elif event is InputEventMouseButton:
		var btn: InputEventMouseButton = event
		if btn.pressed:
			if btn.button_index == MOUSE_BUTTON_WHEEL_UP:
				_3d_distance = max(0.5, _3d_distance - 0.5)
				_update_3d_camera()
			elif btn.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_3d_distance = min(50.0, _3d_distance + 0.5)
				_update_3d_camera()


# ---------- Metadata ----------

func _format_metadata(asset: Dictionary) -> String:
	var lines: Array = []
	lines.append("id: %s" % str(asset.get("id", "")))
	lines.append("type: %s" % str(asset.get("asset_type", "")))
	lines.append("format: %s" % str(asset.get("format", "")))
	lines.append("plugin: %s" % str(asset.get("source_plugin", "")))
	lines.append("task: %s" % str(asset.get("source_task_id", "")))
	var prompt: String = str(asset.get("prompt", ""))
	if not prompt.is_empty():
		lines.append("prompt: %s" % prompt)
	lines.append("path: %s" % str(asset.get("local_path", "")))
	lines.append("size: %s" % _format_size(int(asset.get("size_bytes", 0))))
	if float(asset.get("cost", 0.0)) > 0.0:
		lines.append("cost: $%.6f" % float(asset["cost"]))
	var created: int = int(asset.get("created_at", 0))
	if created > 0:
		# UTC ISO-ish; users who need localized timestamps can hover. We
		# don't pull in a date formatter for one row.
		var dt: Dictionary = Time.get_datetime_dict_from_unix_time(created)
		lines.append("created: %04d-%02d-%02d %02d:%02d UTC" % [
			int(dt.get("year", 0)), int(dt.get("month", 0)), int(dt.get("day", 0)),
			int(dt.get("hour", 0)), int(dt.get("minute", 0))])
	return "\n".join(lines)

func _format_size(size_bytes: int) -> String:
	if size_bytes < 1024:
		return "%d B" % size_bytes
	var size_kb: float = float(size_bytes) / 1024.0
	if size_kb < 1024.0:
		return "%.1f KB" % size_kb
	return "%.2f MB" % (size_kb / 1024.0)


# ---------- Handlers ----------

func _on_close_pressed() -> void:
	_clear_renderer()
	visible = false
	emit_signal("closed")

# Escape closes the preview, same as the Close button. Gated on visibility
# so a stray Esc somewhere else in the app doesn't fire us.
func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey:
		var key: InputEventKey = event as InputEventKey
		if key.pressed and not key.echo and key.keycode == KEY_ESCAPE:
			get_viewport().set_input_as_handled()
			_on_close_pressed()

func _on_delete_pressed() -> void:
	if _current_asset_id.is_empty():
		return
	var aid: String = _current_asset_id
	_clear_renderer()
	visible = false
	emit_signal("delete_requested", aid)

func _on_play_pressed() -> void:
	if _audio_player == null or _audio_player.stream == null:
		return
	# Lazy-load the bytes on first Play. This is the deferred half of
	# the pattern set up in _render_audio: AudioStreamMP3.data
	# push_errors on malformed input, so we delay the assignment until
	# the user explicitly asks for sound.
	var stream: AudioStreamMP3 = _audio_player.stream as AudioStreamMP3
	if stream != null and stream.data.is_empty() and not _audio_path.is_empty():
		var f: FileAccess = FileAccess.open(_audio_path, FileAccess.READ)
		if f == null:
			return
		stream.data = f.get_buffer(f.get_length())
		f.close()
	_audio_player.play()

func _on_stop_pressed() -> void:
	if _audio_player != null and _audio_player.playing:
		_audio_player.stop()
