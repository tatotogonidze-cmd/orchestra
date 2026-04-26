# tools/integration/smoke.gd
# Headless CLI for running ONE real API call against ONE plugin.
#
# This file is the only place in the codebase that hits real provider
# endpoints. The GUT suite never does — integration testing lives here and is
# gated on the developer explicitly setting an env var.
#
# Usage (PowerShell):
#
#   $env:ANTHROPIC_API_KEY = "sk-ant-..."
#   godot --headless -s tools/integration/smoke.gd -- `
#         --plugin=claude `
#         --prompt="write a haiku about unit tests" `
#         --params='{"model":"claude-haiku-4-5","max_tokens":256}'
#
#   $env:TRIPO_API_KEY = "tripo_..."
#   godot --headless -s tools/integration/smoke.gd -- `
#         --plugin=tripo --prompt="a stylized purple dragon"
#
#   $env:ELEVENLABS_API_KEY = "xi-..."
#   godot --headless -s tools/integration/smoke.gd -- `
#         --plugin=elevenlabs --prompt="hello, world" `
#         --out=out/hello.mp3
#
# Flags:
#   --plugin=<name>      required; one of PluginRegistry.names()
#   --prompt=<text>      required
#   --params=<json>      optional; merged into the generate() params
#   --out=<path>         optional; for binary outputs (e.g. audio) copies the
#                        user:// file to this host path after success
#   --timeout=<seconds>  optional; overall timeout, default 180
#
# Exit codes:
#   0  success
#   1  cli parse / config error
#   2  plugin registration failed
#   3  task failed
#   4  task timed out
#
# This script is NOT part of the GUT suite and is deliberately procedural —
# the goal is to keep the smoke path small enough to read top-to-bottom.

extends SceneTree

# Explicit preloads — see orchestrator.gd for why we don't rely on bare
# class_name identifiers from a command-line entry point.
const PluginRegistry = preload("res://scripts/plugin_registry.gd")
const PluginManagerScript = preload("res://scripts/plugin_manager.gd")
const BasePluginScript = preload("res://scripts/base_plugin.gd")

const EXIT_OK: int = 0
const EXIT_CLI_ERR: int = 1
const EXIT_REG_ERR: int = 2
const EXIT_TASK_FAILED: int = 3
const EXIT_TIMEOUT: int = 4


func _init() -> void:
	# SceneTree's _init runs before the tree is ready. Defer the real work
	# onto the first idle frame so autoloads / add_child are safe.
	call_deferred("_run")


func _run() -> void:
	var args: Dictionary = _parse_args()
	if args.has("_error"):
		_die(str(args["_error"]), EXIT_CLI_ERR)
		return

	var plugin_name: String = str(args.get("plugin", ""))
	var prompt: String = str(args.get("prompt", ""))
	var params: Dictionary = args.get("params", {})
	var out_path: String = str(args.get("out", ""))
	var timeout_s: float = float(args.get("timeout", 180.0))

	_log("smoke: plugin=%s prompt_len=%d timeout=%ds" % [plugin_name, prompt.length(), int(timeout_s)])

	var entry: Dictionary = PluginRegistry.get_entry(plugin_name)
	if entry.is_empty():
		_die("unknown plugin '%s' (known: %s)" % [plugin_name, str(PluginRegistry.names())], EXIT_CLI_ERR)
		return

	# Build config from env-var only. Smoke tests deliberately bypass the
	# credential store so developers don't have to unlock it by hand.
	var env_var: String = str(entry.get("env_var", ""))
	var api_key: String = OS.get_environment(env_var) if not env_var.is_empty() else ""
	if api_key.is_empty():
		_die("env var %s is not set" % env_var, EXIT_CLI_ERR)
		return

	# Bring up a minimal PluginManager — we don't need the full Orchestrator
	# autoload for a one-shot call, but we do need the retry/signal plumbing.
	var pm = PluginManagerScript.new()
	pm.name = "PluginManager"
	root.add_child(pm)

	var plugin_node: Node = PluginRegistry.instantiate(plugin_name)
	if plugin_node == null:
		_die("cannot instantiate %s" % plugin_name, EXIT_REG_ERR)
		return
	pm.add_child(plugin_node)
	var plugin = plugin_node as BasePluginScript

	var cfg: Dictionary = {"api_key": api_key}
	var reg: Dictionary = pm.register_plugin(plugin_name, plugin, cfg)
	if not bool(reg.get("success", false)):
		_die("register failed: %s" % str(reg.get("error", "?")), EXIT_REG_ERR)
		return
	var en: Dictionary = pm.enable_plugin(plugin_name)
	if not bool(en.get("success", false)):
		_die("enable failed: %s" % str(en.get("error", "?")), EXIT_REG_ERR)
		return

	# Wire up listeners. We only care about the one task we're about to submit.
	var done: Array = [false]  # mutable wrapper for closure capture
	var result: Array = [null]
	var fail: Array = [null]

	pm.plugin_task_progress.connect(
		func(pn: String, tid: String, progress: float, message: String) -> void:
			_log("progress %s %.0f%% %s" % [tid, progress * 100.0, message]))
	pm.plugin_task_completed.connect(
		func(pn: String, tid: String, r: Dictionary) -> void:
			result[0] = r
			done[0] = true)
	pm.plugin_task_failed.connect(
		func(pn: String, tid: String, err: Dictionary) -> void:
			fail[0] = err
			done[0] = true)

	_log("generating…")
	var ns_tid: String = pm.generate(plugin_name, prompt, params)
	if ns_tid.is_empty():
		_die("generate() returned empty task id", EXIT_TASK_FAILED)
		return

	# Poll for completion with a hard overall timeout.
	var deadline_ms: int = Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while not done[0] and Time.get_ticks_msec() < deadline_ms:
		await create_timer(0.25).timeout

	if not done[0]:
		_log("TIMEOUT after %ds, cancelling" % int(timeout_s))
		pm.cancel(ns_tid)
		await create_timer(0.5).timeout
		_die("timed out", EXIT_TIMEOUT)
		return

	if fail[0] != null:
		_log("FAILED code=%s retryable=%s message=%s" % [
			str(fail[0].get("code", "?")),
			str(fail[0].get("retryable", false)),
			str(fail[0].get("message", ""))])
		quit(EXIT_TASK_FAILED)
		return

	var r: Dictionary = result[0]
	_log("OK asset_type=%s format=%s cost=$%.6f" % [
		str(r.get("asset_type", "?")),
		str(r.get("format", "?")),
		float(r.get("cost", 0.0))])
	_log("  path=%s" % str(r.get("path", "")))

	# For binary asset types (audio), optionally copy the user:// file out.
	if not out_path.is_empty():
		var copied: bool = _copy_out(str(r.get("path", "")), out_path)
		_log("  out=%s (%s)" % [out_path, "copied" if copied else "NOT COPIED"])

	# Text responses aren't file-based — print a preview inline.
	if r.get("asset_type") == "text":
		var text: String = str(r.get("text", ""))
		var preview: String = text.substr(0, 280)
		_log("  text: %s%s" % [preview, "…" if text.length() > 280 else ""])

	quit(EXIT_OK)


# ---------- Helpers ----------

# Minimal, permissive arg parser for `--key=value` after `--`.
# OS.get_cmdline_user_args() returns everything after `--` on the command line.
func _parse_args() -> Dictionary:
	var out: Dictionary = {"params": {}}
	for raw in OS.get_cmdline_user_args():
		var a: String = str(raw)
		if not a.begins_with("--"):
			continue
		var eq: int = a.find("=")
		if eq < 0:
			continue
		var key: String = a.substr(2, eq - 2)
		var val: String = a.substr(eq + 1)
		if key == "params":
			var json := JSON.new()
			var err: int = json.parse(val)
			if err != OK or not (json.data is Dictionary):
				return {"_error": "--params must be a JSON object, got: %s" % val}
			out["params"] = json.data
		else:
			out[key] = val
	if str(out.get("plugin", "")).is_empty():
		return {"_error": "--plugin=<name> is required"}
	if str(out.get("prompt", "")).is_empty():
		return {"_error": "--prompt=<text> is required"}
	return out

# Copy a user:// file to an external host path. Returns true on success.
func _copy_out(user_path: String, host_path: String) -> bool:
	if user_path.is_empty() or not user_path.begins_with("user://"):
		return false
	var src: String = ProjectSettings.globalize_path(user_path)
	if not FileAccess.file_exists(src):
		return false
	# Make sure the destination directory exists.
	var dir: String = host_path.get_base_dir()
	if not dir.is_empty():
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var in_f: FileAccess = FileAccess.open(src, FileAccess.READ)
	if in_f == null:
		return false
	var bytes: PackedByteArray = in_f.get_buffer(in_f.get_length())
	in_f.close()
	var out_f: FileAccess = FileAccess.open(host_path, FileAccess.WRITE)
	if out_f == null:
		return false
	out_f.store_buffer(bytes)
	out_f.close()
	return true

func _log(msg: String) -> void:
	print("[smoke] %s" % msg)

func _die(reason: String, code: int) -> void:
	push_error("[smoke] " + reason)
	print("[smoke] ERROR: %s" % reason)
	quit(code)
