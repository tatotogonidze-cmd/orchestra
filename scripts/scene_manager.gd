# scene_manager.gd
# Owns metadata for "scenes" — user-curated bundles of asset_ids that
# the Scene Tester surfaces in a SubViewport (Phase 23 / ADR 023).
#
# Design note: this is a METADATA-ONLY layer. We deliberately do NOT
# serialize Godot `.tscn` files yet. A scene record is just:
#
#   {
#     "id":         String,           # `scene_<unix_ms>_<rand>`
#     "name":       String,           # human-readable label
#     "asset_ids":  Array[String],    # references into AssetManager
#     "created_at": int,              # unix seconds
#     "updated_at": int,
#   }
#
# Reasons for the metadata-only choice:
#   - Real .tscn export needs the asset bytes loaded (GLTFDocument /
#     AudioStreamMP3 / etc) at save time, plus disk-side resource paths
#     that survive Godot's import pipeline. Genuine work; punted.
#   - In-memory scenes are easier to render on-the-fly in the UI's
#     SubViewport — every show_dialog re-loads, the scene is always in
#     sync with the current state of its asset references.
#   - Asset deletion can leave dangling asset_ids; the scene_panel
#     filters them out at render time without any cascade work here.
#
# The on-disk layout mirrors AssetManager:
#
#   <root>/
#     index.json          # array of scene records
#
# `<root>` defaults to `user://scenes` and is overridable via
# `configure(root)` for hermetic tests.
#
# Signals fire on EventBus when present so other subsystems (asset_panel
# refresh, future scene_tester gadgets) can react.

extends Node

signal scene_created(scene_id: String, scene: Dictionary)
signal scene_updated(scene_id: String, scene: Dictionary)
signal scene_deleted(scene_id: String)

const DEFAULT_ROOT: String = "user://scenes"
const INDEX_FILENAME: String = "index.json"
const SCHEMA_VERSION: int = 1

var _root: String = DEFAULT_ROOT
# scene_id -> record (see docstring above for shape)
var _index: Dictionary = {}
var _loaded: bool = false


func _ready() -> void:
	if not _loaded:
		_load_index()


# ---------- Configuration ----------

# Point the manager at a different root. Used by tests to isolate
# from real user data. Safe to call before or after _ready.
func configure(root: String) -> void:
	_root = root
	_index = {}
	_loaded = false
	_load_index()


# ---------- Public API ----------

# Create a new scene. Returns {success, scene_id?, scene?, error?}.
# Optional asset_ids list pre-populates the scene; each id must exist
# in the supplied AssetManager-like object (anything with a get_asset
# method that returns {} for unknown ids). Pass null to skip the
# existence check — useful when the caller has already validated.
func create_scene(name: String, asset_ids: Array = [],
		asset_manager: Node = null) -> Dictionary:
	var trimmed: String = name.strip_edges()
	if trimmed.is_empty():
		return {"success": false, "error": "name required"}
	if asset_manager != null:
		for aid in asset_ids:
			var meta: Dictionary = asset_manager.get_asset(str(aid))
			if meta.is_empty():
				return {"success": false,
						"error": "unknown asset: %s" % str(aid)}
	var scene_id: String = _make_scene_id()
	# Millisecond-precision timestamp so back-to-back creates / updates
	# get distinct values and `list_scenes` sort_custom is deterministic.
	var now: int = int(Time.get_unix_time_from_system() * 1000.0)
	var record: Dictionary = {
		"id":         scene_id,
		"name":       trimmed,
		"asset_ids":  (asset_ids as Array).duplicate(true),
		"created_at": now,
		"updated_at": now,
	}
	_index[scene_id] = record
	_persist_index()
	emit_signal("scene_created", scene_id, record.duplicate(true))
	return {"success": true, "scene_id": scene_id,
			"scene": record.duplicate(true)}

# Append `asset_id` to the scene's asset list. Idempotent — a scene
# never holds duplicate ids. Returns {success, scene?, error?}.
func add_asset_to_scene(scene_id: String, asset_id: String,
		asset_manager: Node = null) -> Dictionary:
	if not _index.has(scene_id):
		return {"success": false, "error": "unknown scene"}
	if asset_manager != null:
		var meta: Dictionary = asset_manager.get_asset(asset_id)
		if meta.is_empty():
			return {"success": false, "error": "unknown asset"}
	var record: Dictionary = _index[scene_id]
	var assets: Array = record["asset_ids"]
	if not assets.has(asset_id):
		assets.append(asset_id)
		record["updated_at"] = int(Time.get_unix_time_from_system() * 1000.0)
		_persist_index()
		emit_signal("scene_updated", scene_id, record.duplicate(true))
	return {"success": true, "scene": record.duplicate(true)}

# Drop `asset_id` from the scene. Returns {success, scene?, error?}.
# Removing an id that wasn't there is a no-op success.
func remove_asset_from_scene(scene_id: String, asset_id: String) -> Dictionary:
	if not _index.has(scene_id):
		return {"success": false, "error": "unknown scene"}
	var record: Dictionary = _index[scene_id]
	var assets: Array = record["asset_ids"]
	var idx: int = assets.find(asset_id)
	if idx >= 0:
		assets.remove_at(idx)
		record["updated_at"] = int(Time.get_unix_time_from_system() * 1000.0)
		_persist_index()
		emit_signal("scene_updated", scene_id, record.duplicate(true))
	return {"success": true, "scene": record.duplicate(true)}

# Rename the scene. Returns {success, scene?, error?}.
func rename_scene(scene_id: String, new_name: String) -> Dictionary:
	if not _index.has(scene_id):
		return {"success": false, "error": "unknown scene"}
	var trimmed: String = new_name.strip_edges()
	if trimmed.is_empty():
		return {"success": false, "error": "name required"}
	var record: Dictionary = _index[scene_id]
	record["name"] = trimmed
	record["updated_at"] = int(Time.get_unix_time_from_system() * 1000.0)
	_persist_index()
	emit_signal("scene_updated", scene_id, record.duplicate(true))
	return {"success": true, "scene": record.duplicate(true)}

func delete_scene(scene_id: String) -> bool:
	if not _index.has(scene_id):
		return false
	_index.erase(scene_id)
	_persist_index()
	emit_signal("scene_deleted", scene_id)
	return true

func get_scene(scene_id: String) -> Dictionary:
	if not _index.has(scene_id):
		return {}
	return (_index[scene_id] as Dictionary).duplicate(true)

# Returns scene records as fresh copies, sorted by created_at descending
# (newest first) by default.
func list_scenes() -> Array:
	var out: Array = []
	for sid in _index.keys():
		out.append((_index[sid] as Dictionary).duplicate(true))
	out.sort_custom(func(a, b) -> bool:
		return int(a.get("created_at", 0)) > int(b.get("created_at", 0)))
	return out

func count() -> int:
	return _index.size()


# ---------- Internals ----------

func _make_scene_id() -> String:
	return "scene_%d_%d" % [
		int(Time.get_unix_time_from_system() * 1000.0),
		randi() % 1_000_000]

func _load_index() -> void:
	_loaded = true
	var path: String = "%s/%s" % [_root, INDEX_FILENAME]
	if not FileAccess.file_exists(path):
		return
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var content: String = f.get_as_text()
	f.close()
	var parser: JSON = JSON.new()
	var err: Error = parser.parse(content)
	if err != OK:
		push_warning("scene_manager: index parse failed: %s" % parser.get_error_message())
		return
	var data: Variant = parser.data
	if not (data is Dictionary):
		return
	var scenes_raw = (data as Dictionary).get("scenes", {})
	if scenes_raw is Dictionary:
		_index = scenes_raw

func _persist_index() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_root))
	var path: String = "%s/%s" % [_root, INDEX_FILENAME]
	var payload: Dictionary = {
		"schema_version": SCHEMA_VERSION,
		"scenes":         _index,
	}
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("scene_manager: cannot persist index to %s" % path)
		return
	f.store_string(JSON.stringify(payload, "  "))
	f.close()
