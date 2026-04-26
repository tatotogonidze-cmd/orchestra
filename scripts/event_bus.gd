# event_bus.gd
# Autoloaded as /root/EventBus (see project.godot).
#
# Broadcast / pub-sub for 1-to-many cross-module events.
# See docs/adrs/001-event-bus.md for the decision rule:
#
#   Native signal — if exactly one known subscriber exists at design time.
#   EventBus      — if >=2 subscribers, OR cross-layer, OR global state change.

extends Node

# -- GDD events --
signal gdd_updated(path: String, document_version: String)
signal gdd_snapshot_created(version: int, path: String)
signal gdd_rollback_performed(version: int)

# -- Plugin events --
signal plugin_registered(plugin_name: String)
signal plugin_enabled(plugin_name: String)
signal plugin_disabled(plugin_name: String)

# -- Task events (high level, not per-request chatter) --
signal task_status_changed(task_id: String, status: String)

# -- Cost events (forwarded from PluginManager.cost_incurred) --
signal cost_incurred(plugin_name: String, amount: float, cost_unit: String)

# -- Asset events --
signal asset_created(asset_id: String, asset_type: String, path: String)
signal asset_updated(asset_id: String)

# -- Scene tester events --
signal scene_error(scene_id: String, error: Dictionary)

# -- Credential Store events --
signal credential_store_unlocked()
signal credential_store_locked()


# Helper for callers who don't want to hard-code signal lookup:
# EventBus.post("gdd_updated", [path, version])
func post(event_name: String, args: Array = []) -> void:
	if not has_signal(event_name):
		push_warning("EventBus: unknown event '%s'" % event_name)
		return
	callv("emit_signal", [event_name] + args)
