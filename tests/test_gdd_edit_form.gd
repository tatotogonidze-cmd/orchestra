# Unit tests for gdd_edit_form.gd. Pure form behaviour — no
# Orchestrator, no GDDManager. The embedding panel exercises the
# integration flow in test_gdd_panel.

extends GutTest

const GddEditFormScript = preload("res://scripts/ui/gdd_edit_form.gd")


func _make_form() -> Node:
	var f: Node = GddEditFormScript.new()
	add_child_autofree(f)
	return f

func _sample_gdd() -> Dictionary:
	return {
		"schema_version": "1.0.0",
		"game_title": "Sample Game",
		"genres": ["RPG", "Strategy"],
		"core_loop": {
			"goal": "explore the dungeon",
			"actions": ["walk", "fight"],
			"rewards": ["loot"],
		},
		"mechanics": [
			{"id": "mech_combat", "description": "turn-based fighting"},
		],
		"assets": [],
		"tasks": [],
		"scenes": [],
		"characters": [],
		"dialogues": [],
		"metadata": {
			"document_version": "0.3.0",
			"created_at": "2026-04-25T10:00:00Z",
		},
	}


# ---------- Build / structure ----------

func test_form_builds_top_level_inputs():
	var f: Node = _make_form()
	assert_not_null(f._title_input)
	assert_not_null(f._goal_input)
	assert_not_null(f._doc_version_input)
	assert_not_null(f._genres_container)
	assert_not_null(f._save_button)
	assert_not_null(f._cancel_button)

func test_form_builds_a_section_per_entity_type():
	var f: Node = _make_form()
	for entity_type in ["mechanics", "assets", "tasks", "scenes", "characters", "dialogues"]:
		assert_true(f._entity_sections.has(entity_type),
			"_entity_sections should have a row registry for '%s'" % entity_type)


# ---------- set_gdd / get_gdd round-trip ----------

func test_set_gdd_populates_top_level_fields():
	var f: Node = _make_form()
	f.set_gdd(_sample_gdd())
	assert_eq(f._title_input.text, "Sample Game")
	assert_eq(f._goal_input.text, "explore the dungeon")
	assert_eq(f._doc_version_input.text, "0.3.0")
	# Two genre rows in the genres container.
	assert_eq(f._genres_container.get_child_count(), 2,
		"genre rows should match the input list")

func test_set_gdd_populates_entity_rows():
	var f: Node = _make_form()
	f.set_gdd(_sample_gdd())
	var mechanics_section: Dictionary = f._entity_sections["mechanics"]
	assert_eq((mechanics_section["rows"] as Array).size(), 1,
		"one mechanic row should land in the form")

func test_get_gdd_round_trips_unchanged_input():
	var f: Node = _make_form()
	var original: Dictionary = _sample_gdd()
	f.set_gdd(original)
	var out: Dictionary = f.get_gdd()
	assert_eq(out["game_title"], "Sample Game")
	assert_eq((out["genres"] as Array).size(), 2)
	assert_eq((out["core_loop"] as Dictionary)["goal"], "explore the dungeon")
	assert_eq((out["mechanics"] as Array).size(), 1)
	# Mechanic shape preserved.
	var mech: Dictionary = (out["mechanics"] as Array)[0]
	assert_eq(mech["id"], "mech_combat")
	assert_eq(mech["description"], "turn-based fighting")

func test_get_gdd_preserves_unrendered_subfields():
	# core_loop.actions and core_loop.rewards aren't exposed in the
	# form, but the buffer carries them — get_gdd should write them
	# back unchanged.
	var f: Node = _make_form()
	f.set_gdd(_sample_gdd())
	var out: Dictionary = f.get_gdd()
	var loop: Dictionary = out["core_loop"]
	assert_eq((loop["actions"] as Array).size(), 2,
		"core_loop.actions should survive a save round-trip")
	assert_eq((loop["rewards"] as Array).size(), 1,
		"core_loop.rewards should survive a save round-trip")
	# metadata.created_at should also survive.
	assert_eq((out["metadata"] as Dictionary)["created_at"],
		"2026-04-25T10:00:00Z",
		"metadata.created_at should survive a save round-trip")

func test_get_gdd_picks_up_user_edits():
	var f: Node = _make_form()
	f.set_gdd(_sample_gdd())
	# Mutate fields as the user would.
	f._title_input.text = "Renamed"
	f._goal_input.text = "different goal"
	# Mutate an entity row.
	var mechanics_section: Dictionary = f._entity_sections["mechanics"]
	var row_entry: Dictionary = (mechanics_section["rows"] as Array)[0]
	# Phase 32: row inputs live under "inputs" keyed by field name
	# so per-type fields all reach through the same accessor.
	(row_entry["inputs"]["id"] as LineEdit).text = "mech_battle"
	(row_entry["inputs"]["description"] as LineEdit).text = "fast battle"
	var out: Dictionary = f.get_gdd()
	assert_eq(out["game_title"], "Renamed")
	assert_eq((out["core_loop"] as Dictionary)["goal"], "different goal")
	var mech: Dictionary = (out["mechanics"] as Array)[0]
	assert_eq(mech["id"], "mech_battle")
	assert_eq(mech["description"], "fast battle")


# ---------- Add / remove rows ----------

func test_add_genre_row_extends_list():
	var f: Node = _make_form()
	f.set_gdd(_sample_gdd())
	f._add_genre_row("Sandbox")
	var out: Dictionary = f.get_gdd()
	assert_eq((out["genres"] as Array).size(), 3)
	assert_true("Sandbox" in (out["genres"] as Array))

func test_empty_genre_row_is_skipped_on_read():
	var f: Node = _make_form()
	f.set_gdd(_sample_gdd())
	# User added a row but never typed in it.
	f._add_genre_row("")
	var out: Dictionary = f.get_gdd()
	assert_eq((out["genres"] as Array).size(), 2,
		"blank genre rows should be dropped, not saved as ''")

func test_add_entity_row_extends_list():
	var f: Node = _make_form()
	f.set_gdd(_sample_gdd())
	f._add_entity_row("tasks", {"id": "task_intro", "description": "tutorial"})
	var out: Dictionary = f.get_gdd()
	assert_eq((out["tasks"] as Array).size(), 1)
	assert_eq((out["tasks"] as Array)[0]["id"], "task_intro")

func test_empty_entity_row_is_skipped_on_read():
	var f: Node = _make_form()
	f.set_gdd(_sample_gdd())
	# User clicked + Add but never typed.
	f._add_entity_row("tasks", {})
	var out: Dictionary = f.get_gdd()
	assert_eq((out["tasks"] as Array).size(), 0,
		"empty rows shouldn't introduce id='' entries")


# ---------- Save / Cancel signals ----------

func test_save_emits_signal_with_current_values():
	var f: Node = _make_form()
	f.set_gdd(_sample_gdd())
	f._title_input.text = "Saved Title"
	watch_signals(f)
	f._on_save_pressed()
	assert_signal_emitted(f, "saved")
	var params: Array = get_signal_parameters(f, "saved")
	var emitted: Dictionary = params[0] as Dictionary
	assert_eq(emitted["game_title"], "Saved Title",
		"save signal should carry the current form state")

func test_cancel_emits_signal_without_payload():
	var f: Node = _make_form()
	f.set_gdd(_sample_gdd())
	watch_signals(f)
	f._on_cancel_pressed()
	assert_signal_emitted(f, "cancelled")


# ---------- Re-set replaces previous content ----------

# ---------- Per-entity custom fields (Phase 32 / ADR 032) ----------

func test_character_row_renders_id_name_role():
	var f: Node = _make_form()
	f.set_gdd({
		"schema_version": "1.0.0",
		"game_title": "T",
		"genres": ["X"],
		"core_loop": {"goal": "g", "actions": [], "rewards": []},
		"mechanics": [], "assets": [], "tasks": [],
		"characters": [{
			"id": "char_hero",
			"name": "Mira",
			"role": "protagonist",
			"stats": {"hp": 100},  # un-rendered; should pass through
		}],
		"metadata": {"document_version": "0.1.0", "created_at": "2026-04-25T00:00:00Z"},
	})
	var section: Dictionary = f._entity_sections["characters"]
	var row: Dictionary = (section["rows"] as Array)[0]
	var inputs: Dictionary = row["inputs"]
	# Phase 32: id, name, role rendered as separate LineEdits.
	assert_true(inputs.has("id"))
	assert_true(inputs.has("name"))
	assert_true(inputs.has("role"))
	assert_eq((inputs["id"] as LineEdit).text, "char_hero")
	assert_eq((inputs["name"] as LineEdit).text, "Mira")
	assert_eq((inputs["role"] as LineEdit).text, "protagonist")

func test_scene_row_renders_id_and_name():
	var f: Node = _make_form()
	f.set_gdd({
		"schema_version": "1.0.0",
		"game_title": "T",
		"genres": ["X"],
		"core_loop": {"goal": "g", "actions": [], "rewards": []},
		"mechanics": [], "assets": [], "tasks": [],
		"scenes": [{"id": "scene_intro", "name": "Opening Scene"}],
		"metadata": {"document_version": "0.1.0", "created_at": "2026-04-25T00:00:00Z"},
	})
	var section: Dictionary = f._entity_sections["scenes"]
	var row: Dictionary = (section["rows"] as Array)[0]
	assert_eq((row["inputs"]["id"] as LineEdit).text, "scene_intro")
	assert_eq((row["inputs"]["name"] as LineEdit).text, "Opening Scene")
	# Phase 32: scenes don't have a "description" field in spec.
	assert_false(row["inputs"].has("description"),
		"scene rows shouldn't render a description field (not in spec)")

func test_task_row_renders_id_title_description():
	var f: Node = _make_form()
	f.set_gdd({
		"schema_version": "1.0.0",
		"game_title": "T",
		"genres": ["X"],
		"core_loop": {"goal": "g", "actions": [], "rewards": []},
		"mechanics": [], "assets": [],
		"tasks": [{
			"id": "task_intro",
			"title": "Tutorial Quest",
			"description": "Walk the player through the basics",
			"status": "Ready",
			"created_at": "2026-04-25T00:00:00Z",
		}],
		"metadata": {"document_version": "0.1.0", "created_at": "2026-04-25T00:00:00Z"},
	})
	var section: Dictionary = f._entity_sections["tasks"]
	var row: Dictionary = (section["rows"] as Array)[0]
	assert_eq((row["inputs"]["title"] as LineEdit).text, "Tutorial Quest")
	assert_eq((row["inputs"]["description"] as LineEdit).text,
		"Walk the player through the basics")

func test_get_gdd_round_trips_per_type_fields():
	var f: Node = _make_form()
	f.set_gdd({
		"schema_version": "1.0.0",
		"game_title": "T",
		"genres": ["X"],
		"core_loop": {"goal": "g", "actions": [], "rewards": []},
		"mechanics": [], "assets": [], "tasks": [],
		"characters": [{"id": "char_a", "name": "Alice", "role": "guide"}],
		"metadata": {"document_version": "0.1.0", "created_at": "2026-04-25T00:00:00Z"},
	})
	# Mutate fields as the user would.
	var section: Dictionary = f._entity_sections["characters"]
	var row: Dictionary = (section["rows"] as Array)[0]
	(row["inputs"]["name"] as LineEdit).text = "Bob"
	(row["inputs"]["role"] as LineEdit).text = "rival"
	var out: Dictionary = f.get_gdd()
	var c: Dictionary = (out["characters"] as Array)[0]
	assert_eq(c["id"], "char_a")
	assert_eq(c["name"], "Bob")
	assert_eq(c["role"], "rival")

func test_get_gdd_preserves_unrendered_per_type_fields():
	# character.stats / asset.tags / scene.entry_points etc.
	# These aren't in the spec — they pass through via the buffer.
	var f: Node = _make_form()
	f.set_gdd({
		"schema_version": "1.0.0",
		"game_title": "T",
		"genres": ["X"],
		"core_loop": {"goal": "g", "actions": [], "rewards": []},
		"mechanics": [], "assets": [], "tasks": [],
		"characters": [{
			"id": "char_a",
			"name": "Hero",
			"stats": {"hp": 100, "mp": 50},
		}],
		"metadata": {"document_version": "0.1.0", "created_at": "2026-04-25T00:00:00Z"},
	})
	# User edits the name; stats should survive.
	var section: Dictionary = f._entity_sections["characters"]
	var row: Dictionary = (section["rows"] as Array)[0]
	(row["inputs"]["name"] as LineEdit).text = "Hero (rev)"
	var out: Dictionary = f.get_gdd()
	var c: Dictionary = (out["characters"] as Array)[0]
	assert_eq(c["name"], "Hero (rev)")
	# stats came from the buffer, untouched.
	assert_eq(int((c["stats"] as Dictionary)["hp"]), 100)
	assert_eq(int((c["stats"] as Dictionary)["mp"]), 50)

func test_blank_row_still_skipped_with_per_type_spec():
	# An empty per-type row (all LineEdits blank) should still be
	# skipped on read — same behaviour as Phase 18.
	var f: Node = _make_form()
	f.set_gdd(_sample_gdd())
	# Add a fresh empty character row.
	f._add_entity_row("characters", {})
	var out: Dictionary = f.get_gdd()
	# Empty row not written to the array.
	assert_eq((out["characters"] as Array).size(), 0,
		"empty per-type rows should be skipped, same as Phase 18")


func test_set_gdd_replaces_previous_state():
	var f: Node = _make_form()
	f.set_gdd(_sample_gdd())
	# Sub in a different document. The form should drop the old genre
	# rows and the old mechanic row.
	f.set_gdd({
		"schema_version": "1.0.0",
		"game_title": "Different",
		"genres": ["Puzzle"],
		"core_loop": {"goal": "solve puzzles", "actions": [], "rewards": []},
		"mechanics": [],
		"assets": [],
		"tasks": [],
		"metadata": {"document_version": "0.1.0", "created_at": "2026-04-25T11:00:00Z"},
	})
	assert_eq(f._title_input.text, "Different")
	assert_eq(f._genres_container.get_child_count(), 1,
		"old genre rows should be cleared on re-set")
	var mechanics_section: Dictionary = f._entity_sections["mechanics"]
	assert_eq((mechanics_section["rows"] as Array).size(), 0,
		"old mechanic rows should be cleared on re-set")
