# gdd_manager.gd
# Validate, load, save, snapshot, rollback the Game Design Document.
#
# Validation is a SHALLOW structural check (not a full JSON Schema impl):
#   - Required root fields present.
#   - Root additionalProperties=false enforced (unknown root keys flagged).
#   - Entity ID prefixes checked (mech_, asset_, task_, scene_, char_, dlg_).
# Full cross-reference integrity (e.g. every dependency id exists) is a separate concern
# — TODO: add in a follow-up once chat-edit flow lands.
#
# Snapshots: linear numbering (v1, v2, ...). Retain last MAX_SNAPSHOTS. See ADR #6.
# Emits EventBus events on successful save/snapshot/rollback.

extends Node
class_name GDDManager

const SCHEMA_PATH_DEFAULT: String = "res://schemas/gdd_schema.json"
const SNAPSHOT_DIR_DEFAULT: String = "user://gdd_snapshots"
const MAX_SNAPSHOTS: int = 20

var schema_path: String = SCHEMA_PATH_DEFAULT
var snapshot_dir: String = SNAPSHOT_DIR_DEFAULT

var _schema: Dictionary = {}
var _schema_loaded: bool = false


# ---------- Schema ----------

# Lazy: first call to validate() will trigger load if not yet loaded.
func _ensure_schema() -> void:
	if _schema_loaded:
		return
	_load_schema(schema_path)

func _load_schema(path: String) -> void:
	if not FileAccess.file_exists(path):
		push_error("GDD schema not found at %s" % path)
		return
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("Cannot open GDD schema: %s" % path)
		return
	var content: String = f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(content)
	if not (parsed is Dictionary):
		push_error("GDD schema is not a JSON object")
		return
	_schema = parsed
	_schema_loaded = true


# ---------- Public schema accessor ----------

# Returns a copy of the loaded JSON Schema. Used by the chat-edit flow
# to include the schema in Claude's prompt. Triggers the lazy load on
# first call so callers don't need to poke at internal state.
func get_schema() -> Dictionary:
	_ensure_schema()
	return _schema.duplicate(true)


# ---------- Validation ----------

# Returns {valid: bool, errors: Array[String]}.
func validate(gdd: Dictionary) -> Dictionary:
	_ensure_schema()
	var errors: Array = []
	if not _schema_loaded:
		errors.append("schema not loaded")
		return {"valid": false, "errors": errors}

	# Required root fields
	var required: Array = _schema.get("required", [])
	for field in required:
		if not gdd.has(field):
			errors.append("missing required field: %s" % field)

	# Root additionalProperties=false
	if _schema.get("additionalProperties", true) == false:
		var root_props: Dictionary = _schema.get("properties", {})
		var allowed: Array = root_props.keys()
		for key in gdd.keys():
			if not allowed.has(key):
				errors.append("unknown root field: %s" % key)

	_check_id_patterns(gdd, errors)
	_check_cross_references(gdd, errors)

	return {"valid": errors.is_empty(), "errors": errors}

func _check_id_patterns(gdd: Dictionary, errors: Array) -> void:
	var specs: Array = [
		["mechanics", "mech_"],
		["assets", "asset_"],
		["tasks", "task_"],
		["scenes", "scene_"],
		["characters", "char_"],
		["dialogues", "dlg_"],
	]
	for pair in specs:
		var field: String = pair[0]
		var prefix: String = pair[1]
		if not gdd.has(field):
			continue
		var items = gdd[field]
		if not (items is Array):
			errors.append("%s must be an array" % field)
			continue
		for item in items:
			if item is Dictionary and item.has("id"):
				var id_val: String = str(item["id"])
				if not id_val.begins_with(prefix):
					errors.append("%s.id should start with '%s', got '%s'" % [field, prefix, id_val])


# Validate that every id-typed reference points at an entity that
# actually exists in the document. The schema only constrains the
# *shape* of these references (each must match the right `^prefix_*`
# pattern); existence is the app's job. Phase 19 / ADR 019.
#
# Reference map (sourced from schemas/gdd_schema.json):
#   mechanics[].dependencies         → mechanics
#   assets[].parent_asset_id         → assets       (null is also valid)
#   tasks[].dependencies             → tasks
#   tasks[].blocked_by               → tasks
#   tasks[].related_asset_ids        → assets
#   tasks[].related_mechanic_ids     → mechanics
#   scenes[].related_asset_ids       → assets
#   scenes[].entry_points[].from_scene_id → scenes
#   characters[].asset_id            → assets
#   dialogues[].character_id         → characters
#
# Intra-document graphs (e.g. dialogue node next_node_ids) are NOT
# checked — see ADR 019 follow-ups.
func _check_cross_references(gdd: Dictionary, errors: Array) -> void:
	# Build id pools per entity type. Each pool is a Dictionary used as
	# a set for O(1) membership testing.
	var pools: Dictionary = {
		"mechanics":  _id_pool(gdd, "mechanics"),
		"assets":     _id_pool(gdd, "assets"),
		"tasks":      _id_pool(gdd, "tasks"),
		"scenes":     _id_pool(gdd, "scenes"),
		"characters": _id_pool(gdd, "characters"),
	}

	# mechanics[].dependencies → mechanics
	for m in _items(gdd, "mechanics"):
		_check_array_refs(m, "dependencies",
			pools["mechanics"], "mechanic", "mechanic", errors)

	# assets[].parent_asset_id → assets (nullable)
	for a in _items(gdd, "assets"):
		_check_scalar_ref(a, "parent_asset_id",
			pools["assets"], "asset", "asset", errors, true)

	# tasks[]: dependencies, blocked_by, related_asset_ids,
	# related_mechanic_ids
	for t in _items(gdd, "tasks"):
		_check_array_refs(t, "dependencies",
			pools["tasks"], "task", "task", errors)
		_check_array_refs(t, "blocked_by",
			pools["tasks"], "task", "task", errors)
		_check_array_refs(t, "related_asset_ids",
			pools["assets"], "task", "asset", errors)
		_check_array_refs(t, "related_mechanic_ids",
			pools["mechanics"], "task", "mechanic", errors)

	# scenes[]: related_asset_ids + entry_points[].from_scene_id
	for s in _items(gdd, "scenes"):
		_check_array_refs(s, "related_asset_ids",
			pools["assets"], "scene", "asset", errors)
		var ep = s.get("entry_points", [])
		if ep is Array:
			for entry in ep:
				if entry is Dictionary:
					# from_scene_id is optional — a scene may have an
					# entry_point that's just a spawn position with no
					# inbound link.
					_check_scalar_ref(entry, "from_scene_id",
						pools["scenes"], "scene.entry_point", "scene",
						errors, true)

	# characters[].asset_id (nullable per the schema's `pattern`-only
	# constraint — but the field is optional, treat absence as fine).
	for c in _items(gdd, "characters"):
		_check_scalar_ref(c, "asset_id",
			pools["assets"], "character", "asset", errors, true)

	# dialogues[].character_id (required per schema — but if it's
	# missing, _check_id_patterns / required-field check has already
	# flagged it; we only verify existence here when present).
	for d in _items(gdd, "dialogues"):
		_check_scalar_ref(d, "character_id",
			pools["characters"], "dialogue", "character", errors, false)


# Build a {id: true} map for the named entity array. Returns an empty
# Dictionary if the field is missing or not an Array — callers treat
# "no pool" as "every reference will be flagged as unknown", which is
# the desired behaviour.
func _id_pool(gdd: Dictionary, field: String) -> Dictionary:
	var pool: Dictionary = {}
	for item in _items(gdd, field):
		if item is Dictionary and item.has("id"):
			pool[str(item["id"])] = true
	return pool

# Iterate the items of a top-level array field. Returns [] when the
# field is missing or not an Array — saves callers a guard.
func _items(gdd: Dictionary, field: String) -> Array:
	var v = gdd.get(field, [])
	return v if v is Array else []

# Validate that `record[ref_field]` (an array of ids) all live in
# `pool`. `owner_label` describes where we found the bad ref;
# `target_label` describes what kind of id it should have been. Empty
# arrays are fine.
func _check_array_refs(
		record: Dictionary, ref_field: String, pool: Dictionary,
		owner_label: String, target_label: String, errors: Array) -> void:
	if not record.has(ref_field):
		return
	var arr = record[ref_field]
	if not (arr is Array):
		return
	var owner_id: String = str(record.get("id", "<no id>"))
	for ref in (arr as Array):
		var ref_id: String = str(ref)
		if not pool.has(ref_id):
			errors.append("%s '%s' references unknown %s: '%s'" % [
				owner_label, owner_id, target_label, ref_id])

# Validate that `record[ref_field]` (a single id) lives in `pool`.
# When `nullable` is true, missing field / explicit null / empty
# string are all accepted as "no reference".
func _check_scalar_ref(
		record: Dictionary, ref_field: String, pool: Dictionary,
		owner_label: String, target_label: String, errors: Array,
		nullable: bool) -> void:
	if not record.has(ref_field):
		if nullable:
			return
		# A required field that's missing is the schema's job to
		# flag, not ours.
		return
	var v = record[ref_field]
	if v == null or (v is String and (v as String).is_empty()):
		if nullable:
			return
	var ref_id: String = str(v)
	if not pool.has(ref_id):
		var owner_id: String = str(record.get("id", "<no id>"))
		errors.append("%s '%s' references unknown %s: '%s'" % [
			owner_label, owner_id, target_label, ref_id])


# ---------- Persistence ----------

# Named load_gdd to avoid shadowing built-in global load().
func load_gdd(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"success": false, "error": "file not found: %s" % path, "gdd": {}}
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"success": false, "error": "cannot open", "gdd": {}}
	var text: String = f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return {"success": false, "error": "invalid JSON", "gdd": {}}
	return {"success": true, "gdd": parsed, "error": ""}

# save_gdd: validates, writes main file, creates snapshot, posts events.
# Returns {success, error?, snapshot_version?}.
func save_gdd(gdd: Dictionary, path: String) -> Dictionary:
	var v: Dictionary = validate(gdd)
	if not v["valid"]:
		return {"success": false, "error": "validation failed", "errors": v["errors"]}

	# Touch timestamps (non-destructive: keep created_at)
	var now: String = Time.get_datetime_string_from_system(true)
	if not gdd.has("metadata") or not (gdd["metadata"] is Dictionary):
		gdd["metadata"] = {}
	var md: Dictionary = gdd["metadata"]
	md["updated_at"] = now
	if not md.has("created_at"):
		md["created_at"] = now

	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {"success": false, "error": "cannot open for write: %s" % path}
	f.store_string(JSON.stringify(gdd, "  "))
	f.close()

	var snap: Dictionary = _create_snapshot(gdd)

	_post_event("gdd_updated", [path, str(md.get("document_version", ""))])
	if snap.get("success", false):
		_post_event("gdd_snapshot_created", [int(snap["version"]), str(snap["path"])])

	return {"success": true, "error": "", "snapshot_version": snap.get("version", -1)}


# ---------- Snapshots ----------

func _create_snapshot(gdd: Dictionary) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(snapshot_dir))
	var version: int = _next_snapshot_version()
	var snap_path: String = "%s/gdd_v%d.json" % [snapshot_dir, version]
	var f: FileAccess = FileAccess.open(snap_path, FileAccess.WRITE)
	if f == null:
		return {"success": false, "error": "cannot write snapshot"}
	f.store_string(JSON.stringify(gdd, "  "))
	f.close()
	_prune_snapshots()
	return {"success": true, "version": version, "path": snap_path}

func _next_snapshot_version() -> int:
	var existing: Array = list_snapshots()
	if existing.is_empty():
		return 1
	return int(existing[-1]["version"]) + 1

# Returns [{version: int, path: String}] sorted ascending.
func list_snapshots() -> Array:
	var result: Array = []
	var dir: DirAccess = DirAccess.open(snapshot_dir)
	if dir == null:
		return result
	dir.list_dir_begin()
	var fname: String = dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.begins_with("gdd_v") and fname.ends_with(".json"):
			var v_str: String = fname.trim_prefix("gdd_v").trim_suffix(".json")
			if v_str.is_valid_int():
				result.append({"version": int(v_str), "path": "%s/%s" % [snapshot_dir, fname]})
		fname = dir.get_next()
	dir.list_dir_end()
	result.sort_custom(func(a, b): return int(a["version"]) < int(b["version"]))
	return result

func _prune_snapshots() -> void:
	var snaps: Array = list_snapshots()
	var excess: int = snaps.size() - MAX_SNAPSHOTS
	if excess <= 0:
		return
	for i in range(excess):
		var abs_path: String = ProjectSettings.globalize_path(snaps[i]["path"])
		DirAccess.remove_absolute(abs_path)

# Load a snapshot by version. Does NOT auto-apply — caller can pass result.gdd to save_gdd.
func rollback(version: int) -> Dictionary:
	for s in list_snapshots():
		if int(s["version"]) == version:
			var r: Dictionary = load_gdd(s["path"])
			if r.get("success", false):
				_post_event("gdd_rollback_performed", [version])
			return r
	return {"success": false, "error": "snapshot v%d not found" % version, "gdd": {}}


# ---------- EventBus plumbing (safe if no autoload) ----------

func _post_event(event_name: String, args: Array) -> void:
	var loop = Engine.get_main_loop()
	if loop == null or not (loop is SceneTree):
		return
	var tree := loop as SceneTree
	if tree.root == null or not tree.root.has_node("EventBus"):
		return
	var bus: Node = tree.root.get_node("EventBus")
	if bus.has_method("post"):
		bus.call("post", event_name, args)
