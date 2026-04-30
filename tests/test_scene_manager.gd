# Tests for SceneManager. Each test gets a unique test root under
# user:// so the index file never collides with another run or the
# real user data. AssetManager is also stood up in some tests so the
# create_scene / add_asset_to_scene asset-existence guard has
# something to validate against.

extends GutTest

const SceneManagerScript = preload("res://scripts/scene_manager.gd")
const AssetManagerScript = preload("res://scripts/asset_manager.gd")

var sm
var test_root: String


func before_each() -> void:
	test_root = "user://test_scenes_%d_%d" % [Time.get_ticks_msec(), randi() % 10000]
	sm = SceneManagerScript.new()
	add_child_autofree(sm)
	sm.configure(test_root)

func after_each() -> void:
	_rm_rf(ProjectSettings.globalize_path(test_root))


# Helper: stand up an AssetManager under its own root and ingest one
# text asset for use as a known-good asset_id in scene tests. Returns
# (am, asset_id).
func _stand_up_asset() -> Dictionary:
	var am: Node = AssetManagerScript.new()
	add_child_autofree(am)
	am.configure("%s/_assets" % test_root)
	var r: Dictionary = await am.ingest("claude", "claude:t1",
		{"asset_type": "text", "format": "plain", "text": "x"}, "")
	return {"asset_manager": am, "asset_id": str(r["asset_id"])}


# ---------- Initial state ----------

func test_initial_state_is_empty():
	assert_eq(sm.count(), 0)
	assert_eq(sm.list_scenes().size(), 0)


# ---------- create_scene ----------

func test_create_scene_basic():
	watch_signals(sm)
	var r: Dictionary = sm.create_scene("My Scene")
	assert_true(bool(r["success"]))
	assert_true(r.has("scene_id"))
	assert_eq(r["scene"]["name"], "My Scene")
	assert_eq((r["scene"]["asset_ids"] as Array).size(), 0)
	assert_signal_emitted(sm, "scene_created")
	assert_eq(sm.count(), 1)

func test_create_scene_blank_name_rejected():
	var r: Dictionary = sm.create_scene("   ")
	assert_false(bool(r["success"]))
	assert_true("name required" in str(r["error"]))
	assert_eq(sm.count(), 0,
		"failed creates should not leave a scene record")

func test_create_scene_with_pre_populated_asset_ids():
	var ctx: Dictionary = await _stand_up_asset()
	var r: Dictionary = sm.create_scene("With assets",
		[ctx["asset_id"]], ctx["asset_manager"])
	assert_true(bool(r["success"]), str(r))
	assert_eq((r["scene"]["asset_ids"] as Array).size(), 1)
	assert_eq((r["scene"]["asset_ids"] as Array)[0], ctx["asset_id"])

func test_create_scene_with_unknown_asset_rejected():
	var ctx: Dictionary = await _stand_up_asset()
	var r: Dictionary = sm.create_scene("Bad",
		["asset_does_not_exist"], ctx["asset_manager"])
	assert_false(bool(r["success"]))
	assert_true("unknown asset" in str(r["error"]))
	assert_eq(sm.count(), 0,
		"failed validation should not leave a scene record")

func test_create_scene_skips_asset_check_when_manager_null():
	# Passing null bypasses the existence check — useful for tests and
	# for callers who've already validated.
	var r: Dictionary = sm.create_scene("Loose", ["asset_phantom"])
	assert_true(bool(r["success"]))
	assert_eq((r["scene"]["asset_ids"] as Array)[0], "asset_phantom")


# ---------- add_asset_to_scene ----------

func test_add_asset_to_scene_round_trip():
	var ctx: Dictionary = await _stand_up_asset()
	var c: Dictionary = sm.create_scene("S", [], null)
	var sid: String = c["scene_id"]
	watch_signals(sm)
	var r: Dictionary = sm.add_asset_to_scene(sid, ctx["asset_id"], ctx["asset_manager"])
	assert_true(bool(r["success"]))
	assert_eq((r["scene"]["asset_ids"] as Array)[0], ctx["asset_id"])
	assert_signal_emitted(sm, "scene_updated")

func test_add_asset_to_scene_idempotent():
	# Adding the same id twice should not grow the array — scenes
	# don't hold duplicates.
	var c: Dictionary = sm.create_scene("S", [], null)
	var sid: String = c["scene_id"]
	sm.add_asset_to_scene(sid, "asset_a")
	sm.add_asset_to_scene(sid, "asset_a")
	var s: Dictionary = sm.get_scene(sid)
	assert_eq((s["asset_ids"] as Array).size(), 1,
		"duplicate add should be idempotent, not append")

func test_add_asset_to_unknown_scene_fails():
	var r: Dictionary = sm.add_asset_to_scene("scene_nope", "asset_a")
	assert_false(bool(r["success"]))
	assert_true("unknown scene" in str(r["error"]))

func test_add_asset_with_unknown_asset_validated_when_manager_present():
	var ctx: Dictionary = await _stand_up_asset()
	var c: Dictionary = sm.create_scene("S", [], null)
	var r: Dictionary = sm.add_asset_to_scene(c["scene_id"],
		"asset_phantom", ctx["asset_manager"])
	assert_false(bool(r["success"]))
	assert_true("unknown asset" in str(r["error"]))


# ---------- remove_asset_from_scene ----------

func test_remove_asset_from_scene_round_trip():
	var c: Dictionary = sm.create_scene("S", ["asset_a", "asset_b"], null)
	var sid: String = c["scene_id"]
	watch_signals(sm)
	var r: Dictionary = sm.remove_asset_from_scene(sid, "asset_a")
	assert_true(bool(r["success"]))
	var assets: Array = r["scene"]["asset_ids"]
	assert_eq(assets.size(), 1)
	assert_eq(assets[0], "asset_b")
	assert_signal_emitted(sm, "scene_updated")

func test_remove_asset_not_in_scene_is_noop_success():
	var c: Dictionary = sm.create_scene("S", ["asset_a"], null)
	var r: Dictionary = sm.remove_asset_from_scene(c["scene_id"], "asset_phantom")
	assert_true(bool(r["success"]),
		"removing an absent id should succeed silently")
	assert_eq((r["scene"]["asset_ids"] as Array).size(), 1)

func test_remove_asset_from_unknown_scene_fails():
	var r: Dictionary = sm.remove_asset_from_scene("scene_nope", "asset_a")
	assert_false(bool(r["success"]))


# ---------- rename_scene ----------

func test_rename_scene():
	var c: Dictionary = sm.create_scene("Old", [], null)
	var sid: String = c["scene_id"]
	watch_signals(sm)
	var r: Dictionary = sm.rename_scene(sid, "New name")
	assert_true(bool(r["success"]))
	assert_eq(r["scene"]["name"], "New name")
	assert_signal_emitted(sm, "scene_updated")

func test_rename_scene_blank_rejected():
	var c: Dictionary = sm.create_scene("Old", [], null)
	var r: Dictionary = sm.rename_scene(c["scene_id"], "  ")
	assert_false(bool(r["success"]))
	assert_eq(sm.get_scene(c["scene_id"])["name"], "Old",
		"failed rename should leave the original name in place")


# ---------- delete_scene ----------

func test_delete_scene_returns_true_and_emits():
	var c: Dictionary = sm.create_scene("S", [], null)
	watch_signals(sm)
	assert_true(sm.delete_scene(c["scene_id"]))
	assert_signal_emitted(sm, "scene_deleted")
	assert_eq(sm.count(), 0)
	assert_eq(sm.get_scene(c["scene_id"]).size(), 0,
		"deleted scene should not be retrievable")

func test_delete_unknown_scene_returns_false():
	assert_false(sm.delete_scene("scene_nope"))


# ---------- list / get ----------

func test_list_scenes_newest_first():
	var first: Dictionary = sm.create_scene("First", [], null)
	# Force a 1ms gap so created_at differs deterministically.
	OS.delay_msec(2)
	var second: Dictionary = sm.create_scene("Second", [], null)
	var listed: Array = sm.list_scenes()
	assert_eq(listed.size(), 2)
	assert_eq(listed[0]["name"], "Second",
		"list_scenes should put the newest record first")
	assert_eq(listed[1]["name"], "First")

func test_get_scene_returns_copy():
	var c: Dictionary = sm.create_scene("S", ["asset_a"], null)
	var snap: Dictionary = sm.get_scene(c["scene_id"])
	# Mutate the returned dict; the manager's internal record must not change.
	(snap["asset_ids"] as Array).append("asset_tampered")
	var fresh: Dictionary = sm.get_scene(c["scene_id"])
	assert_eq((fresh["asset_ids"] as Array).size(), 1,
		"get_scene should return an independent copy")


# ---------- Persistence ----------

func test_index_persists_across_reconfigure():
	var c: Dictionary = sm.create_scene("Persisted", ["asset_a"], null)
	# New instance, same root → reload.
	var sm2 = SceneManagerScript.new()
	add_child_autofree(sm2)
	sm2.configure(test_root)
	var loaded: Dictionary = sm2.get_scene(c["scene_id"])
	assert_eq(loaded["name"], "Persisted")
	assert_eq((loaded["asset_ids"] as Array)[0], "asset_a")

func test_configure_resets_in_memory_index():
	sm.create_scene("Was", [], null)
	# Reconfigure to a fresh empty root; old in-memory index should drop.
	var fresh_root: String = "%s_alt" % test_root
	sm.configure(fresh_root)
	assert_eq(sm.count(), 0,
		"reconfigure should drop in-memory state and reload from new root")
	_rm_rf(ProjectSettings.globalize_path(fresh_root))


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
