# asset_gallery.gd
# Right sidebar: browseable list of assets AssetManager has ingested.
#
# Shape:
#
#   Assets                                        [refresh]
#   Filter: (All)   (Text)  (Audio)  (Image)  (3D)
#   ┌───────────────────────────────────────────┐
#   │ [text] claude — "say hello"   12 B        │
#   │ [audio] elevenlabs — "hi"    3.2 KB       │
#   │ ...                                        │
#   └───────────────────────────────────────────┘
#   [ details panel — selected asset metadata  ]
#
# Auto-refreshes on AssetManager.asset_ingested / asset_deleted signals.

extends VBoxContainer

const _FILTER_OPTIONS: Array = ["all", "text", "audio", "image", "3d"]

# Emitted when the user selects a row in the list. main_shell wires this
# to asset_preview.show_for_asset. We deliberately don't reach for the
# preview overlay from inside this panel — the gallery has no business
# knowing what UI sits above it.
signal asset_clicked(asset_id: String)

var _orch: Node = null

var _filter_dropdown: OptionButton
var _list: ItemList
var _details: Label
var _current_filter: String = "all"
# list index -> asset_id for selection lookups.
var _ids_by_index: Array = []


func _ready() -> void:
	var header_row := HBoxContainer.new()
	header_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(header_row)

	var header := Label.new()
	header.text = "Assets"
	header.add_theme_font_size_override("font_size", 16)
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_child(header)

	var refresh_btn := Button.new()
	refresh_btn.text = "refresh"
	refresh_btn.pressed.connect(refresh)
	header_row.add_child(refresh_btn)

	# Filter dropdown.
	var filter_row := HBoxContainer.new()
	add_child(filter_row)

	var filter_label := Label.new()
	filter_label.text = "Filter:"
	filter_row.add_child(filter_label)

	_filter_dropdown = OptionButton.new()
	for opt in _FILTER_OPTIONS:
		_filter_dropdown.add_item(opt)
	_filter_dropdown.item_selected.connect(_on_filter_changed)
	filter_row.add_child(_filter_dropdown)

	# Asset list.
	_list = ItemList.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.custom_minimum_size = Vector2(0, 160)
	_list.item_selected.connect(_on_asset_selected)
	add_child(_list)

	# Details pane — text that updates when a row is selected.
	_details = Label.new()
	_details.text = "(select an asset)"
	_details.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_details.custom_minimum_size = Vector2(0, 80)
	_details.add_theme_font_size_override("font_size", 11)
	add_child(_details)


func bind(orch: Node) -> void:
	_orch = orch
	refresh()
	var am: Node = orch.asset_manager if orch != null else null
	if am == null:
		return
	if am.has_signal("asset_ingested") and not am.asset_ingested.is_connected(_on_asset_ingested):
		am.asset_ingested.connect(_on_asset_ingested)
	if am.has_signal("asset_deleted") and not am.asset_deleted.is_connected(_on_asset_deleted):
		am.asset_deleted.connect(_on_asset_deleted)


func refresh() -> void:
	_list.clear()
	_ids_by_index.clear()
	if _orch == null or _orch.asset_manager == null:
		_list.add_item("(no asset manager)")
		_list.set_item_disabled(0, true)
		return
	var filter: Dictionary = {}
	if _current_filter != "all":
		filter["asset_type"] = _current_filter
	var assets: Array = _orch.asset_manager.list_assets(filter)
	if assets.is_empty():
		_list.add_item("(no assets)")
		_list.set_item_disabled(0, true)
		return
	# Newest first — sort by created_at descending. AssetManager returns
	# dict order which is hash-map order on some builds; make it stable.
	assets.sort_custom(func(a, b) -> bool:
		return int(a.get("created_at", 0)) > int(b.get("created_at", 0)))
	for asset in assets:
		_list.add_item(_format_row(asset))
		_ids_by_index.append(str(asset.get("id", "")))


# ---------- Public test hooks ----------

func item_count() -> int:
	# Excludes the "(no assets)" placeholder so tests can assert "2 ingested".
	return _ids_by_index.size()


# ---------- Internals ----------

func _format_row(asset: Dictionary) -> String:
	var asset_type: String = str(asset.get("asset_type", "?"))
	var plugin: String = str(asset.get("source_plugin", "?"))
	var prompt: String = str(asset.get("prompt", ""))
	var size_kb: float = float(int(asset.get("size_bytes", 0))) / 1024.0
	var snippet: String = prompt.substr(0, 30) if not prompt.is_empty() else "(no prompt)"
	if prompt.length() > 30:
		snippet += "…"
	return "[%s] %s — %s · %s" % [asset_type, plugin, snippet, _format_size(size_kb)]

func _format_size(size_kb: float) -> String:
	if size_kb < 1.0:
		return "%d B" % int(size_kb * 1024.0)
	if size_kb < 1024.0:
		return "%.1f KB" % size_kb
	return "%.2f MB" % (size_kb / 1024.0)

func _on_filter_changed(idx: int) -> void:
	_current_filter = _FILTER_OPTIONS[idx]
	refresh()

func _on_asset_selected(idx: int) -> void:
	if idx < 0 or idx >= _ids_by_index.size():
		return
	var asset_id: String = _ids_by_index[idx]
	if _orch == null or _orch.asset_manager == null:
		return
	var asset: Dictionary = _orch.asset_manager.get_asset(asset_id)
	if asset.is_empty():
		return
	_details.text = _format_details(asset)
	# Fire the public signal so any overlay (asset_preview today, future
	# inspector tools tomorrow) can react to the selection. Existing
	# tests that don't subscribe stay unaffected.
	emit_signal("asset_clicked", asset_id)

func _format_details(asset: Dictionary) -> String:
	var lines: Array = []
	lines.append("id: %s" % str(asset.get("id", "")))
	lines.append("type: %s / %s" % [str(asset.get("asset_type", "")), str(asset.get("format", ""))])
	lines.append("plugin: %s" % str(asset.get("source_plugin", "")))
	lines.append("task: %s" % str(asset.get("source_task_id", "")))
	var prompt: String = str(asset.get("prompt", ""))
	if not prompt.is_empty():
		lines.append("prompt: %s" % prompt)
	lines.append("path: %s" % str(asset.get("local_path", "")))
	lines.append("size: %d B" % int(asset.get("size_bytes", 0)))
	if float(asset.get("cost", 0.0)) > 0.0:
		lines.append("cost: $%.6f" % float(asset["cost"]))
	return "\n".join(lines)

func _on_asset_ingested(_asset_id: String, _asset: Dictionary) -> void:
	refresh()

func _on_asset_deleted(_asset_id: String) -> void:
	refresh()
