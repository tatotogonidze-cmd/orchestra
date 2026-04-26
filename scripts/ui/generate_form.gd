# generate_form.gd
# Center-top input widget: pick a plugin, type a prompt, hit Generate.
#
# Shape: [Plugin v] [ Prompt TextEdit                    ] [ Generate ]
#
# On submit, we call Orchestrator.generate(plugin, prompt, {}). The
# returned namespaced task_id is surfaced in a small status label below
# the button, so the user immediately sees "their task went somewhere".
# TaskList handles the follow-up progress/completion reporting.
#
# The form refreshes its plugin dropdown from Orchestrator.plugin_names()
# on bind() and when EventBus fires plugin_enabled / plugin_disabled.
# This way the dropdown only ever lists plugins the user can actually
# dispatch to.

extends VBoxContainer

const ParamFormScript = preload("res://scripts/ui/param_form.gd")

var _orch: Node = null

var _plugin_dropdown: OptionButton
var _prompt_input: TextEdit
var _submit_button: Button
var _status_label: Label
var _param_form: Node


func _ready() -> void:
	var header := Label.new()
	header.text = "Generate"
	header.add_theme_font_size_override("font_size", 16)
	add_child(header)

	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(row)

	_plugin_dropdown = OptionButton.new()
	_plugin_dropdown.custom_minimum_size = Vector2(140, 0)
	row.add_child(_plugin_dropdown)

	_prompt_input = TextEdit.new()
	_prompt_input.placeholder_text = "prompt..."
	_prompt_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_prompt_input.custom_minimum_size = Vector2(0, 64)
	# Ctrl+Enter from the prompt fires a submit. We use gui_input rather
	# than _input/_unhandled_input so the shortcut is scoped to "user is
	# typing in the prompt right now". Avoids surprise dispatches when
	# the user hits Ctrl+Enter while focused elsewhere in the app.
	_prompt_input.gui_input.connect(_on_prompt_input)
	row.add_child(_prompt_input)

	_submit_button = Button.new()
	_submit_button.text = "Generate"
	_submit_button.pressed.connect(_on_submit)
	row.add_child(_submit_button)

	# Per-plugin parameter form. set_schema is called whenever the
	# dropdown selection changes (and on bind/refresh) so the controls
	# always match the currently-targeted plugin. Empty schema until
	# something is selected.
	_param_form = ParamFormScript.new()
	add_child(_param_form)

	# When the user picks a different plugin, refresh the param form
	# from the new plugin's schema. We also fire this manually after
	# refresh_plugins() repopulates the dropdown.
	_plugin_dropdown.item_selected.connect(_on_plugin_dropdown_changed)

	_status_label = Label.new()
	_status_label.text = ""
	_status_label.modulate = Color(0.7, 0.7, 0.7, 1.0)
	add_child(_status_label)


func bind(orch: Node) -> void:
	_orch = orch
	refresh_plugins()
	# Track enable/disable events so the dropdown is always current.
	var tree: SceneTree = get_tree()
	if tree == null or tree.root == null or not tree.root.has_node("EventBus"):
		return
	var bus: Node = tree.root.get_node("EventBus")
	var cb: Callable = Callable(self, "_on_plugin_lifecycle")
	for sig_name in ["plugin_enabled", "plugin_disabled"]:
		if bus.has_signal(sig_name) and not bus.is_connected(sig_name, cb):
			bus.connect(sig_name, cb)


func refresh_plugins() -> void:
	_plugin_dropdown.clear()
	# Source plugin names from PluginManager.active_plugins rather than
	# Orchestrator.plugin_names() — the latter reads orchestrator-level
	# bookkeeping that's set AFTER the EventBus signals fire (registration
	# completes), so listening for plugin_enabled and then querying
	# orchestrator state was racing with itself. plugin_manager is the
	# single source of truth for "what's actually dispatchable right now".
	var pm: Node = _orch.plugin_manager if _orch != null else null
	if pm == null:
		_plugin_dropdown.add_item("(no orchestrator)")
		_plugin_dropdown.set_item_disabled(0, true)
		_submit_button.disabled = true
		_param_form.clear()
		return
	var names: Array = (pm.active_plugins as Dictionary).keys() if "active_plugins" in pm else []
	if names.is_empty():
		_plugin_dropdown.add_item("(no plugins registered)")
		_plugin_dropdown.set_item_disabled(0, true)
		_submit_button.disabled = true
		_param_form.clear()
		return
	for n in names:
		_plugin_dropdown.add_item(str(n))
	_submit_button.disabled = false
	# Refresh the param form for whichever plugin is now selected.
	# Dropdown auto-selects the first item on `add_item`, so we have a
	# valid index here.
	_refresh_param_form_for_selection()


# ---------- Internals ----------

func _on_submit() -> void:
	if _orch == null:
		return
	var idx: int = _plugin_dropdown.selected
	if idx < 0:
		_status_label.text = "pick a plugin first"
		return
	if _plugin_dropdown.is_item_disabled(idx):
		# Placeholder row ("(no plugins registered)") — nothing to dispatch.
		return
	var plugin_name: String = _plugin_dropdown.get_item_text(idx)
	var prompt: String = _prompt_input.text.strip_edges()
	if prompt.is_empty():
		_status_label.text = "prompt is empty"
		return
	var params: Dictionary = _param_form.get_values() if _param_form != null else {}
	var tid: String = str(_orch.generate(plugin_name, prompt, params))
	if tid.is_empty():
		_status_label.text = "dispatch failed (see logs)"
		return
	_status_label.text = "dispatched: %s" % tid
	# Leave the prompt in the box so the user can tweak + resubmit; they
	# can clear it themselves. Lots of iterative prompting flows want this.

func _on_plugin_lifecycle(_plugin_name: String) -> void:
	refresh_plugins()

# Dropdown selection changed — re-render the param form against the new
# plugin's schema. Item index is what OptionButton hands us; we resolve
# back to the plugin name and look up the schema via plugin_manager.
func _on_plugin_dropdown_changed(_idx: int) -> void:
	_refresh_param_form_for_selection()

func _refresh_param_form_for_selection() -> void:
	if _param_form == null or _orch == null:
		return
	var idx: int = _plugin_dropdown.selected
	if idx < 0:
		_param_form.clear()
		return
	if _plugin_dropdown.is_item_disabled(idx):
		_param_form.clear()
		return
	var plugin_name: String = _plugin_dropdown.get_item_text(idx)
	var pm: Node = _orch.plugin_manager
	if pm == null or not (pm.active_plugins as Dictionary).has(plugin_name):
		_param_form.clear()
		return
	var plugin: Node = (pm.active_plugins as Dictionary)[plugin_name]
	if plugin == null or not plugin.has_method("get_param_schema"):
		_param_form.clear()
		return
	var schema: Dictionary = plugin.call("get_param_schema") as Dictionary
	_param_form.set_schema(schema)

# Keyboard shortcut handler for the prompt input. Ctrl+Enter (or
# Cmd+Enter on macOS — Godot maps `command_or_control_autoremap` for
# this style, but we keep it explicit here) submits without inserting
# a newline. We `accept_event()` so the TextEdit doesn't also paste a
# blank line.
func _on_prompt_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key: InputEventKey = event as InputEventKey
	if not key.pressed or key.echo:
		return
	# KEY_ENTER is the main return key; KEY_KP_ENTER is the keypad one.
	# Both should submit on Ctrl-modified.
	var is_enter: bool = key.keycode == KEY_ENTER or key.keycode == KEY_KP_ENTER
	if not is_enter:
		return
	if not (key.ctrl_pressed or key.meta_pressed):
		return
	get_viewport().set_input_as_handled()
	_on_submit()
