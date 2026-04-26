# ADR 009: Minimal UI shell — programmatic Control tree

- **Status:** Accepted
- **Date:** 2026-04-24

## Context

With Orchestrator + PluginManager + AssetManager wired up, the app could
dispatch generations and ingest their outputs, but there was no surface for
a human to actually drive it. Everything ran through `tools/integration/`
scripts or unit tests. We needed a small UI shell that:

1. Lists the plugins the app knows about and shows which are active.
2. Lets the user type a prompt, pick a plugin, and dispatch.
3. Shows in-flight tasks with progress + cancel.
4. Shows the asset catalog (with type filter + metadata).

We deliberately did NOT need:

- Authentication / credential-store unlock UI (dev still flips this via
  env-vars; the unlock UX is a follow-up).
- Pixel-perfect styling. This is a dev tool.
- Plugin-specific param pickers. Stubbing `params = {}` is enough to prove
  the plumbing.

Open questions going in:

1. **Scene files vs. code?** Godot's idiomatic path is `.tscn` scenes
   hand-edited in the editor. But scenes are semi-binary text, diff poorly
   in code review, and make headless unit tests awkward.
2. **Where does the shell get its data?** Reach for the `/root/Orchestrator`
   autoload, or take the orchestrator as a parameter?
3. **How does the UI stay live?** Poll Orchestrator state, or subscribe to
   signals / EventBus events?

## Decision

1. **Programmatic Control tree.** The root `scenes/main.tscn` is a stub
   that wires in `scripts/ui/main_shell.gd`; all other UI nodes are built
   in `_ready()` as plain `Control` subclasses. The shell owns four panels,
   each its own script under `scripts/ui/`:

   - `plugin_panel.gd`    — left sidebar, plugin list with status.
   - `generate_form.gd`   — center top, plugin dropdown + prompt + submit.
   - `task_list.gd`       — center bottom, live task rows.
   - `asset_gallery.gd`   — right sidebar, asset catalog with filter.

2. **`bind(orch)` on every panel.** The shell's `bind_orchestrator(orch)`
   threads the Orchestrator instance through its four children. No panel
   directly reaches for the `/root/Orchestrator` autoload itself — that's
   done once, in `main_shell._ready`, as a fallback when no bind was done
   first. Tests inject a fresh Orchestrator via `bind_orchestrator()`
   without ever touching the autoload.

3. **Signal-driven refresh, not polling.** Panels connect to their
   respective sources:

   - `plugin_panel` subscribes to `EventBus.plugin_registered /
     plugin_enabled / plugin_disabled`.
   - `generate_form` subscribes to `EventBus.plugin_enabled / disabled`
     to keep its dropdown current.
   - `task_list` subscribes to `PluginManager.plugin_task_progress /
     completed / failed`.
   - `asset_gallery` subscribes to `AssetManager.asset_ingested /
     asset_deleted`.

   Every `.connect()` is guarded by `is_connected` so re-binding (e.g. in
   tests) doesn't stack duplicate handlers.

4. **Tests live at the structural level.** `tests/test_ui_shell.gd` does
   not render pixels — GUT runs headless. Instead it verifies:
   - The shell builds its panels on `_ready`.
   - Each panel responds correctly to the exact signals it claims to
     subscribe to.
   - Edge cases (no orchestrator bound, empty plugin list) render a
     placeholder row instead of crashing.

## Consequences

- **Everything is diffable.** No binary .tscn that swings on unrelated
  editor state. Someone reviewing a UI change reviews GDScript.
- **Headless tests are trivial.** `add_child_autofree(panel); panel.bind(orch)`
  is the entire setup; no scene-packing pipeline needed.
- **Layout tweaks cost a code edit.** Changing a minimum size or a panel's
  position means editing `main_shell.gd`, not dragging in the editor. For
  a dev tool where we touch the layout rarely, that's the right tradeoff.
- **No hard dependency on the Orchestrator autoload.** Panels work against
  ANY Orchestrator instance. Useful for tests; potentially useful for
  future "embed the orchestrator in another app" scenarios.
- **EventBus becomes the contract surface for plugin lifecycle.** Panels
  don't poke PluginManager's internals to learn about enabled-state
  changes — they listen on EventBus. This means any future subsystem
  that enables/disables plugins (e.g. a settings page) only has to
  post the event and every panel updates.

## Alternatives considered

- **Hand-edited `.tscn` per panel.** Rejected. Each tscn is another file
  that drifts from code, another merge conflict target, and worse for
  test setup (we'd have to `load()` and `instantiate()` the scene).
- **One giant `main.gd` that builds everything inline.** Rejected. Panels
  need their own internal state (lists, filters, selections); keeping each
  behind its own script makes that state obvious and testable in
  isolation.
- **Poll `/root/Orchestrator` on a timer.** Rejected. We already emit the
  exact signals we need; polling is latency-for-no-reason.
- **Use the autoload directly in every panel.** Rejected. Tests would
  have to stand up the real autoload or monkey-patch `/root/Orchestrator`
  mid-run. `bind(orch)` is one extra line at setup time and buys us full
  test isolation.
- **Build the whole UI in one scene with editor-driven layout.**
  Attractive in principle — Godot's editor is good. Rejected for MVP
  because the layout is trivial (three panels in an HBox) and the
  editor-driven workflow has a real code-review cost.

## Follow-ups

- **Credential unlock UX.** A modal dialog that calls
  `Orchestrator.unlock_and_register(password)` instead of requiring env
  vars. Gates everything below it. Design: a full-screen overlay on app
  startup until unlock succeeds.
- **Plugin-specific param editor.** Read `plugin.get_param_schema()` and
  render typed inputs (enum → dropdown, number → slider, etc).
- **Asset preview.** Text: inline `<Label>`. Audio: an `AudioStreamPlayer`
  + transport. Image: a `TextureRect`. 3D: a small viewport with the
  imported `.glb`. This lands alongside the scene-import layer (deferred
  from ADR 008).
- **Keyboard-first dispatch.** `Ctrl+Enter` on the prompt submits; arrow
  keys navigate the task list. Small polish, high daily-driver value.
- **Cost footer.** Sum of `asset.cost` across the catalog, displayed in
  the status bar. Trivial once the budget-tracker phase lands.
