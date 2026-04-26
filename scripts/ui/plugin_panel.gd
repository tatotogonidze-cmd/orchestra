# plugin_panel.gd
# Left sidebar: shows every plugin known to PluginRegistry and whether it's
# currently registered/active with the bound Orchestrator.
#
# The panel is passive — it doesn't register/enable plugins itself. That's
# Orchestrator's job (via unlock_and_register / register_all_available).
# We just reflect state.
#
# Refresh triggers:
#   - On bind (initial paint).
#   - When Orchestrator's PluginManager posts events to EventBus.
#     We subscribe to plugin_registered / plugin_enabled / plugin_disabled
#     if an EventBus autoload is present; otherwise we rely on the caller
#     to invoke refresh() manually.

extends VBoxContainer

const PluginRegistryScript = preload("res://scripts/plugin_registry.gd")

# Emitted when the user clicks "Manage credentials". main_shell listens for
# this and shows the CredentialEditor overlay. We deliberately don't reach
# for the editor from inside this panel — that would couple the sidebar to
# a specific overlay node by name, and break test isolation.
signal manage_credentials_requested()

var _orch: Node = null
var _list: ItemList
var _manage_button: Button


func _ready() -> void:
	# Header.
	var header := Label.new()
	header.text = "Plugins"
	header.add_theme_font_size_override("font_size", 16)
	add_child(header)

	_list = ItemList.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.custom_minimum_size = Vector2(0, 200)
	add_child(_list)

	_manage_button = Button.new()
	_manage_button.text = "Manage credentials…"
	_manage_button.tooltip_text = "Edit per-plugin API keys saved in the credential store"
	_manage_button.pressed.connect(_on_manage_pressed)
	add_child(_manage_button)


func bind(orch: Node) -> void:
	_orch = orch
	refresh()
	# Subscribe to EventBus if available so the panel stays live without
	# callers having to nudge us.
	var tree: SceneTree = get_tree()
	if tree == null or tree.root == null or not tree.root.has_node("EventBus"):
		return
	var bus: Node = tree.root.get_node("EventBus")
	# Listen to the three plugin lifecycle signals. Guard is_connected so
	# re-binding doesn't stack duplicate connections.
	var cb: Callable = Callable(self, "_on_plugin_lifecycle")
	for sig_name in ["plugin_registered", "plugin_enabled", "plugin_disabled"]:
		if bus.has_signal(sig_name) and not bus.is_connected(sig_name, cb):
			bus.connect(sig_name, cb)


func refresh() -> void:
	_list.clear()
	if _orch == null:
		_list.add_item("(no orchestrator bound)")
		_list.set_item_disabled(0, true)
		return
	var known: Array = PluginRegistryScript.names()
	if known.is_empty():
		_list.add_item("(no plugins in registry)")
		_list.set_item_disabled(0, true)
		return
	for plugin_name in known:
		var label: String = _format_row(str(plugin_name))
		_list.add_item(label)


# ---------- Internals ----------

func _format_row(plugin_name: String) -> String:
	# We deliberately query plugin_manager rather than orchestrator's
	# `is_registered`. Orchestrator sets its `_registered[plugin_name]`
	# AFTER `_register_and_enable` returns, while plugin_manager flips
	# its state BEFORE emitting the EventBus signals that drive our
	# refresh. Reading orchestrator state here meant the signal handler
	# ran before _registered was true, painting "[unregistered]" — and
	# never refreshing again. plugin_manager is in sync with the signal.
	var pm: Node = _orch.plugin_manager if _orch != null else null
	var registered: bool = pm != null and pm.has_method("is_plugin_registered") \
		and bool(pm.call("is_plugin_registered", plugin_name))
	var active: bool = pm != null and pm.has_method("is_plugin_active") \
		and bool(pm.call("is_plugin_active", plugin_name))
	var marker: String
	if active:
		marker = "[active]"
	elif registered:
		marker = "[registered]"
	else:
		marker = "[unregistered]"
	return "%s %s" % [marker, plugin_name]

func _on_plugin_lifecycle(_plugin_name: String) -> void:
	# All three signals have the same shape — one String arg.
	refresh()

func _on_manage_pressed() -> void:
	emit_signal("manage_credentials_requested")
