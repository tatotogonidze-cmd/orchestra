# ADR 013: Cost footer + Budget HUD — soft-warning cost awareness

- **Status:** Accepted
- **Date:** 2026-04-25

## Context

Until now the orchestrator has tracked cost on every ingested asset
(`asset.cost`) and re-emitted `cost_incurred` on the EventBus, but
nothing surfaced any of that to the user. A 10-second flurry of
parallel `parallel_generate(["claude", "elevenlabs", "tripo"])` calls
could spend several dollars before the user noticed — there was no
running total, no limit, no warning.

The Phase 13 goal: make the user *aware* of session cost in the
moment, without yet introducing the friction of hard gating. Two
related surfaces:

1. A persistent **cost footer** at the bottom of the main shell —
   always visible, never blocks anything, color-coded by state.
2. A **Budget HUD** modal — opened from the footer — with a
   progress bar, per-category breakdown, a settable limit, and a
   reset button.

The decisions to make:

1. **Where does the cost data come from?** `EventBus.cost_incurred`
   is the canonical "money was spent" event, fires on every
   non-zero-cost completed task. Alternative: subscribe to
   `AssetManager.asset_ingested` and read `asset.cost` from the
   metadata.
2. **How do we categorize spend?** `cost_incurred(plugin, amount,
   unit)` doesn't carry `asset_type`. We can either (a) include it
   (signal-shape change), (b) read it from a follow-up
   `asset_ingested`, or (c) look up plugin → category via
   `PluginRegistry`.
3. **Soft warning or hard gate?** Should crossing the limit BLOCK
   further dispatches (return `ERR_INSUFFICIENT_BUDGET`), or just
   paint the footer red and trust the user?
4. **Where does the tracker live?** Autoload, child of Orchestrator,
   or just a singleton inside the UI layer?
5. **Layout impact?** A persistent footer means the existing
   three-panel HBox can no longer fill the shell directly.

## Decision

1. **Source: `EventBus.cost_incurred`.** It's the canonical signal
   for "cost happened", and it fires whether or not an asset is
   ingested (e.g. a future stateless "ping" plugin call). Reading
   from `AssetManager.asset_ingested` would have missed those.

2. **Categorize via PluginRegistry.** The signal carries
   `plugin_name`; we look up `PluginRegistry.get_entry(plugin_name).category`
   and bucket the spend (`text` / `audio` / `image` / `3d`). Plugins
   that aren't in the registry land in an `unknown` bucket so
   their cost is still reflected in the total. This avoids
   reshaping the signal contract and keeps the registry as the
   single source of truth for plugin → category.

3. **Soft warnings only — no hard gating in this phase.** The
   tracker emits `budget_warning_reached` (default at 80% of
   limit) and `budget_limit_reached` (at 100%). The footer color-
   shifts (white → amber → red) but `Orchestrator.generate(...)`
   keeps dispatching. Hard gating belongs with a richer policy
   layer (per-plugin / per-category limits, "ask before exceeding"
   prompts, etc.) and is documented as a follow-up.

4. **`CostTracker` is a child of Orchestrator.** Same shape as
   `PluginManager`, `CredentialStore`, `AssetManager`. The UI
   binds to `orch.cost_tracker`. Tests can stand up a tracker in
   isolation (no autoload required) by calling `record_cost`
   directly — same idiom as the other modules.

5. **Layout: outer VBox.** `main_shell._build_layout` now wraps
   the existing three-panel HBox in an outer VBox so the
   `cost_footer` can sit underneath it at fixed height. The HBox
   gets `SIZE_EXPAND_FILL` so it claims the rest. No panel-level
   logic moves; this is purely a vertical split.

6. **Limits are per-session, in memory only.** Setting a limit
   doesn't persist across app restart. Persistence is a follow-up
   alongside settings — see ADR 011 follow-ups for the same
   pattern. Reset zeros the running spend but PRESERVES the
   limit, because the typical "reset" is "start a fresh prompt
   session under the same budget cap".

7. **Tests probe state, not pixels.** Same pattern as ADR 010 /
   011 / 012. Footer exposes `_state: String` (`"ok" | "warning"
   | "over"`) and the relevant labels; HUD exposes `_summary_label`,
   `_limit_input`, `_breakdown_container`, etc. Internal handlers
   (`_on_apply_limit_pressed`, `_on_reset_pressed`,
   `_emit_hud_requested`) are the test seams.

## Consequences

- **Spend is visible without being intrusive.** The footer is one
  thin line at the bottom; users can ignore it during heads-down
  prompting and glance at it whenever they want a sanity check.
  No dialogs or pauses.
- **Categorization couples to PluginRegistry.** Adding a new
  plugin without adding a registry entry will land its cost in
  the `unknown` bucket. Acceptable: the registry is small and
  any new plugin needs an entry anyway for the lifecycle.
- **The contract for `ERR_INSUFFICIENT_BUDGET` is still unused.**
  It exists on `BasePlugin` and is reserved for the hard-gating
  follow-up. Documenting that here so the next person doesn't
  delete it as dead code.
- **One more overlay + one persistent panel.** `main_shell` now
  hosts five panels (plugin / generate_form / task_list /
  asset_gallery / cost_footer) plus four overlays (unlock_dialog
  / credential_editor / asset_preview / budget_hud). Still
  manageable, still decomposed.
- **Reset is destructive, but bounded.** It only zeroes the
  in-memory spend; on-disk asset costs are untouched. A user
  who wants "show all-time spend" can compute it by summing
  `AssetManager.list_assets()` cost fields — that's a different
  number and a different report.

## Alternatives considered

- **Pull cost from `AssetManager.asset_ingested` instead.**
  Misses cost incurred on tasks that don't produce assets
  (errors after a successful API call, exploratory pings). Also
  couples cost tracking to asset ingestion, which is a
  *consequence* of cost, not the cost itself.
- **Hard-gate at the limit.** Tempting and "safe", but the UX
  is strictly worse for the dev-tool case: a developer who's
  iterating fast wants visibility, not a wall. Hard gating
  belongs with explicit policy + opt-in.
- **Embed the HUD into the gallery sidebar.** Same call as ADR
  012 — the sidebar's 280px is too narrow to host a meaningful
  progress bar + breakdown rows + limit editor. The modal
  pattern wins.
- **Persist the limit to disk.** Worth doing eventually, but
  would mean adding a settings file we haven't otherwise
  needed yet. Punt.
- **Render a pie chart for the breakdown.** Pretty, but Godot's
  native control toolkit doesn't have a pie chart and rolling
  one with `_draw` is more code than it's worth at MVP. Linear
  ProgressBars per category convey the same information.
- **Use a global signal aggregator instead of `cost_tracker`.**
  Considered. Rejected because we already have one — `EventBus`
  — and adding a "tracker that does aggregation" preserves a
  clean separation: EventBus carries events, CostTracker
  computes derived state.

## Follow-ups

- **Hard gating via `ERR_INSUFFICIENT_BUDGET`.** A new
  `Orchestrator.dispatch_policy` flag: `"warn" | "hard_block"`.
  When `hard_block`, `generate(...)` checks the tracker
  pre-dispatch and refuses with the standard error if over
  limit. Per-plugin overrides next.
- **Persist the limit + warning threshold.** Settings store —
  same pattern we'd use for "always skip credential unlock".
- **Per-category limits.** "$5 on text, $20 on 3D, $0 on
  image". Useful when one provider tier is much pricier than
  the others.
- **Lock Now button in the footer.** ADR 010 follow-up. The
  reference image showed it next to "Manage Budget" — a small
  add but its own concern; deferred to keep this phase tight.
- **All-time spend report.** Walk `AssetManager.list_assets()`,
  sum `cost`, group by month / plugin / category. Probably
  lives in a separate "Reports" surface.
- **Pie chart visualization in HUD.** Custom `_draw` on a
  `Control` — straightforward but ~100 lines.
- **Live updates while the HUD is open.** Right now the HUD
  re-reads the tracker on `show_dialog` only; subscribing to
  `cost_updated` while visible would make it a live dashboard.
- **Hover tooltip on the footer** showing per-category
  breakdown without opening the HUD.
