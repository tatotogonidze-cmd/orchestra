# ADR 001: Async, signal-based plugin contract

- **Status:** Accepted
- **Date:** 2026-04-20
- **Supersedes:** the original synchronous sketch that returned `Dictionary` from `generate()`.

## Context

A 3D asset generation call with Tripo or Meshy routinely takes 30 seconds to
several minutes. Audio generation (ElevenLabs, Suno) is shorter but still
second-scale. If `BasePlugin.generate()` were synchronous, every call would
block the Godot main thread, freeze the editor UI, and make cancellation
impossible without teardown-level hacks.

We also want multiple generations in flight at once (parallel mode: 3D + audio
+ dialogue for the same prompt). A synchronous API forces either threads
(painful with Godot's thread/GDScript safety rules) or a hand-rolled queue.

## Decision

`BasePlugin.generate(prompt, params)` returns a **plugin-local task id
(`String`) immediately** and reports outcomes via signals:

- `task_progress(task_id, progress: float, message: String)` — optional
- `task_completed(task_id, result: Dictionary)`
- `task_failed(task_id, error: Dictionary)`
- `task_stream_chunk(task_id, chunk: Variant)` — optional, for streaming
  providers

The **PluginManager re-emits** these signals with plugin-namespaced task ids
so callers don't have to know which plugin produced a given id.

`cancel(task_id) -> bool` is the only way to stop a running task. Errors use
the common error contract defined in ADR 004.

## Consequences

- No thread safety concerns in plugin code — everything runs on the main
  thread driven by `await`.
- Plugin implementations are straightforward: `await` the network call,
  `emit_signal("task_completed", ...)`.
- Callers (UI, automation, tests) use `await manager.plugin_task_completed`
  or connect handlers — no polling.
- The manager can trivially track many concurrent tasks in a single
  dictionary.

## Alternatives considered

- **Threaded sync API.** Rejected: GDScript thread safety is fragile, the
  Godot docs themselves warn about it, and we get no benefit over `await`.
- **Callback parameter.** (`generate(prompt, params, on_done: Callable)`.)
  Rejected: signals compose better with editor tooling, GUT's
  `watch_signals`, and the EventBus — and support multiple listeners for
  free.
