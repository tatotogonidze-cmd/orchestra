# Tests for GDDManager: validation, load/save round-trip, snapshot + rollback.

extends GutTest

const GDDManagerScript = preload("res://scripts/gdd_manager.gd")

var gm

func before_each():
	gm = GDDManagerScript.new()
	add_child_autofree(gm)
	# Redirect snapshot dir to a per-test location so tests are isolated.
	gm.snapshot_dir = "user://_test_snapshots_%d" % Time.get_ticks_msec()
	_rmdir_recursive(gm.snapshot_dir)

func after_each():
	_rmdir_recursive(gm.snapshot_dir)

func _minimal_valid_gdd() -> Dictionary:
	return {
		"schema_version": "1.0.0",
		"game_title": "Test Game",
		"genres": ["RPG"],
		"core_loop": {
			"goal": "survive",
			"actions": ["explore", "fight"],
			"rewards": ["xp"]
		},
		"mechanics": [
			{"id": "mech_combat", "description": "turn-based combat"}
		],
		"assets": [],
		"tasks": [],
		"metadata": {
			"document_version": "0.1.0",
			"created_at": "2026-04-24T10:00:00Z"
		}
	}

# ---------- Validation ----------

func test_validate_missing_required_reports_errors():
	var gdd = {"game_title": "incomplete"}
	var v = gm.validate(gdd)
	assert_false(bool(v["valid"]))
	assert_true(v["errors"].size() > 0)

func test_validate_minimal_valid_passes():
	var v = gm.validate(_minimal_valid_gdd())
	assert_true(bool(v["valid"]), "errors: %s" % str(v["errors"]))

func test_validate_rejects_unknown_root_field():
	var gdd = _minimal_valid_gdd()
	gdd["hack"] = "injected"
	var v = gm.validate(gdd)
	assert_false(bool(v["valid"]))
	var has_unknown = false
	for e in v["errors"]:
		if str(e).find("unknown root field") >= 0:
			has_unknown = true
			break
	assert_true(has_unknown, "expected an unknown-root-field error")

func test_validate_rejects_bad_id_prefix():
	var gdd = _minimal_valid_gdd()
	gdd["mechanics"].append({"id": "wrong_prefix_combat", "description": "x"})
	var v = gm.validate(gdd)
	assert_false(bool(v["valid"]))

# ---------- Load / Save round-trip ----------

func test_save_and_load_round_trip():
	var gdd = _minimal_valid_gdd()
	var path = "user://_test_gdd_%d.json" % Time.get_ticks_msec()
	var save_r = gm.save_gdd(gdd, path)
	assert_true(bool(save_r["success"]), "save failed: %s" % str(save_r))
	var load_r = gm.load_gdd(path)
	assert_true(bool(load_r["success"]))
	assert_eq(load_r["gdd"]["game_title"], gdd["game_title"])
	assert_eq(load_r["gdd"]["genres"], gdd["genres"])
	# cleanup
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

func test_save_rejects_invalid_gdd():
	var bad = {"game_title": "only this"}
	var r = gm.save_gdd(bad, "user://_should_not_exist.json")
	assert_false(bool(r["success"]))

# ---------- Snapshots ----------

func test_snapshot_created_on_save():
	var gdd = _minimal_valid_gdd()
	var path = "user://_test_gdd_snap.json"
	var r = gm.save_gdd(gdd, path)
	assert_true(bool(r["success"]))
	var snaps = gm.list_snapshots()
	assert_eq(snaps.size(), 1)
	assert_eq(int(snaps[0]["version"]), 1)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

func test_snapshots_linear_numbering():
	var gdd = _minimal_valid_gdd()
	var path = "user://_test_gdd_multi.json"
	for i in range(3):
		gdd["metadata"]["document_version"] = "0.%d.0" % i
		gm.save_gdd(gdd, path)
	var snaps = gm.list_snapshots()
	assert_eq(snaps.size(), 3)
	assert_eq(int(snaps[0]["version"]), 1)
	assert_eq(int(snaps[1]["version"]), 2)
	assert_eq(int(snaps[2]["version"]), 3)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

func test_rollback_returns_previous_snapshot():
	var gdd = _minimal_valid_gdd()
	var path = "user://_test_gdd_roll.json"
	gdd["game_title"] = "Version One"
	gm.save_gdd(gdd, path)
	gdd["game_title"] = "Version Two"
	gm.save_gdd(gdd, path)
	var roll = gm.rollback(1)
	assert_true(bool(roll["success"]))
	assert_eq(roll["gdd"]["game_title"], "Version One")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

# ---------- Cross-reference integrity (Phase 19) ----------

# Fixture with realistic cross-entity references all resolving cleanly.
# Tests mutate copies of this to exercise individual ref types.
func _xref_gdd() -> Dictionary:
	return {
		"schema_version": "1.0.0",
		"game_title": "XRef",
		"genres": ["RPG"],
		"core_loop": {
			"goal": "win",
			"actions": ["fight"],
			"rewards": ["xp"],
		},
		"mechanics": [
			{"id": "mech_a", "description": "A"},
			{"id": "mech_b", "description": "B", "dependencies": ["mech_a"]},
		],
		"assets": [
			{"id": "asset_a", "type": "Image", "path": "x.png",
				"status": "draft", "created_at": "2026-04-25T00:00:00Z"},
			{"id": "asset_b", "type": "Image", "path": "y.png",
				"status": "draft", "created_at": "2026-04-25T00:00:00Z",
				"parent_asset_id": "asset_a"},
		],
		"tasks": [
			{"id": "task_a", "title": "A", "status": "Ready",
				"created_at": "2026-04-25T00:00:00Z"},
			{"id": "task_b", "title": "B", "status": "Ready",
				"created_at": "2026-04-25T00:00:00Z",
				"dependencies": ["task_a"],
				"blocked_by": ["task_a"],
				"related_asset_ids": ["asset_a"],
				"related_mechanic_ids": ["mech_b"]},
		],
		"scenes": [
			{"id": "scene_a", "name": "Intro",
				"related_asset_ids": ["asset_a"]},
			{"id": "scene_b", "name": "Outro",
				"entry_points": [
					{"id": "ep_main", "from_scene_id": "scene_a"},
				]},
		],
		"characters": [
			{"id": "char_hero", "name": "Hero", "asset_id": "asset_a"},
		],
		"dialogues": [
			{"id": "dlg_intro", "character_id": "char_hero",
				"nodes": [{"id": "n0", "text": "hi"}]},
		],
		"metadata": {
			"document_version": "0.1.0",
			"created_at": "2026-04-25T00:00:00Z",
		},
	}


func test_xref_clean_fixture_validates():
	var v: Dictionary = gm.validate(_xref_gdd())
	assert_true(bool(v["valid"]),
		"all references resolve — fixture should be valid; errors: %s"
			% str(v["errors"]))

func test_xref_dangling_mechanic_dependency_flagged():
	var g: Dictionary = _xref_gdd()
	(g["mechanics"][1]["dependencies"] as Array).append("mech_nope")
	var v: Dictionary = gm.validate(g)
	assert_false(bool(v["valid"]))
	var found: bool = false
	for e in v["errors"]:
		if "mech_b" in str(e) and "mech_nope" in str(e):
			found = true
			break
	assert_true(found, "errors should call out mech_b → mech_nope; got: %s"
		% str(v["errors"]))

func test_xref_dangling_task_dependency_flagged():
	var g: Dictionary = _xref_gdd()
	(g["tasks"][1]["dependencies"] as Array).append("task_nope")
	var v: Dictionary = gm.validate(g)
	assert_false(bool(v["valid"]))
	var has_msg: bool = false
	for e in v["errors"]:
		if "task_b" in str(e) and "task_nope" in str(e):
			has_msg = true
			break
	assert_true(has_msg)

func test_xref_dangling_task_blocked_by_flagged():
	var g: Dictionary = _xref_gdd()
	g["tasks"][1]["blocked_by"] = ["task_ghost"]
	var v: Dictionary = gm.validate(g)
	assert_false(bool(v["valid"]))
	var found: bool = false
	for e in v["errors"]:
		if "task_ghost" in str(e):
			found = true
			break
	assert_true(found)

func test_xref_dangling_task_related_asset_flagged():
	var g: Dictionary = _xref_gdd()
	g["tasks"][1]["related_asset_ids"] = ["asset_missing"]
	var v: Dictionary = gm.validate(g)
	assert_false(bool(v["valid"]))
	var found: bool = false
	for e in v["errors"]:
		if "asset_missing" in str(e):
			found = true
			break
	assert_true(found)

func test_xref_dangling_task_related_mechanic_flagged():
	var g: Dictionary = _xref_gdd()
	g["tasks"][1]["related_mechanic_ids"] = ["mech_missing"]
	var v: Dictionary = gm.validate(g)
	assert_false(bool(v["valid"]))
	var found: bool = false
	for e in v["errors"]:
		if "mech_missing" in str(e):
			found = true
			break
	assert_true(found)

func test_xref_dangling_scene_related_asset_flagged():
	var g: Dictionary = _xref_gdd()
	g["scenes"][0]["related_asset_ids"] = ["asset_ghost"]
	var v: Dictionary = gm.validate(g)
	assert_false(bool(v["valid"]))
	var found: bool = false
	for e in v["errors"]:
		if "asset_ghost" in str(e):
			found = true
			break
	assert_true(found)

func test_xref_dangling_scene_entry_point_flagged():
	var g: Dictionary = _xref_gdd()
	g["scenes"][1]["entry_points"][0]["from_scene_id"] = "scene_ghost"
	var v: Dictionary = gm.validate(g)
	assert_false(bool(v["valid"]))
	var found: bool = false
	for e in v["errors"]:
		if "scene_ghost" in str(e):
			found = true
			break
	assert_true(found)

func test_xref_dangling_character_asset_flagged():
	var g: Dictionary = _xref_gdd()
	g["characters"][0]["asset_id"] = "asset_nope"
	var v: Dictionary = gm.validate(g)
	assert_false(bool(v["valid"]))
	var found: bool = false
	for e in v["errors"]:
		if "char_hero" in str(e) and "asset_nope" in str(e):
			found = true
			break
	assert_true(found)

func test_xref_dangling_dialogue_character_flagged():
	var g: Dictionary = _xref_gdd()
	g["dialogues"][0]["character_id"] = "char_nope"
	var v: Dictionary = gm.validate(g)
	assert_false(bool(v["valid"]))
	var found: bool = false
	for e in v["errors"]:
		if "char_nope" in str(e):
			found = true
			break
	assert_true(found)

func test_xref_null_parent_asset_id_is_ok():
	# Schema allows parent_asset_id: null. Cross-ref check should
	# treat null as "no reference".
	var g: Dictionary = _xref_gdd()
	g["assets"][1]["parent_asset_id"] = null
	var v: Dictionary = gm.validate(g)
	assert_true(bool(v["valid"]),
		"null parent_asset_id should be accepted; errors: %s"
			% str(v["errors"]))

func test_xref_missing_asset_id_on_character_is_ok():
	# asset_id is optional on characters. Omitting it should not
	# trigger a cross-ref error.
	var g: Dictionary = _xref_gdd()
	g["characters"][0].erase("asset_id")
	var v: Dictionary = gm.validate(g)
	assert_true(bool(v["valid"]),
		"omitted asset_id should be valid; errors: %s" % str(v["errors"]))

func test_xref_multiple_errors_aggregated():
	# Break two unrelated references; both should appear in the
	# error list.
	var g: Dictionary = _xref_gdd()
	(g["tasks"][1]["dependencies"] as Array).append("task_a_nope")
	g["characters"][0]["asset_id"] = "asset_a_nope"
	var v: Dictionary = gm.validate(g)
	assert_false(bool(v["valid"]))
	var has_task_err: bool = false
	var has_char_err: bool = false
	for e in v["errors"]:
		if "task_a_nope" in str(e):
			has_task_err = true
		if "asset_a_nope" in str(e):
			has_char_err = true
	assert_true(has_task_err and has_char_err,
		"both bad refs should be reported; got: %s" % str(v["errors"]))

func test_xref_empty_arrays_are_fine():
	# A task with `dependencies: []` should not produce a cross-ref
	# error — empty array means "no dependencies" not "unresolved".
	var g: Dictionary = _xref_gdd()
	g["tasks"][1]["dependencies"] = []
	g["tasks"][1]["blocked_by"] = []
	g["tasks"][1]["related_asset_ids"] = []
	g["tasks"][1]["related_mechanic_ids"] = []
	var v: Dictionary = gm.validate(g)
	assert_true(bool(v["valid"]),
		"empty reference arrays should be valid; errors: %s"
			% str(v["errors"]))


# ---------- clean_dangling_references (Phase 29 / ADR 029) ----------

func test_clean_dangling_no_changes_on_valid_gdd():
	var r: Dictionary = gm.clean_dangling_references(_xref_gdd())
	assert_true(bool(r["success"]))
	assert_eq(int(r["removed_count"]), 0,
		"clean shouldn't remove anything from an already-valid GDD")

func test_clean_dangling_removes_array_refs():
	var g: Dictionary = _xref_gdd()
	(g["tasks"][1]["dependencies"] as Array).append("task_nope")
	(g["tasks"][1]["related_asset_ids"] as Array).append("asset_nope")
	var r: Dictionary = gm.clean_dangling_references(g)
	assert_true(bool(r["success"]))
	assert_eq(int(r["removed_count"]), 2,
		"two dangling array entries should be removed")
	# Cleaned GDD revalidates.
	var v: Dictionary = gm.validate(r["gdd"])
	assert_true(bool(v["valid"]),
		"cleaned GDD should pass validation; errors: %s" % str(v["errors"]))

func test_clean_dangling_clears_scalar_ref():
	var g: Dictionary = _xref_gdd()
	g["assets"][1]["parent_asset_id"] = "asset_nope"
	var r: Dictionary = gm.clean_dangling_references(g)
	assert_eq(int(r["removed_count"]), 1)
	# parent_asset_id key should be erased entirely.
	var asset: Dictionary = (r["gdd"]["assets"] as Array)[1]
	assert_false(asset.has("parent_asset_id"),
		"dangling scalar ref should be erased, not nulled or zero'd")

func test_clean_dangling_does_not_mutate_caller():
	# Pure function — the original GDD should be unchanged.
	var g: Dictionary = _xref_gdd()
	(g["tasks"][1]["dependencies"] as Array).append("task_nope")
	var original_size: int = (g["tasks"][1]["dependencies"] as Array).size()
	gm.clean_dangling_references(g)
	assert_eq((g["tasks"][1]["dependencies"] as Array).size(), original_size,
		"clean should not mutate the input GDD")

func test_clean_dangling_preserves_unrelated_fields():
	# Confidence test: cleaning shouldn't touch genres, core_loop,
	# scalar metadata, etc.
	var g: Dictionary = _xref_gdd()
	g["characters"][0]["asset_id"] = "asset_nope"
	var r: Dictionary = gm.clean_dangling_references(g)
	var cleaned: Dictionary = r["gdd"]
	assert_eq(cleaned["game_title"], "XRef")
	assert_eq((cleaned["genres"] as Array)[0], "RPG")
	# The character's name should survive even though asset_id was
	# pruned.
	assert_eq((cleaned["characters"] as Array)[0]["name"], "Hero")

func test_clean_dangling_handles_multiple_per_record():
	# Same task with multiple dangling refs in different fields.
	var g: Dictionary = _xref_gdd()
	(g["tasks"][1]["dependencies"] as Array).append("task_phantom_a")
	(g["tasks"][1]["dependencies"] as Array).append("task_phantom_b")
	(g["tasks"][1]["blocked_by"] as Array).append("task_phantom_c")
	var r: Dictionary = gm.clean_dangling_references(g)
	assert_eq(int(r["removed_count"]), 3,
		"all dangling entries across all fields should be counted")


# ---------- Markdown export (Phase 34 / ADR 034) ----------

func test_export_to_markdown_returns_non_empty_string():
	var md: String = gm.export_to_markdown(_minimal_valid_gdd())
	assert_true(md.length() > 0,
		"converter should always emit at least the heading")
	assert_true(md.begins_with("#"),
		"markdown should start with a heading; got: %s" % md.substr(0, 40))

func test_export_includes_title_from_metadata():
	var g: Dictionary = _minimal_valid_gdd()
	(g["metadata"] as Dictionary)["title"] = "Hero's Journey"
	var md: String = gm.export_to_markdown(g)
	assert_true("# Hero's Journey" in md,
		"title from metadata.title should be the heading; got: %s"
			% md.substr(0, 80))

func test_export_falls_back_to_default_title():
	var md: String = gm.export_to_markdown(_minimal_valid_gdd())
	assert_true("# Game Design Document" in md,
		"absent metadata.title should produce default heading")

func test_export_renders_mechanics_section():
	var md: String = gm.export_to_markdown(_minimal_valid_gdd())
	assert_true("## Mechanics" in md,
		"mechanics section should be rendered when array non-empty")
	assert_true("mech_combat" in md, "mechanic id should be in output")
	assert_true("turn-based combat" in md, "mechanic description should be in output")

func test_export_skips_empty_sections():
	var md: String = gm.export_to_markdown(_minimal_valid_gdd())
	# minimal fixture has empty assets/tasks and no scenes/chars/dialogues
	assert_false("## Assets" in md,
		"empty assets array should NOT produce a section")
	assert_false("## Tasks" in md,
		"empty tasks array should NOT produce a section")
	assert_false("## Scenes" in md,
		"absent scenes should NOT produce a section")

func test_export_renders_full_xref_fixture():
	var md: String = gm.export_to_markdown(_xref_gdd())
	# Every entity type in the xref fixture should produce a section.
	assert_true("## Mechanics" in md, "mechanics section expected")
	assert_true("## Assets" in md, "assets section expected")
	assert_true("## Tasks" in md, "tasks section expected")
	assert_true("## Scenes" in md, "scenes section expected")
	assert_true("## Characters" in md, "characters section expected")
	assert_true("## Dialogues" in md, "dialogues section expected")

func test_export_includes_character_name_and_role():
	var g: Dictionary = _xref_gdd()
	(g["characters"][0] as Dictionary)["role"] = "Protagonist"
	var md: String = gm.export_to_markdown(g)
	assert_true("char_hero — Hero" in md,
		"character heading should combine id + name")
	assert_true("Protagonist" in md,
		"character role should be rendered")

func test_export_renders_task_dependencies():
	var md: String = gm.export_to_markdown(_xref_gdd())
	# task_b in the xref fixture depends on task_a.
	assert_true("**Depends on:** task_a" in md,
		"task dependencies should be rendered as a bullet")

func test_export_ends_with_newline():
	var md: String = gm.export_to_markdown(_minimal_valid_gdd())
	assert_true(md.ends_with("\n"),
		"markdown output should end with a single newline for clean concat")

func test_save_markdown_writes_to_disk():
	var path: String = "user://_test_export_%d.md" % Time.get_ticks_msec()
	var r: Dictionary = gm.save_markdown(_minimal_valid_gdd(), path)
	assert_true(bool(r["success"]), "save_markdown should report success")
	assert_eq(str(r["path"]), path, "result should echo path back")
	assert_true(int(r["bytes"]) > 0, "result should report a positive byte count")
	assert_true(FileAccess.file_exists(path),
		"file should exist on disk after save_markdown")
	# Read it back to confirm contents.
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	var disk_text: String = f.get_as_text()
	f.close()
	assert_true(disk_text.begins_with("# "),
		"disk content should be markdown starting with a heading")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

func test_save_markdown_rejects_empty_path():
	var r: Dictionary = gm.save_markdown(_minimal_valid_gdd(), "")
	assert_false(bool(r["success"]),
		"empty path should be rejected before any file work")

func test_save_markdown_handles_validation_invalid_gdd():
	# Markdown export is presentation, not persistence — even a
	# structurally invalid GDD should produce best-effort output.
	# (Contrast with save_gdd, which DOES validate.)
	var bad: Dictionary = {"mechanics": [{"id": "mech_x", "description": "ok"}]}
	var path: String = "user://_test_export_invalid_%d.md" % Time.get_ticks_msec()
	var r: Dictionary = gm.save_markdown(bad, path)
	assert_true(bool(r["success"]),
		"save_markdown should not require the GDD to validate")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


# ---------- Helpers ----------

func _rmdir_recursive(path: String) -> void:
	var dir = DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var f = dir.get_next()
	while f != "":
		if not dir.current_is_dir():
			DirAccess.remove_absolute(ProjectSettings.globalize_path("%s/%s" % [path, f]))
		f = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
