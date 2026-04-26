# Unit tests for AssetManager. No network — remote-URL ingest is covered
# manually in tools/integration/smoke.gd (see test_rejects_unknown_type for
# the contract we verify here).
#
# Every test configures the manager to a unique test root under user:// so
# tests never touch real app data and don't interfere with each other.

extends GutTest

const AssetManagerScript = preload("res://scripts/asset_manager.gd")

var am
var test_root: String


func before_each():
	# Unique per-test root, scoped under user:// so Godot handles cleanup on
	# process exit. The counter handles multiple tests in the same ms.
	test_root = "user://test_assets_%d_%d" % [Time.get_ticks_msec(), randi() % 10000]
	am = AssetManagerScript.new()
	add_child_autofree(am)
	am.configure(test_root)

func after_each():
	# Best-effort cleanup — we also leave user:// to the OS, but deleting the
	# test root keeps the dev machine tidy between GUT runs.
	_rm_rf(ProjectSettings.globalize_path(test_root))


# ---------- ingest: text ----------

func test_ingest_text_creates_asset():
	var result: Dictionary = {
		"asset_type": "text",
		"format": "plain",
		"text": "hello, world",
		"cost": 0.0001,
		"plugin": "claude",
	}
	var r: Dictionary = await am.ingest("claude", "claude:abc", result, "say hello")
	assert_true(bool(r["success"]), str(r))
	var asset: Dictionary = r["asset"]
	assert_eq(str(asset["asset_type"]), "text")
	assert_eq(str(asset["format"]), "txt")
	assert_eq(str(asset["source_plugin"]), "claude")
	assert_eq(str(asset["source_task_id"]), "claude:abc")
	assert_eq(str(asset["prompt"]), "say hello")
	assert_eq(int(asset["size_bytes"]), 12)
	assert_gt(int(asset["created_at"]), 0)
	# File was written.
	assert_true(FileAccess.file_exists(str(asset["local_path"])),
				"text file not written at %s" % asset["local_path"])

func test_ingest_text_empty_fails():
	var r: Dictionary = await am.ingest("claude", "claude:xyz",
		{"asset_type": "text", "format": "plain", "text": ""})
	assert_false(bool(r["success"]))
	assert_eq(am.count(), 0)


# ---------- ingest: local binary ----------

func test_ingest_local_binary_copies_and_registers():
	# Write a fake audio file the "plugin" would have produced.
	var src_path: String = "%s/_fake_audio.mp3" % test_root
	_write_file(src_path, "FAKE_MP3_BYTES".to_utf8_buffer())
	var result: Dictionary = {
		"asset_type": "audio",
		"format": "mp3",
		"path": src_path,
		"cost": 0.002,
		"plugin": "elevenlabs",
	}
	var r: Dictionary = await am.ingest("elevenlabs", "elevenlabs:t1", result, "hello")
	assert_true(bool(r["success"]), str(r))
	var asset: Dictionary = r["asset"]
	assert_eq(str(asset["asset_type"]), "audio")
	assert_eq(str(asset["format"]), "mp3")
	assert_true(FileAccess.file_exists(str(asset["local_path"])))

func test_ingest_binary_rejects_non_user_path():
	var r: Dictionary = await am.ingest("elevenlabs", "t1",
		{"asset_type": "audio", "format": "mp3", "path": "/etc/passwd"})
	assert_false(bool(r["success"]))

func test_ingest_binary_rejects_missing_source():
	var r: Dictionary = await am.ingest("elevenlabs", "t1",
		{"asset_type": "audio", "format": "mp3", "path": "%s/does_not_exist.mp3" % test_root})
	assert_false(bool(r["success"]))


# ---------- ingest: dedup ----------

func test_ingest_identical_content_deduplicates():
	var r1: Dictionary = await am.ingest("claude", "t1",
		{"asset_type": "text", "format": "plain", "text": "identical output"})
	var r2: Dictionary = await am.ingest("claude", "t2",
		{"asset_type": "text", "format": "plain", "text": "identical output"})
	assert_true(bool(r1["success"]))
	assert_true(bool(r2["success"]))
	assert_eq(str(r1["asset_id"]), str(r2["asset_id"]), "different asset_ids for same content")
	assert_false(bool(r1.get("deduplicated", false)))
	assert_true(bool(r2.get("deduplicated", false)))
	assert_eq(am.count(), 1)

func test_ingest_different_content_produces_different_ids():
	var r1: Dictionary = await am.ingest("claude", "t1",
		{"asset_type": "text", "format": "plain", "text": "first"})
	var r2: Dictionary = await am.ingest("claude", "t2",
		{"asset_type": "text", "format": "plain", "text": "second"})
	assert_ne(str(r1["asset_id"]), str(r2["asset_id"]))
	assert_eq(am.count(), 2)


# ---------- asset type rejection ----------

func test_ingest_unknown_asset_type_fails():
	var r: Dictionary = await am.ingest("custom", "t1",
		{"asset_type": "hologram", "format": "holo", "path": "user://x"})
	assert_false(bool(r["success"]))


# ---------- query ----------

func test_get_asset_returns_copy():
	var r: Dictionary = await am.ingest("claude", "t",
		{"asset_type": "text", "format": "plain", "text": "x"})
	var aid: String = str(r["asset_id"])
	var a1: Dictionary = am.get_asset(aid)
	a1["mutated"] = true
	var a2: Dictionary = am.get_asset(aid)
	assert_false(a2.has("mutated"), "get_asset should return a copy")

func test_get_asset_unknown_returns_empty():
	assert_true(am.get_asset("doesnotexist").is_empty())

func test_list_assets_filters_by_type():
	await am.ingest("claude",     "t1", {"asset_type": "text",  "format": "plain", "text": "a"})
	await am.ingest("claude",     "t2", {"asset_type": "text",  "format": "plain", "text": "b"})
	# Make a binary entry.
	var src_path: String = "%s/_x.mp3" % test_root
	_write_file(src_path, "BIN".to_utf8_buffer())
	await am.ingest("elevenlabs", "t3",
		{"asset_type": "audio", "format": "mp3", "path": src_path})

	var texts: Array = am.list_assets({"asset_type": "text"})
	var audios: Array = am.list_assets({"asset_type": "audio"})
	assert_eq(texts.size(), 2)
	assert_eq(audios.size(), 1)
	assert_eq(am.list_assets().size(), 3)

func test_list_assets_filters_by_plugin():
	await am.ingest("claude",     "t1", {"asset_type": "text", "format": "plain", "text": "a"})
	await am.ingest("claude",     "t2", {"asset_type": "text", "format": "plain", "text": "b"})
	await am.ingest("anthropic",  "t3", {"asset_type": "text", "format": "plain", "text": "c"})
	assert_eq(am.list_assets({"plugin": "claude"}).size(), 2)
	assert_eq(am.list_assets({"plugin": "anthropic"}).size(), 1)


# ---------- delete ----------

func test_delete_removes_file_and_metadata():
	var r: Dictionary = await am.ingest("claude", "t",
		{"asset_type": "text", "format": "plain", "text": "delete me"})
	var aid: String = str(r["asset_id"])
	var path: String = str((r["asset"] as Dictionary)["local_path"])
	assert_true(FileAccess.file_exists(path))

	assert_true(am.delete_asset(aid))
	assert_false(FileAccess.file_exists(path))
	assert_true(am.get_asset(aid).is_empty())
	assert_eq(am.count(), 0)

func test_delete_unknown_returns_false():
	assert_false(am.delete_asset("does_not_exist"))


# ---------- persistence ----------

func test_index_persists_across_reconfigure():
	var r: Dictionary = await am.ingest("claude", "t",
		{"asset_type": "text", "format": "plain", "text": "persistent"})
	var aid: String = str(r["asset_id"])
	# Simulate app restart by pointing a fresh AssetManager at the same root.
	var am2 = AssetManagerScript.new()
	add_child_autofree(am2)
	am2.configure(test_root)
	var restored: Dictionary = am2.get_asset(aid)
	assert_false(restored.is_empty(), "index didn't reload from disk")
	assert_eq(str(restored["source_plugin"]), "claude")


# ---------- signals ----------

func test_asset_ingested_signal_fires():
	watch_signals(am)
	await am.ingest("claude", "t",
		{"asset_type": "text", "format": "plain", "text": "signal me"})
	assert_signal_emitted(am, "asset_ingested")

func test_asset_deleted_signal_fires():
	var r: Dictionary = await am.ingest("claude", "t",
		{"asset_type": "text", "format": "plain", "text": "byebye"})
	watch_signals(am)
	am.delete_asset(str(r["asset_id"]))
	assert_signal_emitted(am, "asset_deleted")


# ---------- test helpers ----------

func _write_file(path: String, bytes: PackedByteArray) -> void:
	var dir: String = path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	assert_not_null(f, "cannot write test fixture at %s" % path)
	f.store_buffer(bytes)
	f.close()

# Recursively remove a directory. Best-effort — swallows errors because
# test cleanup should never fail a test.
#
# Implementation note: we list the directory in a separate helper so the
# DirAccess refcount drops to zero before we recurse. Holding an open
# DirAccess handle across the recursive call kept it alive longer than
# necessary and tripped Godot's "ObjectDB leaked at exit" warning under
# some cleanup orderings.
func _rm_rf(absolute_dir: String) -> void:
	if not DirAccess.dir_exists_absolute(absolute_dir):
		return
	var entries: Dictionary = _list_dir_entries(absolute_dir)
	for f in (entries.get("files", []) as Array):
		DirAccess.remove_absolute(f)
	for sd in (entries.get("dirs", []) as Array):
		_rm_rf(sd)
	DirAccess.remove_absolute(absolute_dir)

# Returns {"files": [abs_path,...], "dirs": [abs_path,...]}. The DirAccess
# handle is local to this function and is freed when the function returns.
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
