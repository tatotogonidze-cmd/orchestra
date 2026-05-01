# plugin_registry.gd
# Single source of truth for which plugins the app knows about.
#
# The `Orchestrator` autoload reads this registry at startup (or after the
# CredentialStore is unlocked) and instantiates + registers each plugin whose
# credentials are available. Tests and the smoke-test CLI also use it so we
# never hard-code plugin paths in more than one place.
#
# Shape:
#   {
#     "tripo": {
#       "path":    "res://plugins/tripo_plugin.gd",
#       "category": "3d",
#       "env_var":  "TRIPO_API_KEY",         # fallback if credential store is empty
#       "config_keys": ["api_key"],          # keys looked up in CredentialStore
#     },
#     ...
#   }
#
# To add a new plugin: (a) implement it under plugins/, (b) add an entry here,
# (c) add credential store entries (or set the env var) and Orchestrator will
# pick it up on next unlock.

extends RefCounted
class_name PluginRegistry

const ENTRIES: Dictionary = {
	"tripo": {
		"path":        "res://plugins/tripo_plugin.gd",
		"category":    "3d",
		"env_var":     "TRIPO_API_KEY",
		"config_keys": ["api_key"],
	},
	"elevenlabs": {
		"path":        "res://plugins/elevenlabs_plugin.gd",
		"category":    "audio",
		"env_var":     "ELEVENLABS_API_KEY",
		"config_keys": ["api_key", "per_char_cost_usd"],
	},
	"claude": {
		"path":        "res://plugins/claude_plugin.gd",
		"category":    "text",
		"env_var":     "ANTHROPIC_API_KEY",
		"config_keys": ["api_key", "pricing"],
	},
	"openai_image": {
		"path":        "res://plugins/openai_image_plugin.gd",
		"category":    "image",
		"env_var":     "OPENAI_API_KEY",
		"config_keys": ["api_key", "per_image_cost_usd"],
	},
}


# All plugin names known to the registry.
static func names() -> Array:
	return ENTRIES.keys()

# Entry for a given plugin, or {} if unknown.
static func get_entry(plugin_name: String) -> Dictionary:
	return ENTRIES.get(plugin_name, {})

# All entries in a given category ("3d" | "audio" | "text" | ...).
static func names_by_category(category: String) -> Array:
	var out: Array = []
	for name in ENTRIES.keys():
		if str(ENTRIES[name].get("category", "")) == category:
			out.append(name)
	return out

# Instantiate a plugin by name. Returns null if the registry entry is missing
# or the script cannot be loaded. Caller owns the returned Node and is
# responsible for add_child() + PluginManager.register_plugin().
#
# Note on logging: "unknown plugin" is a *valid lookup result* — callers use
# this to probe the registry — so it returns null silently. A script that
# fails to LOAD despite being in the registry is a real bug and emits
# push_error.
static func instantiate(plugin_name: String) -> Node:
	var entry: Dictionary = get_entry(plugin_name)
	if entry.is_empty():
		return null
	var script: Script = load(str(entry["path"]))
	if script == null:
		push_error("plugin_registry: cannot load script '%s'" % entry["path"])
		return null
	var instance = script.new()
	if not (instance is Node):
		push_error("plugin_registry: '%s' did not produce a Node" % plugin_name)
		return null
	return instance
