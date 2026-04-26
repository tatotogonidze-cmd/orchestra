# asset_manager.gd
# Owns the lifecycle of every generated asset after a plugin emits
# `task_completed`. Handles three ingest modes depending on `asset_type`:
#
#   - "text"       — result.text is UTF-8 written to user://assets/text/<id>.txt
#   - "audio"/"image" — result.path is a user:// file the plugin already wrote;
#                    we read its bytes and copy them into the managed layout
#   - "3d"         — result.path is a remote URL; we fetch bytes via HTTPRequest
#                    and persist them locally
#
# Asset IDs are derived from the SHA-256 of the content bytes, so identical
# output from two different generations produces exactly one on-disk file and
# one metadata row. That's the dedup guarantee.
#
# Metadata is held in memory as `_index: {asset_id -> Dictionary}` and
# persisted to `<root>/index.json` on every mutation. The index survives app
# restart.
#
# This module does NOT:
#   - Import .glb / .png / .mp3 into Godot resources. That's the scene/asset-
#     importer layer that sits on top. AssetManager only manages the raw
#     bytes + metadata.
#   - Talk to the plugin system directly. `ingest()` is the only entry point;
#     Orchestrator wires `PluginManager.plugin_task_completed -> ingest`.
#
# See docs/adrs/008-asset-manager.md for design rationale.

extends Node

# Explicit preloads — see orchestrator.gd for the class_name-cache rationale.
const BasePluginScript = preload("res://scripts/base_plugin.gd")

signal asset_ingested(asset_id: String, asset: Dictionary)
signal asset_deleted(asset_id: String)
signal asset_ingest_failed(source_task_id: String, error: Dictionary)

const DEFAULT_ROOT: String = "user://assets"
const INDEX_FILENAME: String = "index.json"
const SCHEMA_VERSION: int = 1

# HTTPRequest timeout for remote URL fetches (3D assets). Generous because
# Tripo's CDN can be slow.
var http_fetch_timeout_s: float = 120.0

# asset_id -> metadata dict. See _build_meta() for the shape.
var _index: Dictionary = {}
var _root: String = DEFAULT_ROOT
var _loaded: bool = false


func _ready() -> void:
	if not _loaded:
		_load_index()


# ---------- Configuration ----------

# Point the manager at a different root. Used by tests to isolate from the
# real user:// data. Safe to call before or after _ready.
func configure(root: String) -> void:
	_root = root
	_index = {}
	_loaded = false
	_load_index()


# ---------- Public API ----------

# Primary entry point. Called by Orchestrator in response to
# `plugin_task_completed`. The `prompt` argument is optional; it's stored for
# provenance so future UI can show "what generated this".
#
# Returns {success, asset_id?, asset?, deduplicated?, error?}.
#
# NOTE: ingest for 3D assets is async (HTTP fetch). Callers should `await`.
func ingest(source_plugin: String, source_task_id: String, result: Dictionary, prompt: String = "") -> Dictionary:
	var asset_type: String = str(result.get("asset_type", ""))
	match asset_type:
		"text":
			return _ingest_text(source_plugin, source_task_id, result, prompt)
		"audio", "image":
			return _ingest_local_binary(source_plugin, source_task_id, result, prompt)
		"3d":
			return await _ingest_remote_url(source_plugin, source_task_id, result, prompt)
		_:
			var err: Dictionary = {"code": "INVALID_ASSET_TYPE",
								   "message": "unknown asset_type: '%s'" % asset_type}
			emit_signal("asset_ingest_failed", source_task_id, err)
			return {"success": false, "error": err["message"]}

# Look up one asset. Returns {} if unknown.
func get_asset(asset_id: String) -> Dictionary:
	var row: Dictionary = _index.get(asset_id, {})
	return row.duplicate(true)

# List assets, optionally filtered. Filter keys currently supported:
#   asset_type: String  — exact match
#   plugin:     String  — exact match on source_plugin
# Returns a fresh Array of metadata copies.
func list_assets(filter: Dictionary = {}) -> Array:
	var out: Array = []
	for aid in _index.keys():
		if _matches_filter(_index[aid], filter):
			out.append((_index[aid] as Dictionary).duplicate(true))
	return out

# Remove an asset from disk and from the index. Returns true iff the metadata
# row existed (whether or not the file still existed at delete time).
func delete_asset(asset_id: String) -> bool:
	if not _index.has(asset_id):
		return false
	var row: Dictionary = _index[asset_id]
	var path: String = str(row.get("local_path", ""))
	if not path.is_empty() and FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_index.erase(asset_id)
	_persist_index()
	emit_signal("asset_deleted", asset_id)
	return true

func count() -> int:
	return _index.size()


# ---------- Ingest: text ----------

func _ingest_text(source_plugin: String, source_task_id: String, result: Dictionary, prompt: String) -> Dictionary:
	var text: String = str(result.get("text", ""))
	if text.is_empty():
		return _fail(source_task_id, "INVALID_PARAMS", "text result missing 'text' field")
	var bytes: PackedByteArray = text.to_utf8_buffer()
	return _register_bytes(
		bytes,
		"text",
		"txt",
		source_plugin,
		source_task_id,
		"",  # no source URL for inline text
		prompt,
		result)


# ---------- Ingest: local binary ----------

func _ingest_local_binary(source_plugin: String, source_task_id: String, result: Dictionary, prompt: String) -> Dictionary:
	var src_path: String = str(result.get("path", ""))
	if src_path.is_empty() or not src_path.begins_with("user://"):
		return _fail(source_task_id, "INVALID_PARAMS",
					 "expected user:// path for binary asset, got '%s'" % src_path)
	if not FileAccess.file_exists(src_path):
		return _fail(source_task_id, "PROVIDER_ERROR",
					 "plugin-declared file does not exist: %s" % src_path)
	var f: FileAccess = FileAccess.open(src_path, FileAccess.READ)
	if f == null:
		return _fail(source_task_id, "UNKNOWN", "cannot read source file: %s" % src_path)
	var bytes: PackedByteArray = f.get_buffer(f.get_length())
	f.close()
	var asset_type: String = str(result.get("asset_type", "unknown"))
	var fmt: String = str(result.get("format", "bin"))
	return _register_bytes(
		bytes, asset_type, fmt, source_plugin, source_task_id, src_path, prompt, result)


# ---------- Ingest: remote URL (3D) ----------

func _ingest_remote_url(source_plugin: String, source_task_id: String, result: Dictionary, prompt: String) -> Dictionary:
	var url: String = str(result.get("path", ""))
	if url.is_empty() or not (url.begins_with("http://") or url.begins_with("https://")):
		return _fail(source_task_id, "INVALID_PARAMS",
					 "expected http(s) URL for 3d asset, got '%s'" % url)

	var http := HTTPRequest.new()
	http.timeout = http_fetch_timeout_s
	add_child(http)
	var err: int = http.request(url)
	if err != OK:
		http.queue_free()
		return _fail(source_task_id, "NETWORK", "HTTPRequest.request() returned %d" % err)

	var out: Array = await http.request_completed
	http.queue_free()
	var result_code: int = int(out[0])
	var http_code: int = int(out[1])
	var bytes: PackedByteArray = out[3]
	if result_code != HTTPRequest.RESULT_SUCCESS:
		return _fail(source_task_id, "NETWORK",
					 "fetch failed: http_result=%d" % result_code)
	if http_code >= 400:
		return _fail(source_task_id, "PROVIDER_ERROR",
					 "fetch HTTP %d for %s" % [http_code, url])
	if bytes.size() == 0:
		return _fail(source_task_id, "PROVIDER_ERROR", "empty body from %s" % url)

	var fmt: String = str(result.get("format", "bin"))
	return _register_bytes(
		bytes, "3d", fmt, source_plugin, source_task_id, url, prompt, result)


# ---------- Shared: persist bytes + metadata ----------

func _register_bytes(
		bytes: PackedByteArray,
		asset_type: String,
		fmt: String,
		source_plugin: String,
		source_task_id: String,
		source_url: String,
		prompt: String,
		result: Dictionary) -> Dictionary:
	var hash_hex: String = _sha256_hex(bytes)
	var asset_id: String = hash_hex.substr(0, 16)  # first 16 hex chars — enough collision space

	# Dedup: if we already have this content under ANY id, return the existing row.
	if _index.has(asset_id):
		var existing: Dictionary = _index[asset_id]
		return {
			"success": true,
			"asset_id": asset_id,
			"asset": existing.duplicate(true),
			"deduplicated": true,
		}

	# Persist bytes to the managed layout.
	var local_path: String = "%s/%s/%s.%s" % [_root, asset_type, asset_id, fmt]
	if not _write_bytes(local_path, bytes):
		return _fail(source_task_id, "UNKNOWN", "cannot write asset to %s" % local_path)

	var meta: Dictionary = _build_meta(
		asset_id, asset_type, fmt, local_path, bytes.size(),
		hash_hex, source_plugin, source_task_id, source_url, prompt, result)
	_index[asset_id] = meta
	_persist_index()
	emit_signal("asset_ingested", asset_id, meta)
	return {"success": true, "asset_id": asset_id, "asset": meta.duplicate(true), "deduplicated": false}

func _build_meta(
		asset_id: String,
		asset_type: String,
		fmt: String,
		local_path: String,
		size_bytes: int,
		content_hash: String,
		source_plugin: String,
		source_task_id: String,
		source_url: String,
		prompt: String,
		result: Dictionary) -> Dictionary:
	return {
		"id":              asset_id,
		"asset_type":      asset_type,
		"format":          fmt,
		"local_path":      local_path,
		"size_bytes":      size_bytes,
		"content_hash":    content_hash,
		"source_plugin":   source_plugin,
		"source_task_id":  source_task_id,
		"source_url":      source_url,
		"prompt":          prompt,
		"cost":            float(result.get("cost", 0.0)),
		"created_at":      int(Time.get_unix_time_from_system()),
	}


# ---------- Index persistence ----------

func _load_index() -> void:
	_loaded = true
	var path: String = "%s/%s" % [_root, INDEX_FILENAME]
	if not FileAccess.file_exists(path):
		return
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var text: String = f.get_as_text()
	f.close()
	var json := JSON.new()
	var err: int = json.parse(text)
	if err != OK or not (json.data is Dictionary):
		push_warning("asset_manager: index at %s is corrupt; starting empty" % path)
		return
	var data: Dictionary = json.data
	if not (data.get("assets") is Dictionary):
		return
	_index = data["assets"]

func _persist_index() -> void:
	_ensure_dir(_root)
	var path: String = "%s/%s" % [_root, INDEX_FILENAME]
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("asset_manager: cannot persist index at %s" % path)
		return
	var payload: Dictionary = {"version": SCHEMA_VERSION, "assets": _index}
	f.store_string(JSON.stringify(payload))
	f.close()


# ---------- Helpers ----------

func _sha256_hex(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode()

func _write_bytes(path: String, bytes: PackedByteArray) -> bool:
	_ensure_dir(path.get_base_dir())
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(bytes)
	f.close()
	return true

func _ensure_dir(dir_path: String) -> void:
	# Works for both user:// and absolute paths.
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path))

func _matches_filter(row: Dictionary, filter: Dictionary) -> bool:
	if filter.has("asset_type") and str(row.get("asset_type", "")) != str(filter["asset_type"]):
		return false
	if filter.has("plugin") and str(row.get("source_plugin", "")) != str(filter["plugin"]):
		return false
	return true

func _fail(source_task_id: String, code: String, message: String) -> Dictionary:
	var err: Dictionary = {"code": code, "message": message}
	emit_signal("asset_ingest_failed", source_task_id, err)
	return {"success": false, "error": message}
