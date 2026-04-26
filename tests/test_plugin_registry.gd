# Unit tests for PluginRegistry: shape of entries, lookup helpers,
# instantiate() for every registered plugin. No network.

extends GutTest

const PluginRegistryScript = preload("res://scripts/plugin_registry.gd")
const BasePluginScript = preload("res://scripts/base_plugin.gd")


func test_names_include_all_production_plugins():
	var names: Array = PluginRegistryScript.names()
	for expected in ["tripo", "elevenlabs", "claude"]:
		assert_true(names.has(expected), "missing plugin in registry: %s" % expected)

func test_get_entry_for_known_plugin():
	var entry: Dictionary = PluginRegistryScript.get_entry("claude")
	assert_false(entry.is_empty())
	for field in ["path", "category", "env_var", "config_keys"]:
		assert_true(entry.has(field), "entry missing field: %s" % field)
	assert_eq(str(entry["category"]), "text")
	assert_eq(str(entry["env_var"]), "ANTHROPIC_API_KEY")

func test_get_entry_for_unknown_plugin_is_empty():
	var entry: Dictionary = PluginRegistryScript.get_entry("no_such_plugin")
	assert_true(entry.is_empty())

func test_names_by_category():
	assert_eq(PluginRegistryScript.names_by_category("3d"), ["tripo"])
	assert_eq(PluginRegistryScript.names_by_category("audio"), ["elevenlabs"])
	assert_eq(PluginRegistryScript.names_by_category("text"), ["claude"])
	assert_eq(PluginRegistryScript.names_by_category("nonexistent"), [])

func test_instantiate_returns_base_plugin_subclass():
	# We instantiate each registered plugin and confirm it extends BasePlugin.
	# Nodes get auto-freed so we don't leak between tests.
	for plugin_name in PluginRegistryScript.names():
		var node = PluginRegistryScript.instantiate(plugin_name)
		assert_not_null(node, "instantiate returned null for %s" % plugin_name)
		add_child_autofree(node)
		assert_true(node is BasePluginScript, "%s is not a BasePlugin" % plugin_name)

func test_instantiate_unknown_plugin_returns_null():
	var node = PluginRegistryScript.instantiate("does_not_exist")
	assert_null(node)
