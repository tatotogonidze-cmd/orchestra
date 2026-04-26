# ADR 003: Pin Godot 4.2.2 and prefer lambdas over `Callable.bind()`

- **Status:** Accepted
- **Date:** 2026-04-21

## Context

Our plugin manager re-emits per-plugin signals with the plugin name prepended.
The obvious first implementation is:

```gdscript
plugin.task_progress.connect(_on_task_progress.bind(plugin_name))
```

Intent: the handler would receive `(plugin_name, task_id, progress, message)`.

**Observed behavior:** Godot's `Callable.bind()` appends bound arguments at
the **end**, not the beginning. Handlers written with the expected order
silently receive `(task_id, progress, message, plugin_name)`, and GUT tests
inspecting signal arg[0] fail with "expected 'mock_3d', got a task id".

This is a well-known source of hours-of-debugging pain. We decided to lock
the toolchain and coding convention to head this off.

## Decision

- **Pin Godot 4.2.2.** Document the exact version in the README and in the
  project file. CI (future) will use the same version.
- **Do not use `Callable.bind()` to inject context into plugin signal
  handlers.** Always use a lambda closure:

  ```gdscript
  plugin.task_progress.connect(
      func(task_id: String, progress: float, message: String) -> void:
          _on_task_progress(plugin_name, task_id, progress, message))
  ```

- Unit test `test_generate_and_progress_signal_argument_order` in
  `tests/test_plugin_manager.gd` guards against regression by asserting
  `params[0] == "mock_3d"` on the re-emitted signal.

## Consequences

- A future Godot upgrade is a deliberate, tracked decision (new ADR), not a
  drive-by `project.godot` bump.
- Closures carry the local `plugin_name` without surprises.
- Slightly more verbose than `.bind()`, but the verbosity pays for itself
  the first time someone adds a new plugin signal.

## Alternatives considered

- **Hope `.bind()` works the expected way.** Rejected: it doesn't, and the
  failure mode is subtle.
- **Upgrade to 4.3+ and see if `.bind()` changed.** Rejected for the MVP:
  we want a known-good baseline. Revisit post-MVP.

## Verification log

- **2026-04-24 — Godot 4.6.2.stable.mono (v4.6.2, GUT 9.6.0).** Full suite
  `godot --headless -s addons/gut/gut_cmdln.gd -gconfig=.gutconfig.json`
  passes: 50/50 tests, 149 asserts, 3.18s, 1 pending (the documented
  engine-push_error limitation in `test_wrong_password_rejected`), 0
  unexpected errors.
  - The lambda-closure pattern from this ADR works identically on 4.6.2;
    the signal-argument-order regression test passes.
  - 4.2.2 remains the pin of record for *what we develop against* so the
    team has a known-good baseline, but 4.6.2 is known to run the code.
  - Before bumping the pin we want to see: CI on 4.6.x, and a conscious
    pass over any 4.3→4.6 breaking changes (especially signal typing and
    any `.bind()` behavior revisions).
