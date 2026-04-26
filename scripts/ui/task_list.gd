# task_list.gd
# Center-bottom live list of in-flight + recently-terminated generation tasks.
#
# Each row renders:   [plugin]  prompt snippet   [====progress====]  [cancel]
#
# Lifecycle:
#   - plugin_task_progress  → update progress bar, optionally update label
#   - plugin_task_completed → mark row as done (green), auto-remove after a beat
#   - plugin_task_failed    → mark row as failed (red), keep visible
#
# Rows are looked up by namespaced task_id. PluginManager uses retry aliases
# so a retried task keeps the same reported id on our side — one row, one
# identity across retries.

extends VBoxContainer

var _orch: Node = null

# task_id -> {row: Control, bar: ProgressBar, label: Label}
var _rows: Dictionary = {}

var _header: Label
var _list_box: VBoxContainer


func _ready() -> void:
	_header = Label.new()
	_header.text = "Tasks"
	_header.add_theme_font_size_override("font_size", 16)
	add_child(_header)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(scroll)

	_list_box = VBoxContainer.new()
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list_box)


func bind(orch: Node) -> void:
	_orch = orch
	var pm: Node = orch.plugin_manager if orch != null else null
	if pm == null:
		return
	# Hook the three task-lifecycle signals. Guard against double-connect so
	# re-binding in tests doesn't stack callbacks.
	if not pm.plugin_task_progress.is_connected(_on_progress):
		pm.plugin_task_progress.connect(_on_progress)
	if not pm.plugin_task_completed.is_connected(_on_completed):
		pm.plugin_task_completed.connect(_on_completed)
	if not pm.plugin_task_failed.is_connected(_on_failed):
		pm.plugin_task_failed.connect(_on_failed)


# ---------- Public test hooks ----------

func row_count() -> int:
	return _rows.size()

func has_row(task_id: String) -> bool:
	return _rows.has(task_id)


# ---------- Signal handlers ----------

func _on_progress(plugin_name: String, task_id: String, progress: float, message: String) -> void:
	var row: Dictionary = _ensure_row(plugin_name, task_id)
	(row["bar"] as ProgressBar).value = clamp(progress * 100.0, 0.0, 100.0)
	if not message.is_empty():
		(row["label"] as Label).text = "%s — %s" % [plugin_name, message]

func _on_completed(plugin_name: String, task_id: String, result: Dictionary) -> void:
	var row: Dictionary = _ensure_row(plugin_name, task_id)
	(row["bar"] as ProgressBar).value = 100.0
	var asset_type: String = str(result.get("asset_type", ""))
	var suffix: String = ""
	if not asset_type.is_empty():
		suffix = " (%s)" % asset_type
	(row["label"] as Label).text = "%s — done%s" % [plugin_name, suffix]
	# Tint green via modulate.
	(row["row"] as Control).modulate = Color(0.6, 1.0, 0.6, 1.0)

func _on_failed(plugin_name: String, task_id: String, error: Dictionary) -> void:
	var row: Dictionary = _ensure_row(plugin_name, task_id)
	var code: String = str(error.get("code", "UNKNOWN"))
	var msg: String = str(error.get("message", "")).substr(0, 80)
	(row["label"] as Label).text = "%s — FAILED %s: %s" % [plugin_name, code, msg]
	(row["row"] as Control).modulate = Color(1.0, 0.6, 0.6, 1.0)


# ---------- Row construction ----------

func _ensure_row(plugin_name: String, task_id: String) -> Dictionary:
	if _rows.has(task_id):
		return _rows[task_id]

	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_box.add_child(row)

	var label := Label.new()
	label.text = "%s — running…" % plugin_name
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.custom_minimum_size = Vector2(220, 0)
	row.add_child(label)

	var bar := ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = 100.0
	bar.value = 0.0
	bar.custom_minimum_size = Vector2(120, 0)
	row.add_child(bar)

	var cancel := Button.new()
	cancel.text = "cancel"
	cancel.pressed.connect(func() -> void: _on_cancel(task_id))
	row.add_child(cancel)

	var entry: Dictionary = {"row": row, "bar": bar, "label": label}
	_rows[task_id] = entry
	return entry

func _on_cancel(task_id: String) -> void:
	if _orch != null and _orch.has_method("cancel"):
		_orch.cancel(task_id)
