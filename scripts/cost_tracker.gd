# cost_tracker.gd
# Per-session cost accumulator. One Node, child of Orchestrator (see
# ADR 013).
#
# Source of truth: `EventBus.cost_incurred(plugin_name, amount, unit)`.
# That signal is the canonical "money was spent" event — PluginManager
# emits it whenever a plugin reports a non-zero cost on `task_completed`.
# We bucket those amounts by category via `PluginRegistry.get_entry`
# (claude → text, elevenlabs → audio, tripo → 3d, ...).
#
# What this tracker does:
#   - Total session spend.
#   - Per-category breakdown.
#   - Optional session limit + warning threshold (defaults to 0.8 →
#     fires `budget_warning_reached` once we cross 80% of the limit).
#   - Emits `cost_updated()` after every change so the footer / HUD
#     can repaint.
#
# What this tracker does NOT do (intentionally):
#   - Hard-gate dispatches when the limit is reached. The contract for
#     `ERR_INSUFFICIENT_BUDGET` exists on BasePlugin, but enforcing it
#     in the dispatch path is a follow-up — see ADR 013. For MVP we
#     SOFT-WARN the user and trust them to back off.
#   - Persist across app restarts. "Session" really means "the lifetime
#     of this Orchestrator instance".
#   - Track cost incurred on tasks that never reached completion. The
#     cost_incurred signal is only fired on success.

extends Node

const PluginRegistryScript = preload("res://scripts/plugin_registry.gd")

signal cost_updated()
signal budget_warning_reached(spent: float, limit: float)
signal budget_limit_reached(spent: float, limit: float)

# Default warning threshold — fires at 80% of the configured limit. The
# user can set their own via `set_warning_threshold(fraction)`. Stored
# as a fraction (0.8 → 80%).
const DEFAULT_WARNING_THRESHOLD: float = 0.8

# Total spend this session, in the unit reported by the cost_incurred
# signal. We don't try to mix currencies — every real plugin today
# reports USD; if a future plugin reports something else we'll either
# convert or surface a separate counter.
var _total: float = 0.0

# category -> float. Categories come from PluginRegistry.get_entry.
# Missing-from-registry plugins land in the "unknown" bucket so their
# cost is still reflected in the total.
var _per_category: Dictionary = {}

# task_count: how many cost-incurring events we've seen. Used by the
# HUD's "Cost Per Item" line; not the same as total tasks dispatched.
var _task_count: int = 0

# Optional session limit. 0.0 means "no limit" — the tracker still
# accumulates totals, but the warning / limit signals never fire.
var _session_limit: float = 0.0

# Fraction of the limit at which to fire `budget_warning_reached`.
# Setting this to 0.0 disables the warning; setting it to 1.0 makes the
# warning equivalent to the limit signal.
var _warning_threshold: float = DEFAULT_WARNING_THRESHOLD

# Latches so we only fire each milestone once per session. Reset on
# `reset()` and any time the limit is raised above the current spend.
var _warning_fired: bool = false
var _limit_fired: bool = false


func _ready() -> void:
	# Subscribe to EventBus.cost_incurred if the autoload is around. In
	# tests where EventBus isn't loaded, callers can drive the tracker
	# manually via `record_cost(plugin, amount)`.
	var tree: SceneTree = get_tree()
	if tree == null or tree.root == null or not tree.root.has_node("EventBus"):
		return
	var bus: Node = tree.root.get_node("EventBus")
	if bus.has_signal("cost_incurred") and not bus.is_connected("cost_incurred", Callable(self, "_on_cost_incurred")):
		bus.connect("cost_incurred", Callable(self, "_on_cost_incurred"))


# ---------- Public API ----------

# Called by tests, and by `_on_cost_incurred` in production. Keeping
# this public means any future "cost happened but EventBus wasn't
# involved" path (e.g. ad-hoc fixed fees) can route through the same
# accounting.
func record_cost(plugin_name: String, amount: float) -> void:
	if amount <= 0.0:
		return
	_total += amount
	var cat: String = _category_for(plugin_name)
	_per_category[cat] = float(_per_category.get(cat, 0.0)) + amount
	_task_count += 1
	_check_thresholds()
	emit_signal("cost_updated")

# Set the session limit. 0.0 disables limit/warning signals. Setting a
# higher limit re-arms the warning/limit latches if we'd previously
# crossed them.
func set_session_limit(amount: float) -> void:
	var prev_limit: float = _session_limit
	_session_limit = max(0.0, amount)
	# Re-arm latches if the new limit is comfortably above the current
	# spend. The intuitive UX: "I bumped my budget, stop nagging me."
	if _session_limit == 0.0 or _session_limit > _total:
		_warning_fired = false
	if _session_limit == 0.0 or _session_limit > _total:
		_limit_fired = false
	# If we haven't moved the spend but we changed the limit, we still
	# want repaints to reflect the new "remaining" value.
	if prev_limit != _session_limit:
		emit_signal("cost_updated")

func set_warning_threshold(fraction: float) -> void:
	_warning_threshold = clamp(fraction, 0.0, 1.0)
	_warning_fired = false
	emit_signal("cost_updated")

# Zero everything. Useful at app teardown via Orchestrator.shutdown,
# and from the HUD's "Reset" button when the user wants a fresh
# session counter without restarting the app.
func reset() -> void:
	_total = 0.0
	_per_category.clear()
	_task_count = 0
	_warning_fired = false
	_limit_fired = false
	emit_signal("cost_updated")

# ---------- Read-only accessors ----------

func get_total() -> float:
	return _total

func get_session_limit() -> float:
	return _session_limit

func get_warning_threshold() -> float:
	return _warning_threshold

func get_remaining() -> float:
	# Negative remaining is meaningful — it tells the HUD to show "over
	# by $X". Callers that want a non-negative float should max(0.0, ..)
	# at the call site.
	if _session_limit <= 0.0:
		return 0.0
	return _session_limit - _total

func get_task_count() -> int:
	return _task_count

func get_average_cost_per_task() -> float:
	if _task_count == 0:
		return 0.0
	return _total / float(_task_count)

# Returns a copy of the per-category breakdown so callers can sort /
# render without risk of mutating our internal state.
func get_breakdown() -> Dictionary:
	return _per_category.duplicate()

# ---------- Internals ----------

func _on_cost_incurred(plugin_name: String, amount: float, _unit: String) -> void:
	record_cost(plugin_name, amount)

func _category_for(plugin_name: String) -> String:
	var entry: Dictionary = PluginRegistryScript.get_entry(plugin_name)
	if entry.is_empty():
		return "unknown"
	return str(entry.get("category", "unknown"))

func _check_thresholds() -> void:
	if _session_limit <= 0.0:
		return
	# Limit hit takes priority — if we just crossed both, the user
	# probably cares about the bigger one.
	if not _limit_fired and _total >= _session_limit:
		_limit_fired = true
		emit_signal("budget_limit_reached", _total, _session_limit)
	if not _warning_fired and _warning_threshold > 0.0 \
			and _total >= _session_limit * _warning_threshold:
		_warning_fired = true
		emit_signal("budget_warning_reached", _total, _session_limit)
