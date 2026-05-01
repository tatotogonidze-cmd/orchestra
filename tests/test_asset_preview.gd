# Tests for asset_preview.gd. Exercises every renderer branch (text,
# image, audio, 3d, error) plus the Close / Delete handlers and the
# re-show case.
#
# We use a real Orchestrator so the AssetManager actually ingests fake
# assets to disk. Each test gets a unique test_root so the real
# `user://assets` directory is never touched.

extends GutTest

const AssetPreviewScript = preload("res://scripts/ui/asset_preview.gd")
const OrchestratorScript = preload("res://scripts/orchestrator.gd")

var _orch: Node
var _ed: Node
var _test_root: String


func before_each() -> void:
	_test_root = "user://_test_preview_%d_%d" % [
		Time.get_ticks_msec(), randi() % 100000]
	_orch = OrchestratorScript.new()
	add_child_autofree(_orch)
	_orch.asset_manager.configure(_test_root)
	_ed = AssetPreviewScript.new()
	add_child_autofree(_ed)
	_ed.bind(_orch)

func after_each() -> void:
	# Best-effort cleanup of the per-test root and any source fixtures
	# we wrote into user://.
	_rm_rf(ProjectSettings.globalize_path(_test_root))


# ---------- Build / structure ----------

func test_preview_builds_top_level_pieces():
	# All structural members exist after _ready.
	assert_not_null(_ed._panel, "_panel not built")
	assert_not_null(_ed._content_holder, "_content_holder not built")
	assert_not_null(_ed._metadata_label, "_metadata_label not built")
	assert_not_null(_ed._close_button, "_close_button not built")
	assert_not_null(_ed._delete_button, "_delete_button not built")

func test_preview_starts_hidden():
	assert_false(_ed.visible, "preview should start hidden until show_for_asset()")


# ---------- Error paths ----------

func test_show_for_unknown_asset_renders_error():
	_ed.show_for_asset("definitely-not-a-real-id")
	assert_true(_ed.visible)
	assert_eq(_ed._current_renderer_type, "error",
		"unknown asset should land on the error branch")
	# A label should now be in the content holder.
	assert_eq(_ed._content_holder.get_child_count(), 1)


# ---------- Text ----------

func test_show_for_text_asset_renders_text_view():
	var r: Dictionary = await _orch.asset_manager.ingest(
		"claude", "claude:t1",
		{"asset_type": "text", "format": "plain", "text": "preview me"},
		"say hi")
	assert_true(bool(r["success"]), str(r))
	_ed.show_for_asset(str(r["asset_id"]))
	assert_eq(_ed._current_renderer_type, "text")
	# The single child of _content_holder should be a TextEdit with our
	# text loaded.
	var view: Node = _ed._content_holder.get_child(0)
	assert_true(view is TextEdit, "text branch should produce a TextEdit")
	assert_eq((view as TextEdit).text, "preview me",
		"TextEdit content should match the ingested text")
	assert_false((view as TextEdit).editable,
		"text preview should be read-only")


# ---------- Image ----------

func test_show_for_image_asset_renders_texture_rect():
	# Author a real 1×1 PNG so Image.load() succeeds. The plugin would
	# normally produce this — we mock the producer side here.
	var src_path: String = "%s/_fixture_red.png" % _test_root
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_test_root))
	var img := Image.create(1, 1, false, Image.FORMAT_RGB8)
	img.set_pixel(0, 0, Color(1.0, 0.0, 0.0))
	var save_err: Error = img.save_png(src_path)
	assert_eq(save_err, OK, "PNG fixture write failed: %s" % error_string(save_err))

	var r: Dictionary = await _orch.asset_manager.ingest(
		"mock_image", "mock:img1",
		{"asset_type": "image", "format": "png", "path": src_path},
		"red dot")
	assert_true(bool(r["success"]), str(r))
	_ed.show_for_asset(str(r["asset_id"]))
	assert_eq(_ed._current_renderer_type, "image",
		"image asset should land on the image branch")
	var view: Node = _ed._content_holder.get_child(0)
	assert_true(view is TextureRect, "image branch should produce a TextureRect")
	assert_not_null((view as TextureRect).texture,
		"TextureRect should have a texture loaded")


# ---------- Audio ----------

func test_show_for_audio_asset_renders_audio_branch():
	# We don't validate the bytes are real mp3 — Godot's AudioStreamMP3
	# accepts arbitrary data on assignment; decoding only happens on play().
	# The point of this test is the branch + AudioStreamPlayer wiring.
	var src_path: String = "%s/_fixture.mp3" % _test_root
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_test_root))
	var f: FileAccess = FileAccess.open(src_path, FileAccess.WRITE)
	f.store_buffer(PackedByteArray([0xFF, 0xFB, 0x00, 0x00, 0x42, 0x42, 0x42, 0x42]))
	f.close()

	var r: Dictionary = await _orch.asset_manager.ingest(
		"elevenlabs", "el:a1",
		{"asset_type": "audio", "format": "mp3", "path": src_path},
		"hi")
	assert_true(bool(r["success"]), str(r))
	_ed.show_for_asset(str(r["asset_id"]))
	assert_eq(_ed._current_renderer_type, "audio")
	# AudioStreamPlayer should be tracked on the preview for Stop to
	# address. The actual node lives somewhere inside _content_holder.
	assert_not_null(_ed._audio_player,
		"audio branch should populate _audio_player")
	assert_true(_ed._audio_player.stream is AudioStreamMP3,
		"audio player stream should be AudioStreamMP3")

func test_audio_unsupported_format_renders_error():
	# Inject metadata directly so we can hit the "format != mp3" branch
	# without rigging up a fake .wav ingest.
	var fake_id: String = "fake_audio_wav"
	_orch.asset_manager._index[fake_id] = {
		"id": fake_id,
		"asset_type": "audio",
		"format": "wav",
		"local_path": "%s/_fake.wav" % _test_root,
		"size_bytes": 0,
		"source_plugin": "test",
		"source_task_id": "test:0",
		"prompt": "",
		"cost": 0.0,
		"created_at": 0,
	}
	# Touch the file so the existence check passes — _render_audio
	# specifically rejects on format AFTER existence.
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_test_root))
	var f: FileAccess = FileAccess.open(
		"%s/_fake.wav" % _test_root, FileAccess.WRITE)
	f.store_string("not a wav, just a fixture")
	f.close()
	_ed.show_for_asset(fake_id)
	assert_eq(_ed._current_renderer_type, "error",
		"unsupported audio format should hit the error branch")


# ---------- 3D ----------

func test_show_for_3d_asset_builds_subviewport_scaffolding():
	# Phase 21: the 3d renderer always builds a SubViewport + camera +
	# light hierarchy. With a missing file it ALSO drops a small
	# message Label on top of the empty viewport.
	var fake_id: String = "fake_3d_glb"
	_orch.asset_manager._index[fake_id] = {
		"id": fake_id,
		"asset_type": "3d",
		"format": "glb",
		"local_path": "%s/_fake.glb" % _test_root,
		"size_bytes": 0,
		"source_plugin": "tripo",
		"source_task_id": "tripo:0",
		"prompt": "a dragon",
		"cost": 0.0,
		"created_at": 0,
	}
	_ed.show_for_asset(fake_id)
	assert_eq(_ed._current_renderer_type, "3d")
	# Single direct child: the SubViewportContainer.
	assert_eq(_ed._content_holder.get_child_count(), 1)
	var container: Node = _ed._content_holder.get_child(0)
	assert_true(container is SubViewportContainer,
		"3d renderer should produce a SubViewportContainer")
	# Container holds the SubViewport (and an overlay Label since the
	# file is missing — that's two children).
	assert_eq(container.get_child_count(), 2)
	# Member refs populated.
	assert_not_null(_ed._3d_subviewport,
		"_3d_subviewport member should be set after a 3d render")
	assert_not_null(_ed._3d_camera,
		"_3d_camera member should be set after a 3d render")

func test_show_for_3d_asset_subviewport_has_camera_and_light():
	var fake_id: String = "fake_3d_glb_2"
	_orch.asset_manager._index[fake_id] = {
		"id": fake_id, "asset_type": "3d", "format": "glb",
		"local_path": "%s/_nope.glb" % _test_root, "size_bytes": 0,
		"source_plugin": "tripo", "source_task_id": "t",
		"prompt": "", "cost": 0.0, "created_at": 0,
	}
	_ed.show_for_asset(fake_id)
	# Walk the SubViewport's children — should include Camera3D,
	# DirectionalLight3D, WorldEnvironment in some order.
	var has_camera: bool = false
	var has_light: bool = false
	var has_env: bool = false
	for child in _ed._3d_subviewport.get_children():
		if child is Camera3D: has_camera = true
		if child is DirectionalLight3D: has_light = true
		if child is WorldEnvironment: has_env = true
	assert_true(has_camera, "subviewport should host a Camera3D")
	assert_true(has_light, "subviewport should host a DirectionalLight3D")
	assert_true(has_env, "subviewport should host a WorldEnvironment")
	# The camera should be the active one for this viewport.
	assert_true(_ed._3d_camera.current,
		"_3d_camera should be flagged current=true")

func test_3d_camera_initial_position_matches_orbital_state():
	var fake_id: String = "fake_3d_glb_pos"
	_orch.asset_manager._index[fake_id] = {
		"id": fake_id, "asset_type": "3d", "format": "glb",
		"local_path": "%s/_x.glb" % _test_root, "size_bytes": 0,
		"source_plugin": "tripo", "source_task_id": "t",
		"prompt": "", "cost": 0.0, "created_at": 0,
	}
	_ed.show_for_asset(fake_id)
	# Defaults: yaw=0, pitch=-0.3, distance=5, target=origin.
	# x = cos(-0.3)*sin(0)*5 = 0
	# y = sin(-0.3)*5 ≈ -1.477
	# z = cos(-0.3)*cos(0)*5 ≈ 4.776
	var pos: Vector3 = _ed._3d_camera.position
	assert_almost_eq(pos.x, 0.0, 0.001)
	assert_almost_eq(pos.y, sin(-0.3) * 5.0, 0.01)
	assert_almost_eq(pos.z, cos(-0.3) * 5.0, 0.01)

func test_3d_mouse_drag_rotates_camera():
	# Synthesize a left-button mouse motion. Camera should reorient
	# according to relative motion.
	var fake_id: String = "fake_3d_drag"
	_orch.asset_manager._index[fake_id] = {
		"id": fake_id, "asset_type": "3d", "format": "glb",
		"local_path": "%s/_x.glb" % _test_root, "size_bytes": 0,
		"source_plugin": "tripo", "source_task_id": "t",
		"prompt": "", "cost": 0.0, "created_at": 0,
	}
	_ed.show_for_asset(fake_id)
	var yaw_before: float = _ed._3d_yaw
	var pitch_before: float = _ed._3d_pitch
	var ev := InputEventMouseMotion.new()
	ev.relative = Vector2(50, 30)  # drag right + down
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT
	_ed._on_3d_gui_input(ev)
	assert_almost_eq(_ed._3d_yaw, yaw_before - 50 * 0.01, 0.001,
		"yaw should decrease by relative.x * 0.01 with left drag")
	assert_almost_eq(_ed._3d_pitch, pitch_before + 30 * 0.01, 0.001,
		"pitch should increase by relative.y * 0.01")

func test_3d_mouse_drag_without_left_button_is_ignored():
	var fake_id: String = "fake_3d_no_drag"
	_orch.asset_manager._index[fake_id] = {
		"id": fake_id, "asset_type": "3d", "format": "glb",
		"local_path": "%s/_x.glb" % _test_root, "size_bytes": 0,
		"source_plugin": "tripo", "source_task_id": "t",
		"prompt": "", "cost": 0.0, "created_at": 0,
	}
	_ed.show_for_asset(fake_id)
	var yaw_before: float = _ed._3d_yaw
	var ev := InputEventMouseMotion.new()
	ev.relative = Vector2(50, 30)
	ev.button_mask = 0  # no buttons held
	_ed._on_3d_gui_input(ev)
	assert_eq(_ed._3d_yaw, yaw_before,
		"motion without LMB held should not move the camera")

func test_3d_mouse_wheel_zoom():
	var fake_id: String = "fake_3d_zoom"
	_orch.asset_manager._index[fake_id] = {
		"id": fake_id, "asset_type": "3d", "format": "glb",
		"local_path": "%s/_x.glb" % _test_root, "size_bytes": 0,
		"source_plugin": "tripo", "source_task_id": "t",
		"prompt": "", "cost": 0.0, "created_at": 0,
	}
	_ed.show_for_asset(fake_id)
	var dist_before: float = _ed._3d_distance
	# Wheel up = zoom in = decrease distance.
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_WHEEL_UP
	up.pressed = true
	_ed._on_3d_gui_input(up)
	assert_almost_eq(_ed._3d_distance, dist_before - 0.5, 0.001)
	# Wheel down = zoom out.
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_WHEEL_DOWN
	down.pressed = true
	_ed._on_3d_gui_input(down)
	assert_almost_eq(_ed._3d_distance, dist_before, 0.001,
		"wheel up then down should net zero distance change")

func test_3d_pitch_clamped_to_avoid_pole_flip():
	var fake_id: String = "fake_3d_clamp"
	_orch.asset_manager._index[fake_id] = {
		"id": fake_id, "asset_type": "3d", "format": "glb",
		"local_path": "%s/_x.glb" % _test_root, "size_bytes": 0,
		"source_plugin": "tripo", "source_task_id": "t",
		"prompt": "", "cost": 0.0, "created_at": 0,
	}
	_ed.show_for_asset(fake_id)
	# Drag DOWN past the pole — pitch should clamp at +85° (~1.484 rad).
	var ev := InputEventMouseMotion.new()
	ev.relative = Vector2(0, 10000)
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT
	_ed._on_3d_gui_input(ev)
	assert_almost_eq(_ed._3d_pitch, deg_to_rad(85.0), 0.001,
		"pitch should clamp at +85° to keep look_at(UP) stable")

func test_3d_state_clears_on_renderer_swap():
	# Show 3d, then show text — the 3d member refs should null out.
	var fake_id: String = "fake_3d_swap"
	_orch.asset_manager._index[fake_id] = {
		"id": fake_id, "asset_type": "3d", "format": "glb",
		"local_path": "%s/_x.glb" % _test_root, "size_bytes": 0,
		"source_plugin": "tripo", "source_task_id": "t",
		"prompt": "", "cost": 0.0, "created_at": 0,
	}
	_ed.show_for_asset(fake_id)
	assert_not_null(_ed._3d_subviewport)
	# Now show a text asset.
	var r: Dictionary = await _orch.asset_manager.ingest(
		"claude", "claude:tx",
		{"asset_type": "text", "format": "plain", "text": "hi"})
	_ed.show_for_asset(str(r["asset_id"]))
	assert_eq(_ed._current_renderer_type, "text")
	assert_null(_ed._3d_subviewport,
		"_3d_subviewport should null out after switching renderers")
	assert_null(_ed._3d_camera,
		"_3d_camera should null out after switching renderers")


# ---------- Close / Delete ----------

func test_close_button_emits_closed_and_hides():
	var r: Dictionary = await _orch.asset_manager.ingest(
		"claude", "claude:c1",
		{"asset_type": "text", "format": "plain", "text": "x"})
	_ed.show_for_asset(str(r["asset_id"]))
	assert_true(_ed.visible)
	watch_signals(_ed)
	_ed._on_close_pressed()
	assert_signal_emitted(_ed, "closed")
	assert_false(_ed.visible, "Close should hide the preview")

func test_delete_button_emits_delete_requested_with_asset_id():
	var r: Dictionary = await _orch.asset_manager.ingest(
		"claude", "claude:d1",
		{"asset_type": "text", "format": "plain", "text": "doomed"})
	var asset_id: String = str(r["asset_id"])
	_ed.show_for_asset(asset_id)
	watch_signals(_ed)
	_ed._on_delete_pressed()
	assert_signal_emitted(_ed, "delete_requested")
	assert_false(_ed.visible)
	# The signal should carry the asset_id we were previewing.
	var params: Array = get_signal_parameters(_ed, "delete_requested")
	assert_eq(params[0], asset_id,
		"delete_requested should carry the asset_id we were previewing")

func test_delete_with_no_current_asset_is_a_noop():
	# No show_for_asset called → _current_asset_id is empty. Pressing
	# Delete in that state should not emit and should not crash.
	watch_signals(_ed)
	_ed._on_delete_pressed()
	assert_signal_not_emitted(_ed, "delete_requested",
		"Delete should be a no-op when no asset is being previewed")


# ---------- Re-render ----------

func test_show_replaces_previous_renderer():
	# First show: text. Then show: 3d. The first text view must be gone.
	var r: Dictionary = await _orch.asset_manager.ingest(
		"claude", "claude:r1",
		{"asset_type": "text", "format": "plain", "text": "first"})
	_ed.show_for_asset(str(r["asset_id"]))
	assert_eq(_ed._current_renderer_type, "text")

	var fake_id: String = "fake_3d_for_replace"
	_orch.asset_manager._index[fake_id] = {
		"id": fake_id,
		"asset_type": "3d",
		"format": "glb",
		"local_path": "%s/x.glb" % _test_root,
		"size_bytes": 0,
		"source_plugin": "tripo",
		"source_task_id": "tripo:r",
		"prompt": "",
		"cost": 0.0,
		"created_at": 0,
	}
	_ed.show_for_asset(fake_id)
	assert_eq(_ed._current_renderer_type, "3d",
		"second show should swap the renderer type")
	# Only the new renderer should be present; the old TextEdit is gone.
	assert_eq(_ed._content_holder.get_child_count(), 1,
		"re-render should leave exactly one child in the content holder")


# ---------- Auto-frame AABB (Phase 30 / ADR 030) ----------

func _make_mesh_at(pos: Vector3, size: Vector3) -> MeshInstance3D:
	# Build a MeshInstance3D with a BoxMesh at the given world
	# position. Sized to the requested extent so the AABB walk has
	# something concrete to merge.
	var mesh := BoxMesh.new()
	mesh.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	return mi

func test_compute_aabb_for_node_returns_empty_when_no_meshes():
	var root := Node3D.new()
	add_child_autofree(root)
	var aabb: AABB = _ed._compute_aabb_for_node(root)
	assert_almost_eq(aabb.size.length(), 0.0, 0.001,
		"empty subtree should produce a zero-size AABB")

func test_compute_aabb_for_node_combines_multiple_meshes():
	var root := Node3D.new()
	add_child_autofree(root)
	# Two unit cubes 10 units apart along x.
	var a := _make_mesh_at(Vector3(0, 0, 0), Vector3.ONE)
	var b := _make_mesh_at(Vector3(10, 0, 0), Vector3.ONE)
	root.add_child(a)
	root.add_child(b)
	var aabb: AABB = _ed._compute_aabb_for_node(root)
	# Combined extent should span the two cubes:
	# x from -0.5 (a's left edge) to 10.5 (b's right edge) = 11
	assert_almost_eq(aabb.size.x, 11.0, 0.01,
		"combined AABB should span both meshes; got size: %s" % str(aabb.size))

func test_frame_camera_to_aabb_centers_target_and_sets_distance():
	# Build a 3d render scaffold so _3d_camera is non-null.
	var fake_id: String = "frame_aabb"
	_orch.asset_manager._index[fake_id] = {
		"id": fake_id, "asset_type": "3d", "format": "glb",
		"local_path": "%s/x.glb" % _test_root, "size_bytes": 0,
		"source_plugin": "tripo", "source_task_id": "t",
		"prompt": "", "cost": 0.0, "created_at": 0,
	}
	_ed.show_for_asset(fake_id)
	# Now apply auto-frame to a known AABB.
	var target_pos: Vector3 = Vector3(5, 2, -3)
	var aabb := AABB(target_pos, Vector3(2, 2, 2))
	_ed._frame_camera_to_aabb(aabb)
	assert_almost_eq(_ed._3d_target.x, 6.0, 0.01,
		"target should center on AABB.center; AABB.center.x = 5 + 2/2 = 6")
	assert_almost_eq(_ed._3d_target.y, 3.0, 0.01)
	assert_almost_eq(_ed._3d_target.z, -2.0, 0.01)
	# Distance should be > 0 (proportional to bounding sphere radius).
	assert_gt(_ed._3d_distance, 0.5,
		"frame should set a non-trivial camera distance; got: %f"
			% _ed._3d_distance)

func test_frame_camera_to_aabb_with_zero_size_keeps_default_distance():
	# Build the 3d scaffolding first.
	var fake_id: String = "frame_zero"
	_orch.asset_manager._index[fake_id] = {
		"id": fake_id, "asset_type": "3d", "format": "glb",
		"local_path": "%s/x.glb" % _test_root, "size_bytes": 0,
		"source_plugin": "tripo", "source_task_id": "t",
		"prompt": "", "cost": 0.0, "created_at": 0,
	}
	_ed.show_for_asset(fake_id)
	# Zero-size AABB at origin (a degenerate case).
	var aabb := AABB(Vector3.ZERO, Vector3.ZERO)
	_ed._frame_camera_to_aabb(aabb)
	assert_almost_eq(_ed._3d_distance, 5.0, 0.01,
		"zero-size AABB should fall back to the default distance")


# ---------- Esc-to-close (Phase 14) ----------

func test_escape_acts_like_close_when_visible():
	var r: Dictionary = await _orch.asset_manager.ingest(
		"claude", "claude:e1",
		{"asset_type": "text", "format": "plain", "text": "x"})
	_ed.show_for_asset(str(r["asset_id"]))
	assert_true(_ed.visible)
	watch_signals(_ed)
	var ev := InputEventKey.new()
	ev.keycode = KEY_ESCAPE
	ev.pressed = true
	_ed._unhandled_input(ev)
	assert_signal_emitted(_ed, "closed",
		"Esc should trigger Close when the preview is visible")
	assert_false(_ed.visible)

func test_escape_is_noop_when_hidden():
	# Preview built but never shown. Esc should be ignored.
	watch_signals(_ed)
	var ev := InputEventKey.new()
	ev.keycode = KEY_ESCAPE
	ev.pressed = true
	_ed._unhandled_input(ev)
	assert_signal_not_emitted(_ed, "closed")


# ---------- Metadata editor (Phase 43 / ADR 043) ----------

func _ingest_simple_text() -> String:
	var r: Dictionary = await _orch.asset_manager.ingest(
		"claude", "claude:meta-%d" % randi(),
		{"asset_type": "text", "format": "plain", "text": "edit me"},
		"original prompt")
	return str(r["asset_id"])

func test_metadata_editor_builds_inputs():
	# Members exist after _ready, regardless of whether an asset is shown.
	assert_not_null(_ed._display_name_input, "_display_name_input not built")
	assert_not_null(_ed._tags_input, "_tags_input not built")
	assert_not_null(_ed._prompt_input, "_prompt_input not built")
	assert_not_null(_ed._meta_save_button, "_meta_save_button not built")

func test_metadata_editor_prefills_on_show():
	var aid: String = await _ingest_simple_text()
	_orch.asset_manager.update_asset_metadata(aid, {
		"display_name": "Greeting",
		"tags": ["intro", "hero"],
	})
	_ed.show_for_asset(aid)
	assert_eq(_ed._display_name_input.text, "Greeting",
		"display_name should be pre-filled from the asset record")
	assert_eq(_ed._tags_input.text, "intro, hero",
		"tags should be comma-joined for editing")
	assert_eq(_ed._prompt_input.text, "original prompt",
		"prompt should be pre-filled")

func test_metadata_save_persists_changes():
	var aid: String = await _ingest_simple_text()
	_ed.show_for_asset(aid)
	_ed._display_name_input.text = "Renamed"
	_ed._tags_input.text = "alpha, beta, gamma"
	_ed._prompt_input.text = "fixed typo prompt"
	_ed._on_meta_save_pressed()
	# Verify via direct asset_manager read — round-trips the edit
	# through the disk + signal pipeline.
	var fetched: Dictionary = _orch.asset_manager.get_asset(aid)
	assert_eq(str(fetched["display_name"]), "Renamed")
	assert_eq((fetched["tags"] as Array).size(), 3,
		"three tags should land in the asset record")
	assert_eq(str(fetched["prompt"]), "fixed typo prompt")

func test_metadata_save_status_label_announces_success():
	var aid: String = await _ingest_simple_text()
	_ed.show_for_asset(aid)
	_ed._display_name_input.text = "Foo"
	_ed._on_meta_save_pressed()
	assert_eq(_ed._meta_save_status.text, "Saved",
		"status label should announce success after _on_meta_save_pressed")

func test_metadata_save_handles_empty_tags():
	# Empty input → empty tags array (not [""]).
	var aid: String = await _ingest_simple_text()
	_ed.show_for_asset(aid)
	_ed._tags_input.text = ""
	_ed._on_meta_save_pressed()
	var fetched: Dictionary = _orch.asset_manager.get_asset(aid)
	assert_eq((fetched["tags"] as Array).size(), 0,
		"empty tags input should produce empty array, not [\"\"]")

func test_metadata_save_strips_tag_whitespace():
	var aid: String = await _ingest_simple_text()
	_ed.show_for_asset(aid)
	_ed._tags_input.text = "  spaced  ,trim   ,  done"
	_ed._on_meta_save_pressed()
	var fetched: Dictionary = _orch.asset_manager.get_asset(aid)
	var tags: Array = fetched["tags"] as Array
	assert_eq(tags.size(), 3)
	assert_true(tags.has("spaced"))
	assert_true(tags.has("trim"))
	assert_true(tags.has("done"))

func test_metadata_save_without_asset_does_not_crash():
	# Defensive: pressing Save before an asset is selected.
	_ed._on_meta_save_pressed()
	assert_true("no asset" in _ed._meta_save_status.text,
		"status should guide the user; got: %s" % _ed._meta_save_status.text)


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
