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

func test_show_for_3d_asset_renders_placeholder():
	# 3D ingest is async / network; for this UI-only test we inject the
	# metadata directly. The renderer doesn't care that the local_path
	# is bogus — the placeholder branch reads no file.
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
	# Placeholder is a single Label child.
	assert_eq(_ed._content_holder.get_child_count(), 1)
	assert_true(_ed._content_holder.get_child(0) is Label)


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
