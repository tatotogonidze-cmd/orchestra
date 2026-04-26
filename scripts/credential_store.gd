# credential_store.gd
# Encrypted key-value store for plugin credentials.
# Uses FileAccess.open_encrypted_with_pass (AES-256-CBC) — a Godot built-in.
# Data shape on disk (encrypted): {"plugins": {plugin_name: {key: value, ...}}}
#
# Usage:
#   var store := CredentialStore.new()
#   store.unlock("hunter2")
#   store.set_credential("tripo", "api_key", "sk-...")
#   var key := store.get_credential("tripo", "api_key").value
#
# Security notes:
#   - Master password is held in memory only while unlocked.
#   - lock() zeroes the in-memory cache and master password.
#   - AES-256-CBC protects confidentiality. Integrity is via the Godot format's built-in
#     check: a wrong password produces a parse failure on read, not silent corruption.
#   - OS keyring integration is a future enhancement — see docs/adrs/002-credential-store.md.

extends Node
class_name CredentialStore

const DEFAULT_PATH: String = "user://credentials.enc"

var _store_path: String = DEFAULT_PATH
var _master_password: String = ""
var _cache: Dictionary = {"plugins": {}}
var _unlocked: bool = false


# ---------- Unlock / lock ----------

# Unlock with a master password. If the file does not exist, creates an empty store on first write.
# Returns {success: bool, error: String?}.
func unlock(master_password: String, store_path: String = DEFAULT_PATH) -> Dictionary:
	if master_password.is_empty():
		return {"success": false, "error": "master password required"}
	_store_path = store_path
	_master_password = master_password

	if not FileAccess.file_exists(_store_path):
		_cache = {"plugins": {}}
		_unlocked = true
		_post_event("credential_store_unlocked", [])
		return {"success": true}

	var f: FileAccess = FileAccess.open_encrypted_with_pass(_store_path, FileAccess.READ, _master_password)
	if f == null:
		_master_password = ""
		return {"success": false, "error": "cannot open (bad password or corrupt file)"}
	var text: String = f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary) or not parsed.has("plugins"):
		_master_password = ""
		return {"success": false, "error": "decrypted content invalid"}
	_cache = parsed
	_unlocked = true
	_post_event("credential_store_unlocked", [])
	return {"success": true}

func lock() -> void:
	_unlocked = false
	_master_password = ""
	_cache = {"plugins": {}}
	_post_event("credential_store_locked", [])

func is_unlocked() -> bool:
	return _unlocked


# ---------- CRUD ----------

func set_credential(plugin_name: String, key: String, value: String) -> Dictionary:
	if not _unlocked:
		return {"success": false, "error": "store locked"}
	if not _cache["plugins"].has(plugin_name):
		_cache["plugins"][plugin_name] = {}
	_cache["plugins"][plugin_name][key] = value
	return _persist()

# Returns {success: bool, value: Variant, error: String?}.
func get_credential(plugin_name: String, key: String) -> Dictionary:
	if not _unlocked:
		return {"success": false, "error": "store locked", "value": null}
	var plug: Dictionary = _cache["plugins"].get(plugin_name, {})
	if not plug.has(key):
		return {"success": false, "error": "not found", "value": null}
	return {"success": true, "value": plug[key], "error": ""}

func remove_credential(plugin_name: String, key: String) -> Dictionary:
	if not _unlocked:
		return {"success": false, "error": "store locked"}
	if _cache["plugins"].has(plugin_name):
		_cache["plugins"][plugin_name].erase(key)
	return _persist()

func list_plugins() -> Array:
	if not _unlocked:
		return []
	return _cache["plugins"].keys()

# Snapshot of all credentials for a given plugin, used by Plugin Manager's initialize() flow.
func get_plugin_config(plugin_name: String) -> Dictionary:
	if not _unlocked:
		return {}
	var plug: Dictionary = _cache["plugins"].get(plugin_name, {})
	return plug.duplicate(true)


# ---------- Internals ----------

func _persist() -> Dictionary:
	var f: FileAccess = FileAccess.open_encrypted_with_pass(_store_path, FileAccess.WRITE, _master_password)
	if f == null:
		return {"success": false, "error": "cannot open for write"}
	f.store_string(JSON.stringify(_cache))
	f.close()
	return {"success": true, "error": ""}

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
