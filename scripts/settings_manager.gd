# settings_manager.gd
# Persistent key-value store for user preferences (Phase 24 / ADR 024).
#
# Distinct from CredentialStore:
#   - SettingsManager is for NON-SECRET preferences (budget limits,
#     "always skip" flags, last-used paths, UI state).
#   - CredentialStore is for SECRETS (api_keys), which are encrypted
#     and require a master password.
#
# Storage: plain JSON at `user://settings.json`. No encryption — these
# values are user-visible by inspection anyway, and forcing them
# through the credential-store unlock flow would block the app from
# reading "always skip credential unlock" before unlocking.
#
# On-disk shape:
#
#   {
#     "schema_version": 1,
#     "values": {
#       "cost.session_limit": 50.0,
#       "credentials.always_skip": false,
#       "gdd.last_path": "user://gdd.json",
#       ...
#     }
#   }
#
# Naming convention: dotted keys, lowercase, namespaced by the
# subsystem that owns the setting. Examples:
#   cost.session_limit
#   cost.warning_threshold
#   credentials.always_skip
#   gdd.last_path
#
# API choices:
#   - Methods are `get_value` / `set_value` etc (NOT `get` / `set`)
#     to avoid collision with `Node.get(property)` /
#     `Node.set(property, value)` which exist for property-system
#     access.
#   - Each `set_value` / `remove_value` persists immediately. No
#     batched "save" — keeps the model simple.
#   - Default values are passed in by the reader: `get_value(key, default)`.
#     The store doesn't know about defaults; that's owned by the
#     consumer (so consumers can change defaults without migrating
#     stored values).

extends Node

signal setting_changed(key: String, value: Variant)
signal setting_removed(key: String)

const DEFAULT_PATH: String = "user://settings.json"
const SCHEMA_VERSION: int = 1

var _path: String = DEFAULT_PATH
var _values: Dictionary = {}
var _loaded: bool = false


func _ready() -> void:
	if not _loaded:
		_load()


# ---------- Configuration ----------

# Override the on-disk path. Used by tests to isolate from real user
# data. Resets in-memory state and reloads from the new path.
func configure(path: String) -> void:
	_path = path
	_values = {}
	_loaded = false
	_load()


# ---------- Public API ----------

# Read a value. Returns `default_value` if the key is absent. The
# caller owns the default — different consumers can use different
# defaults for the same key without migrating stored data.
func get_value(key: String, default_value: Variant = null) -> Variant:
	return _values.get(key, default_value)

# Write a value. Persists immediately. Variant value can be any
# JSON-encodable type (bool, int, float, String, Array, Dictionary).
# Non-encodable types (Object, Vector*, Color, etc) round-trip badly
# through JSON — pass them as their primitive components.
func set_value(key: String, value: Variant) -> void:
	_values[key] = value
	_persist()
	emit_signal("setting_changed", key, value)

func has_value(key: String) -> bool:
	return _values.has(key)

# Drop the key. Returns true iff the key existed before the call.
func remove_value(key: String) -> bool:
	if not _values.has(key):
		return false
	_values.erase(key)
	_persist()
	emit_signal("setting_removed", key)
	return true

func keys() -> Array:
	return _values.keys()

# Wipe every setting. Persists the empty state. No batch signal —
# clear is rare and consumers can refresh on demand by re-reading
# whichever keys they care about.
func clear() -> void:
	_values.clear()
	_persist()


# ---------- Internals ----------

func _load() -> void:
	_loaded = true
	if not FileAccess.file_exists(_path):
		return
	var f: FileAccess = FileAccess.open(_path, FileAccess.READ)
	if f == null:
		return
	var content: String = f.get_as_text()
	f.close()
	# Use the JSON instance API so a malformed settings file produces a
	# returned error code instead of an engine push_error.
	var parser: JSON = JSON.new()
	var err: Error = parser.parse(content)
	if err != OK:
		push_warning("settings_manager: parse failed at %s: %s"
			% [_path, parser.get_error_message()])
		return
	var data: Variant = parser.data
	if not (data is Dictionary):
		push_warning("settings_manager: %s did not contain a JSON object" % _path)
		return
	var values_raw = (data as Dictionary).get("values", {})
	if values_raw is Dictionary:
		_values = values_raw

func _persist() -> void:
	var dir: String = _path.get_base_dir()
	if not dir.is_empty():
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var f: FileAccess = FileAccess.open(_path, FileAccess.WRITE)
	if f == null:
		push_warning("settings_manager: cannot persist to %s" % _path)
		return
	var payload: Dictionary = {
		"schema_version": SCHEMA_VERSION,
		"values":         _values,
	}
	f.store_string(JSON.stringify(payload, "  "))
	f.close()
