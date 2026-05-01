# ADR 026: Hard cost gating — opt-in dispatch refusal at the limit

- **Status:** Accepted
- **Date:** 2026-04-25

## Context

ADR 013 shipped CostTracker with SOFT warnings: `budget_warning_reached`
+ `budget_limit_reached` signals, the cost_footer color-shifts amber /
red, the BudgetHUD banner calls out the situation. Dispatching past
the limit was deliberately allowed — Phase 13 documented this as a
follow-up:

> Hard gating via `ERR_INSUFFICIENT_BUDGET`. A new
> `Orchestrator.dispatch_policy` flag: `"warn" | "hard_block"`.
> When `hard_block`, `generate(...)` checks the tracker pre-dispatch
> and refuses with the standard error if over limit. Per-plugin
> overrides next.

Phase 24 (SettingsManager) made the persistent flag trivial. Phase 25
demonstrated the "restore on consumer init" pattern. Phase 26 closes
the cost story by wiring an opt-in hard-block at the dispatch
boundary.

The decisions to make:

1. **Where does the gate live?** PluginManager, Orchestrator, or a
   new policy layer?
2. **How does the failure surface to the UI?** New error path, new
   signal, or hijack the existing task_failed channel?
3. **What about parallel_generate?** Same gate or special semantics?
4. **What's the default policy?** Warn (preserve Phase 13 behaviour)
   or hard_block (safe-by-default)?
5. **How does the user toggle it?**

## Decision

1. **Gate in `Orchestrator.generate`.** Three reasons:
   - Orchestrator already holds references to `cost_tracker` AND
     `settings_manager`. The check is one method call away in each
     direction.
   - Orchestrator IS the policy layer (ADR 007: "facade over
     PluginManager"). Putting policy here keeps `PluginManager`
     focused on dispatch mechanics.
   - The gate runs ONCE per call site. PluginManager's various
     entry points (generate, parallel_generate, etc) bypass the
     gate at lower levels; the orchestrator-level wrap ensures
     no path leaks.

2. **Synthetic `plugin_task_failed` via `PluginManager`.** When
   blocked, Orchestrator generates a task_id with a `:blocked_…`
   marker, calls `plugin_manager.emit_signal("plugin_task_failed",
   plugin_name, task_id, error)`, and returns the task_id.
   - The TaskList already subscribes to `plugin_task_failed` and
     paints failures red. No new wiring.
   - Returning the synthetic task_id lets `generate_form` show the
     usual "dispatched: <id>" status — followed almost
     immediately by the failure row in TaskList.
   - Error code is `BasePlugin.ERR_INSUFFICIENT_BUDGET` (already
     reserved in the contract since ADR 001).

3. **`parallel_generate` is NOT gated this phase.** Mid-batch
   gating is a different UX problem (do you skip the over-budget
   plugins? cancel the whole batch?). The orchestrator's
   `parallel_generate` and `parallel_generate_by_category` pass
   through to `plugin_manager` unchanged. Documented as a
   follow-up.

4. **Default: `"warn"`.** Backwards-compat with every Phase 13
   user. No setting persisted = warn behaviour. Hard-block is an
   opt-in via the BudgetHUD checkbox.

5. **Toggle in BudgetHUD, persisted via SettingsManager.**
   "Hard-block dispatches when over budget" CheckBox below the
   limit row. Persists immediately on toggle (no Apply button —
   the boolean is too small to need a commit step). Orchestrator
   re-reads on every dispatch, so the change takes effect on the
   very next Generate click.

## Settings registry update

| Key                          | Type   | Default  | Owner       | Notes                                |
|------------------------------|--------|----------|-------------|--------------------------------------|
| `cost.dispatch_policy`       | String | `"warn"` | BudgetHUD   | values: `"warn"` \| `"hard_block"`   |

(Joins `cost.session_limit`, `credentials.always_skip`,
`gdd.last_path`, `plugin.<name>.params.<field>` from earlier ADRs.)

## Consequences

- **Cost story is closed.** A user who genuinely wants to cap
  their spend can: (a) set `session_limit`, (b) toggle hard_block
  on, (c) trust the orchestrator to refuse over-budget dispatches.
  Pairs with the warning thresholds from Phase 13 — the user gets
  amber warnings BEFORE hitting the wall.
- **Default behaviour unchanged.** Anyone who never opens BudgetHUD
  or sets the policy explicitly continues to get Phase 13 warn-
  only behaviour. No surprise breakage.
- **task_list is the single source of truth for dispatch status.**
  Blocked tasks show up there alongside auth failures, network
  errors, etc. The user's mental model is "click Generate, watch
  TaskList for outcome" regardless of why a task failed.
- **Synthetic task_id with `:blocked_…` marker is searchable.**
  Tests can assert blocking by checking the marker substring.
  Future log-analysis tooling can grep for it.
- **`parallel_generate` doesn't gate.** A user who runs
  `parallel_generate(["claude","tripo","elevenlabs"], …)` while
  hard-blocked AND over-limit gets all three dispatches through
  the regular channel. They'll incur cost for all three. We
  document this in the ADR; the follow-up implements per-plugin
  decisions.
- **Policy is read on every dispatch.** No caching. A user who
  flips the checkbox mid-session sees the new behaviour on the
  next Generate. Cheap (one settings_manager.get_value call).
- **No "are you sure?" interstitial.** Going over budget refuses
  silently except via the failure row. Could become "would you
  like to raise the limit by $5?" in a future UX pass; for now
  the pattern is simple.

## Alternatives considered

- **Gate inside `PluginManager.generate`.** Conceptually wrong:
  PluginManager doesn't know about cost_tracker. Wiring it would
  add a dependency that has nothing to do with task dispatch.
- **A dedicated `DispatchGate` node.** Premature factoring. One
  if-statement in Orchestrator is enough.
- **Default to hard_block.** Tempting "safe by default", but
  silently changes Phase 13 behaviour for every existing user.
  Opt-in respects the existing contract.
- **Throw / push_error on block.** GUT would mark every test
  exercising the block as failed (engine push_error). The
  signal-based path is cleanly testable.
- **Custom signal `dispatch_blocked(plugin, error)` on
  Orchestrator.** Considered. Rejected because it would mean two
  failure surfaces (block via this signal, real failures via
  plugin_task_failed) — extra wiring at every subscriber. The
  unified channel is simpler.
- **Gate at the BasePlugin layer.** Each plugin checks before
  dispatching. Spreads policy across N plugins; missing one is
  silent breakage. Rejected.

## Follow-ups

- **`parallel_generate` policy.** Either filter the plugin list
  to only-under-budget plugins or cancel the whole batch with a
  combined error. Likely a flag: `parallel_policy: "filter" |
  "all_or_nothing"`.
- **Per-plugin policy override.** A plugin marked "expensive"
  could have a stricter local limit than the session-wide one.
  Settings keys: `cost.plugin.<name>.session_limit`,
  `cost.plugin.<name>.dispatch_policy`. ORs into the global
  decision.
- **"Are you sure?" interstitial.** When approaching the limit
  (warn band), surface a confirm dialog before the dispatch
  rather than after. Pairs with the Phase 13 warning threshold.
- **Auto-raise.** A "+$5" button next to the failure row that
  raises the session_limit and re-tries the dispatch.
- **Aggregate over multiple sessions.** Currently
  cost.session_limit resets at session start. A weekly /
  monthly rolling cap would need a new key family
  (`cost.weekly_limit`, persistent spend tracking).
- **Cost preview before dispatch.** `plugin.estimate_cost(...)`
  exists; surfacing the estimate next to the Generate button
  before the user clicks would let them see the projected
  outcome. Integrates with hard-block: refuse the click rather
  than failing post-dispatch.
- **Header-bar surfaced state.** When hard-blocked, a small
  banner or icon next to cost_footer's labels would advertise
  the policy. Today the policy is "hidden" inside BudgetHUD.
