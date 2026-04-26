# Unit tests for the Orchestrator autoload. No network — we use fake api_keys
# and rely on each plugin's "api_key present = healthy (deferred)" contract.
#
# These tests build fresh Orchestrator instances rather than using the real
# /root/Orchestrator autoload, so each test starts from a clean slate.

extends GutTest

const OrchestratorScript = preload("res://scripts/orchestrator.gd")
const PluginRegistryScript = preload("res://scripts/plugin_registry.gd")

# Env vars we might set/clear during a test. Defensive cleanup in after_each
# ensures no test leaks state into the next.
const TEST_ENV_VARS: Array = [
	"TRIPO_API_KEY",
	"ELEVENLABS_API_KEY",
	"ANTHROPIC_API_KEY",
]

var orch


func before_each():
	# Clear env vars up front so the developer's shell-level exports don't
	# accidentally register a plugin and break the "no creds" tests.
	for v in TEST_ENV_VARS:
		OS.set_environment(v, "")
	orch = OrchestratorScript.new()
	add_child_autofree(orch)
	# Pin the AssetManager to a unique test root so we don't pollute user://
	# or collide with the asset_manager tests that share the default dir.
	if orch.asset_manager != null:
		var test_root: String = "user://test_orch_assets_%d_%d" % [
			Time.get_ticks_msec(), randi() % 10000]
		orch.asset_manager.configure(test_root)

func after_each():
	# And clear again so state doesn't leak to test files that run later.
	for v in TEST_ENV_VARS:
		OS.set_environment(v, "")


# ---------- Wiring ----------

func test_ready_creates_child_nodes():
	assert_not_null(orch.plugin_manager, "plugin_manager not created")
	assert_not_null(orch.credential_store, "credential_store not created")
	assert_not_null(orch.asset_manager, "asset_manager not created")
	assert_not_null(orch.cost_tracker, "cost_tracker not created")
	assert_not_null(orch.gdd_manager, "gdd_manager not created")
	# The children should be in the scene tree as this Orchestrator's children.
	assert_eq(orch.plugin_manager.get_parent(), orch)
	assert_eq(orch.credential_store.get_parent(), orch)
	assert_eq(orch.asset_manager.get_parent(), orch)
	assert_eq(orch.cost_tracker.get_parent(), orch)
	assert_eq(orch.gdd_manager.get_parent(), orch)


# ---------- Explicit config path ----------

func test_register_plugin_with_config_succeeds():
	var r: Dictionary = orch.register_plugin_with_config("claude", {"api_key": "sk-ant-test"})
	assert_true(bool(r["success"]), str(r))
	assert_true(orch.is_registered("claude"))
	assert_eq(orch.plugin_names(), ["claude"])

func test_register_plugin_with_config_unknown_plugin_fails():
	var r: Dictionary = orch.register_plugin_with_config("bogus", {"api_key": "x"})
	assert_false(bool(r["success"]))
	assert_false(orch.is_registered("bogus"))

func test_register_plugin_with_config_bad_config_fails():
	# Empty api_key → plugin's initialize() rejects → registration fails.
	var r: Dictionary = orch.register_plugin_with_config("claude", {})
	assert_false(bool(r["success"]))
	assert_false(orch.is_registered("claude"))

func test_register_multiple_plugins_all_show_up():
	orch.register_plugin_with_config("claude", {"api_key": "sk-ant"})
	orch.register_plugin_with_config("elevenlabs", {"api_key": "xi-test"})
	orch.register_plugin_with_config("tripo", {"api_key": "tripo-test"})
	var names: Array = orch.plugin_names()
	assert_true(names.has("claude"))
	assert_true(names.has("elevenlabs"))
	assert_true(names.has("tripo"))


# ---------- Auto-register path ----------

func test_register_all_available_with_nothing_set_returns_empty():
	# Store is locked, env vars cleared in after_each of the prior test.
	# after_each runs AFTER the test, so at the start of this one we must
	# re-clear in case a previous run in the same process left state.
	for v in TEST_ENV_VARS:
		OS.set_environment(v, "")
	var enabled: Array = orch.register_all_available()
	assert_eq(enabled, [])

func test_register_all_available_picks_up_env_vars():
	OS.set_environment("ANTHROPIC_API_KEY", "sk-ant-from-env")
	var enabled: Array = orch.register_all_available()
	assert_true(enabled.has("claude"), "claude not registered from env var: %s" % str(enabled))
	assert_true(orch.is_registered("claude"))

func test_register_all_available_is_idempotent():
	OS.set_environment("ANTHROPIC_API_KEY", "sk-ant-from-env")
	var first: Array = orch.register_all_available()
	var second: Array = orch.register_all_available()
	assert_eq(first, second, "second call produced different set")
	# Still exactly one claude registration.
	assert_eq(orch.plugin_names().size(), 1)


# ---------- Credential-store-beats-env precedence ----------

func test_credential_store_wins_over_env():
	# Put a key in env AND in the (unlocked) credential store, then confirm
	# the store value is what the plugin actually gets.
	OS.set_environment("ANTHROPIC_API_KEY", "sk-FROM-ENV")
	var unlock: Dictionary = orch.credential_store.unlock(
		"test-password", "user://test_credentials_%d.enc" % Time.get_ticks_msec())
	assert_true(bool(unlock["success"]))
	orch.credential_store.set_credential("claude", "api_key", "sk-FROM-STORE")

	orch.register_all_available()
	assert_true(orch.is_registered("claude"))

	# The plugin was initialized with whichever key won — read it back from
	# the plugin node.
	var plugin_node = orch.plugin_manager.plugins["claude"]
	assert_eq(plugin_node.api_key, "sk-FROM-STORE")


# ---------- Lifecycle ----------

func test_shutdown_clears_state():
	orch.register_plugin_with_config("claude", {"api_key": "sk"})
	orch.shutdown()
	assert_eq(orch.plugin_names(), [])
	assert_false(orch.credential_store.is_unlocked())


# ---------- Facade ----------
#
# Orchestrator.generate / parallel_generate / cancel are one-line passthroughs
# to PluginManager. Their contracts are covered by test_plugin_manager.gd; no
# need to duplicate here, and the "unregistered plugin" failure path emits a
# push_error from PluginManager that GUT would flag as unexpected.


# ---------- Asset pipeline wiring ----------
#
# We simulate plugin completions by emitting plugin_manager.plugin_task_completed
# directly — that's the exact seam the real wiring listens on. We don't go
# through the real plugins (Claude, Tripo, ElevenLabs) because their generate()
# would make network calls.

func test_completed_task_with_asset_type_ingests():
	var task_id: String = "claude:fake-task-1"
	var result: Dictionary = {
		"asset_type": "text",
		"format": "plain",
		"text": "orchestrator-wired output",
		"cost": 0.0,
	}
	orch.plugin_manager.plugin_task_completed.emit("claude", task_id, result)
	# _on_plugin_task_completed awaits asset_manager.ingest; one frame suffices
	# for the text path (no HTTP fetch).
	await get_tree().process_frame
	assert_eq(orch.asset_manager.count(), 1, "asset not ingested from signal")
	var assets: Array = orch.asset_manager.list_assets()
	assert_eq(str(assets[0]["source_plugin"]), "claude")
	assert_eq(str(assets[0]["source_task_id"]), task_id)

func test_completed_task_without_asset_type_is_ignored():
	# No asset_type → no asset. Keeps the pipeline out of the way of
	# non-generative plugin calls (future health-check / "ping" style tasks).
	orch.plugin_manager.plugin_task_completed.emit(
		"claude", "claude:noop", {"status": "ok"})
	await get_tree().process_frame
	assert_eq(orch.asset_manager.count(), 0)

func test_prompt_cache_attaches_prompt_to_ingested_asset():
	# Seed the prompt cache directly — the generate() facade normally does
	# this, but we can't go through a real plugin in a no-network test. The
	# contract we care about is: when plugin_task_completed arrives with a
	# task_id we've seen via generate(), the ingested asset gets the prompt.
	var tid: String = "claude:fake-prompt-probe"
	orch._prompts_by_task[tid] = "write a haiku about wiring"
	orch.plugin_manager.plugin_task_completed.emit("claude", tid, {
		"asset_type": "text",
		"format": "plain",
		"text": "wires hum through nodes",
	})
	await get_tree().process_frame
	var assets: Array = orch.asset_manager.list_assets()
	assert_eq(assets.size(), 1)
	assert_eq(str(assets[0]["prompt"]), "write a haiku about wiring",
		"prompt wasn't carried from cache to ingested asset")
	# Cache should be empty after consumption — otherwise it'd leak across runs.
	assert_false(orch._prompts_by_task.has(tid),
		"prompt cache entry not cleared after completion")

func test_failed_task_clears_prompt_cache():
	# A prompt cached for a task that ultimately fails should not leak across
	# retries-that-give-up.
	var tid: String = "claude:doomed"
	orch._prompts_by_task[tid] = "this one will fail"
	orch.plugin_manager.plugin_task_failed.emit("claude", tid, {"code": "NETWORK"})
	assert_false(orch._prompts_by_task.has(tid),
		"prompt cache wasn't cleared by failure signal")

func test_shutdown_clears_prompt_cache():
	orch._prompts_by_task["claude:a"] = "alpha"
	orch._prompts_by_task["tripo:b"] = "beta"
	orch.shutdown()
	assert_eq(orch._prompts_by_task.size(), 0, "shutdown didn't clear prompt cache")
