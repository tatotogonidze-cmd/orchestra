# gdd_edit_form.gd
# Reusable form for editing a Game Design Document. Built as a
# stand-alone VBoxContainer so gdd_panel can embed it without growing
# any further. The form is the form-based counterpart to ADR 017's
# Claude chat-edit — same underlying GDDManager.save_gdd pipeline,
# different UX flavour:
#
#   - chat-edit is best for exploratory natural-language changes
#     ("add a stealth mechanic"). Claude does the structural work.
#   - this form is best for targeted edits where you already know what
#     you're typing ("rename mech_combat to mech_battle", "bump the
#     document version"). Faster than dictating it to Claude.
#
# Both paths converge on `gdd_manager.save_gdd(...)` so the snapshot
# semantics from ADR 006 apply uniformly.
#
# Scope (MVP, see ADR 018):
#   - Top-level: game_title, core_loop.goal, genres (string list).
#   - Per entity type: list of {id, description} rows with add/remove.
#     Other fields a particular entity type happens to carry (e.g.
#     character.name, scene.connections) are passed through unchanged
#     from the original GDD via the buffer's deep copy.
#   - Save / Cancel emit signals; the embedding panel decides what to
#     do (validate + write, or discard).
#
# Out of scope for this phase (documented as ADR 018 follow-ups):
#   - core_loop.actions / rewards string lists.
#   - Per-entity-type custom fields (character name, scene connections,
#     dialogue lines, etc).
#   - Cross-reference picker (a task referring to an asset id).
#   - Inline validation feedback.
#
# Test hooks:
#   - `_title_input`, `_goal_input`, `_genres_container`,
#     `_entities_container[<type>]`, `_save_button`, `_cancel_button`.
#   - `set_gdd(gdd)` populates the form; `get_gdd()` reads it back.
#   - Internal handlers `_on_save_pressed`, `_on_cancel_pressed`,
#     `_add_genre_row`, `_add_entity_row(<type>)` are callable directly.

extends VBoxContainer

const _ENTITY_TYPES: Array = [
	"mechanics", "assets", "tasks", "scenes", "characters", "dialogues",
]

# Phase 32 (ADR 032): per-entity field rendering. Each entity type
# declares the fields it wants in the row, in order from left to
# right. `expand: true` makes the LineEdit take the remaining row
# width (used for description-style free-form text). `min_width`
# pins the column width for fixed-shape fields (id, type tags,
# enum-ish values).
#
# Fields NOT listed here pass through untouched via the buffer-
# preserves-extras pattern from Phase 18 — character.stats,
# scene.entry_points, dialogue.nodes etc all survive a save round-
# trip without rendering. Adding them later means appending to the
# spec; no read-side change needed.
#
# Phase 40 (ADR 040): per-field "enum" entries for fields that the
# schema constrains to a closed set. The row builder dispatches on
# their presence — fields with "enum" render as OptionButton,
# others stay LineEdit.
#
# Enum values mirror gdd_schema.json verbatim. Keeping the table
# hard-coded (vs. parsing the schema at load time) is the same
# trade-off as ADR 032 made for the spec itself: editorial
# control, predictable test surface, change-on-schema-evolution
# is a deliberate one-line update.
const _ENTITY_FIELD_SPEC: Dictionary = {
	"mechanics": [
		{"key": "id",          "min_width": 150, "expand": false},
		{"key": "description", "min_width": 0,   "expand": true},
	],
	"assets": [
		{"key": "id",   "min_width": 150, "expand": false},
		{"key": "type", "min_width": 100, "expand": false,
			"enum": ["3D", "Audio", "Dialogue", "Code", "Image", "Texture"]},
		{"key": "path", "min_width": 0,   "expand": true},
	],
	"tasks": [
		{"key": "id",          "min_width": 130, "expand": false},
		{"key": "title",       "min_width": 150, "expand": false},
		{"key": "status",      "min_width": 110, "expand": false,
			"enum": ["Ready", "InProgress", "Blocked", "NeedsReview", "Done", "Cancelled"]},
		{"key": "priority",    "min_width": 90,  "expand": false,
			"enum": ["low", "medium", "high", "critical"]},
		{"key": "description", "min_width": 0,   "expand": true},
	],
	"scenes": [
		{"key": "id",   "min_width": 130, "expand": false},
		{"key": "name", "min_width": 0,   "expand": true},
	],
	"characters": [
		{"key": "id",   "min_width": 130, "expand": false},
		{"key": "name", "min_width": 130, "expand": false},
		{"key": "role", "min_width": 0,   "expand": true},
	],
	"dialogues": [
		{"key": "id",           "min_width": 130, "expand": false},
		{"key": "character_id", "min_width": 0,   "expand": true},
	],
}

signal saved(gdd: Dictionary)
signal cancelled()

# Top-level inputs.
var _title_input: LineEdit
var _goal_input: LineEdit
var _doc_version_input: LineEdit
var _genres_container: VBoxContainer

# Entity sections, keyed by type. Each value is a Dictionary
# {"container": VBoxContainer, "rows": Array} so add/remove can work
# without searching the tree.
var _entity_sections: Dictionary = {}

var _save_button: Button
var _cancel_button: Button

# Working buffer — set on `set_gdd`. We keep a deep copy so any
# extra fields the GDD carries (created_at timestamps, per-entity
# custom keys we don't render) survive a save round-trip.
var _buffer: Dictionary = {}


func _ready() -> void:
	add_theme_constant_override("separation", 8)

	# Footer buttons up top — the form is long, putting Save where the
	# user can't see it without scrolling would be cruel.
	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_END
	actions.add_theme_constant_override("separation", 8)
	add_child(actions)

	_cancel_button = Button.new()
	_cancel_button.text = "Cancel"
	_cancel_button.pressed.connect(_on_cancel_pressed)
	actions.add_child(_cancel_button)

	_save_button = Button.new()
	_save_button.text = "Save"
	_save_button.tooltip_text = "Validate, snapshot, and write to disk"
	_save_button.pressed.connect(_on_save_pressed)
	actions.add_child(_save_button)

	# Top-level fields.
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 6)
	add_child(title_row)
	var title_label := Label.new()
	title_label.text = "Title:"
	title_label.custom_minimum_size = Vector2(110, 0)
	title_row.add_child(title_label)
	_title_input = LineEdit.new()
	_title_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(_title_input)

	var goal_row := HBoxContainer.new()
	goal_row.add_theme_constant_override("separation", 6)
	add_child(goal_row)
	var goal_label := Label.new()
	goal_label.text = "Core loop goal:"
	goal_label.custom_minimum_size = Vector2(110, 0)
	goal_row.add_child(goal_label)
	_goal_input = LineEdit.new()
	_goal_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	goal_row.add_child(_goal_input)

	var version_row := HBoxContainer.new()
	version_row.add_theme_constant_override("separation", 6)
	add_child(version_row)
	var version_label := Label.new()
	version_label.text = "Doc version:"
	version_label.custom_minimum_size = Vector2(110, 0)
	version_row.add_child(version_label)
	_doc_version_input = LineEdit.new()
	_doc_version_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_doc_version_input.placeholder_text = "0.1.0"
	version_row.add_child(_doc_version_input)

	# Genres section.
	var genres_header := Label.new()
	genres_header.text = "Genres"
	genres_header.add_theme_font_size_override("font_size", 14)
	add_child(genres_header)

	_genres_container = VBoxContainer.new()
	_genres_container.add_theme_constant_override("separation", 4)
	add_child(_genres_container)

	var add_genre_btn := Button.new()
	add_genre_btn.text = "+ Add genre"
	add_genre_btn.pressed.connect(func() -> void: _add_genre_row(""))
	add_child(add_genre_btn)

	# Entity sections (mechanics, assets, ...).
	for entity_type in _ENTITY_TYPES:
		_build_entity_section(str(entity_type))


# ---------- Public API ----------

# Replace the form contents with values from `gdd`. We deep-copy into
# `_buffer` so caller-side mutations don't leak into our state.
func set_gdd(gdd: Dictionary) -> void:
	_buffer = gdd.duplicate(true)
	_title_input.text = str(_buffer.get("game_title", ""))
	var loop = _buffer.get("core_loop", {})
	if loop is Dictionary:
		_goal_input.text = str((loop as Dictionary).get("goal", ""))
	else:
		_goal_input.text = ""
	var meta = _buffer.get("metadata", {})
	if meta is Dictionary:
		_doc_version_input.text = str((meta as Dictionary).get("document_version", ""))
	else:
		_doc_version_input.text = ""
	# Wipe and repopulate genres list.
	_clear_container(_genres_container)
	var genres = _buffer.get("genres", [])
	if genres is Array:
		for g in (genres as Array):
			_add_genre_row(str(g))
	# Wipe and repopulate each entity section.
	for entity_type in _ENTITY_TYPES:
		var section: Dictionary = _entity_sections[entity_type]
		_clear_container(section["container"])
		(section["rows"] as Array).clear()
		var arr = _buffer.get(entity_type, [])
		if arr is Array:
			for entry in (arr as Array):
				if entry is Dictionary:
					_add_entity_row(entity_type, entry as Dictionary)


# Read the current form state back out into a Dictionary that mirrors
# the input GDD's shape. Untouched fields (anything we didn't render)
# pass through from `_buffer` unchanged so a save round-trip doesn't
# silently drop data.
func get_gdd() -> Dictionary:
	var out: Dictionary = _buffer.duplicate(true)
	out["game_title"] = _title_input.text
	# core_loop is a sub-object — preserve any sibling fields
	# (actions, rewards, anything else) we didn't expose in the form.
	if not (out.get("core_loop", null) is Dictionary):
		out["core_loop"] = {}
	(out["core_loop"] as Dictionary)["goal"] = _goal_input.text
	# metadata mirrors the same idea — preserve created_at etc.
	if not (out.get("metadata", null) is Dictionary):
		out["metadata"] = {}
	var dv: String = _doc_version_input.text.strip_edges()
	if not dv.is_empty():
		(out["metadata"] as Dictionary)["document_version"] = dv
	# Genres — read back as an array of non-empty strings.
	out["genres"] = _read_genres()
	# Each entity type — read back as an array of {id, description, ...}.
	# We preserve any additional keys per entry (e.g. character.name)
	# that the form doesn't render, by indexing into the original buffer
	# array by id.
	for entity_type in _ENTITY_TYPES:
		out[entity_type] = _read_entity_array(entity_type)
	return out


# ---------- Internals: building rows ----------

func _build_entity_section(entity_type: String) -> void:
	var header := Label.new()
	header.text = entity_type.capitalize()
	header.add_theme_font_size_override("font_size", 14)
	add_child(header)

	var container := VBoxContainer.new()
	container.add_theme_constant_override("separation", 4)
	add_child(container)

	var add_btn := Button.new()
	add_btn.text = "+ Add %s" % entity_type.trim_suffix("s")
	# Capture entity_type by value via the lambda's closure.
	add_btn.pressed.connect(func() -> void:
		_add_entity_row(entity_type, {}))
	add_child(add_btn)

	_entity_sections[entity_type] = {"container": container, "rows": []}

func _add_genre_row(initial: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var input := LineEdit.new()
	input.text = initial
	input.placeholder_text = "genre, e.g. RPG"
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(input)
	var remove_btn := Button.new()
	remove_btn.text = "×"
	remove_btn.tooltip_text = "Remove this genre"
	remove_btn.pressed.connect(func() -> void:
		# Synchronous remove for the same orphan-tracker reason as the
		# other rebuilders: queue_free leaves stale rows alive across
		# back-to-back tests.
		if row.is_inside_tree():
			row.get_parent().remove_child(row)
		row.free())
	row.add_child(remove_btn)
	_genres_container.add_child(row)
	return row

func _add_entity_row(entity_type: String, entry: Dictionary) -> Control:
	var section: Dictionary = _entity_sections[entity_type]
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	# Phase 32: build one LineEdit per spec field. Inputs is keyed
	# by field name so _read_entity_array can read them back without
	# walking the row's children.
	var inputs: Dictionary = {}
	var spec: Array = _ENTITY_FIELD_SPEC.get(entity_type, [
		# Fallback for entity types we forgot to declare — at least
		# render id + description so the form isn't useless.
		{"key": "id", "min_width": 150, "expand": false},
		{"key": "description", "min_width": 0, "expand": true},
	]) as Array
	for field in spec:
		var key: String = str((field as Dictionary).get("key", ""))
		if key.is_empty():
			continue
		var enum_values = (field as Dictionary).get("enum", null)
		var ctrl: Control
		var min_w: float = float((field as Dictionary).get("min_width", 0))
		if enum_values is Array:
			# Phase 40 (ADR 040): closed-set field → OptionButton.
			# Pre-select the entry's current value if it's in the enum;
			# otherwise leave the default selection (index 0) and let
			# the read-back path overwrite. Unknown values get logged
			# via the placeholder-style item so the user can see they
			# typed something out-of-schema.
			var ob := OptionButton.new()
			var current: String = str(entry.get(key, ""))
			var matched_idx: int = -1
			for i in range((enum_values as Array).size()):
				var v: String = str((enum_values as Array)[i])
				ob.add_item(v, i)
				if v == current:
					matched_idx = i
			if not current.is_empty() and matched_idx == -1:
				# Out-of-schema value (legacy data, hand-edit, etc) —
				# surface it as a labelled item so we don't silently
				# replace it. Selecting any other item will then save
				# the in-schema value.
				ob.add_item("(invalid: %s)" % current, (enum_values as Array).size())
				ob.selected = (enum_values as Array).size()
			elif matched_idx >= 0:
				ob.selected = matched_idx
			# else: ob.selected stays at default 0 — used when the
			# user clicks + Add and there's no current value.
			ctrl = ob
		else:
			var le := LineEdit.new()
			le.text = str(entry.get(key, ""))
			le.placeholder_text = _placeholder_for(entity_type, key)
			ctrl = le
		if min_w > 0.0:
			ctrl.custom_minimum_size = Vector2(min_w, 0)
		if bool((field as Dictionary).get("expand", false)):
			ctrl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(ctrl)
		inputs[key] = ctrl

	var remove_btn := Button.new()
	remove_btn.text = "×"
	remove_btn.tooltip_text = "Remove this %s" % entity_type.trim_suffix("s")
	# Identity-based removal: search the rows Array for the exact row
	# Node we built. Dictionary.erase with a value comparison would
	# match by structural equality, which collides when two empty rows
	# happen to both have identical inputs/originals.
	remove_btn.pressed.connect(func() -> void:
		var rows_arr: Array = section["rows"]
		for i in range(rows_arr.size()):
			if rows_arr[i]["row"] == row:
				rows_arr.remove_at(i)
				break
		if row.is_inside_tree():
			row.get_parent().remove_child(row)
		row.free())
	row.add_child(remove_btn)
	(section["container"] as VBoxContainer).add_child(row)
	# Row metadata: keep `inputs` (per-field LineEdits) and `original`
	# (the full record dict, including un-rendered fields like
	# character.stats) for the read-back path.
	(section["rows"] as Array).append({
		"row":      row,
		"inputs":   inputs,
		"original": entry,
	})
	return row

# Per-field placeholder hint. id fields show the schema's prefix
# (`mech_*`, `asset_*`, ...). Other fields fall back to the field
# name. Centralising here so per-type spec changes can pull richer
# hints if they want.
func _placeholder_for(entity_type: String, field_key: String) -> String:
	if field_key == "id":
		return _id_prefix_hint(entity_type)
	return field_key

# Hint text matching GDDManager's id-prefix validation. Kept in sync by
# inspection — there's no programmatic source for it short of poking
# at the schema.
func _id_prefix_hint(entity_type: String) -> String:
	match entity_type:
		"mechanics":  return "mech_*"
		"assets":     return "asset_*"
		"tasks":      return "task_*"
		"scenes":     return "scene_*"
		"characters": return "char_*"
		"dialogues":  return "dlg_*"
	return "id"


# ---------- Internals: reading rows back ----------

func _read_genres() -> Array:
	var out: Array = []
	for row in _genres_container.get_children():
		# Each row is HBoxContainer with [LineEdit, Button]. Look up
		# the LineEdit defensively.
		for child in (row as Control).get_children():
			if child is LineEdit:
				var t: String = (child as LineEdit).text.strip_edges()
				if not t.is_empty():
					out.append(t)
				break
	return out

func _read_entity_array(entity_type: String) -> Array:
	var out: Array = []
	var section: Dictionary = _entity_sections[entity_type]
	for entry in (section["rows"] as Array):
		var inputs: Dictionary = entry.get("inputs", {})
		# Per-field value. Phase 40 (ADR 040): inputs may be either
		# LineEdit (free-text) or OptionButton (enum). Branch on the
		# control type when reading.
		# We track LineEdit emptiness separately so we can decide
		# whether the whole row is empty (skip). OptionButton defaults
		# don't count toward "the user filled this in" — every fresh
		# row gets selected=0, which would mark the row as non-empty
		# even if the user never touched it.
		var values: Dictionary = {}
		var any_user_input: bool = false
		for key in inputs.keys():
			var ctrl: Control = inputs[key]
			var t: String = ""
			if ctrl is LineEdit:
				t = (ctrl as LineEdit).text.strip_edges()
				if not t.is_empty():
					any_user_input = true
			elif ctrl is OptionButton:
				var ob: OptionButton = ctrl as OptionButton
				if ob.selected >= 0:
					t = ob.get_item_text(ob.selected)
				# Strip the legacy "(invalid: …)" wrapper that
				# _add_entity_row attaches when the original record
				# carried an out-of-schema value the user has now
				# overwritten. Reading it back as the literal label
				# would re-introduce the bad value.
				if t.begins_with("(invalid: ") and t.ends_with(")"):
					t = t.substr(10, t.length() - 11)
				# OptionButton values do NOT count toward
				# any_user_input — auto-filled defaults shouldn't
				# turn a fresh empty row into a saved record.
			values[key] = t
		if not any_user_input:
			# Pure empty row — user clicked + Add and never typed any
			# free-text. Skip so we don't write garbage that would fail
			# validation. (Auto-filled enum defaults are ignored here:
			# they don't represent user intent on their own.)
			continue
		# Preserve any extra fields from the original record. This is
		# how character.stats / scene.entry_points / dialogue.nodes
		# survive a save round-trip — the form doesn't render them
		# but we copy them through.
		var original: Dictionary = entry.get("original", {})
		var record: Dictionary = (original as Dictionary).duplicate(true)
		# Overwrite rendered fields with the LineEdit values. Empty
		# strings overwrite too — letting the user clear an existing
		# field is a real edit (e.g. clearing a character.role).
		for key in values.keys():
			record[key] = values[key]
		out.append(record)
	return out


# ---------- Internals: cleanup ----------

# Free-immediately drop every child from a container. Same orphan-
# tracker reasoning as the other rebuilders in the UI layer.
func _clear_container(c: Container) -> void:
	for child in c.get_children():
		c.remove_child(child)
		child.free()


# ---------- Handlers ----------

func _on_save_pressed() -> void:
	emit_signal("saved", get_gdd())

func _on_cancel_pressed() -> void:
	emit_signal("cancelled")
