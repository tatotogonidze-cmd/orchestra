# ADR 004: Namespaced task ids and a retry alias for stable identity

- **Status:** Accepted
- **Date:** 2026-04-22

## Context

Each plugin assigns its own task ids. Two issues follow from that:

1. **Collisions.** Two plugins can both generate `task_1` on the same call
   to `parallel_generate(["mock_3d", "mock_audio"], ...)`. Callers must be
   able to tell them apart.
2. **Retry identity.** When a retryable failure triggers a new `generate()`
   attempt under the hood, the plugin produces a *new* inner task id. If we
   surface that new id, a UI that was tracking the original id silently
   loses its handle. Rollback, cancellation, and "is this task done yet?"
   all break.

We also want a common error shape so callers (and retry logic) can make
decisions without plugin-specific branching.

## Decision

- **Namespace every task id at the manager boundary** as
  `"<plugin_name>:<inner_id>"`. The manager stores `active_tasks` keyed by
  the namespaced id; signals always carry the namespaced id.
- **Keep the ORIGINAL namespaced id stable across retries** via a
  `_retry_alias: Dictionary` that maps `current_namespaced_id ->
  original_namespaced_id`. Signal emission consults the alias and reports
  the original id to external listeners. Internal bookkeeping uses the
  current id.
- **Standard error contract** from all plugins:

  ```gdscript
  {
      "code": String,       # see ERR_* constants on BasePlugin
      "message": String,
      "retryable": bool,
      "retry_after_ms": int # optional
      "raw": Variant        # optional: provider-specific payload
  }
  ```

  The manager retries iff `retryable == true` and the task hasn't exceeded
  `retry_config.max_retries`. Backoff is exponential with
  `max(retry_after_ms, base_delay_ms * multiplier^attempt)` capped at
  `max_delay_ms`.

## Consequences

- `cancel()` accepts only namespaced ids; bare ids return `false`. Test
  `test_cancel_bad_namespace_returns_false` locks this in.
- External code only ever sees one id per logical task, no matter how many
  retries happen under the hood.
- The `retry_scheduled(task_id, attempt, delay_ms)` signal exposes the
  retry lifecycle to UIs and tests without breaking identity.
- Internal code has to be careful to use the alias when emitting and the
  current id when mutating `active_tasks`. Helpers in
  `plugin_manager.gd` (`_on_task_progress`, `_on_task_completed`,
  `_on_task_failed`, `_schedule_retry`) are the single place this logic
  lives.

## Alternatives considered

- **Fresh ids on retry, forward mapping via callback.** Rejected: pushes
  identity complexity onto every caller.
- **Retry at the plugin level.** Rejected: each plugin would re-implement
  the same logic, inconsistently. Rate-limit handling in particular
  benefits from a centralized policy (ADR 005's EventBus also surfaces it
  globally).
