# ADR 005: Hybrid EventBus — native signals on owners, autoload for broadcast

- **Status:** Accepted
- **Date:** 2026-04-22

## Context

Two flavors of events flow through the app:

1. **Tight, 1-to-1 signals** between an owner and its direct collaborator —
   e.g. PluginManager -> UI panel for `plugin_task_progress`. The UI
   already has a reference to the manager.
2. **App-wide broadcasts** — e.g. "GDD just got saved", "credential store
   unlocked", "cost incurred". Many subsystems (sidebar, toast system,
   budget tracker, telemetry) may or may not care, and coupling each of
   them directly to the emitter is a mess.

Running both through a single autoload signal hub would be tidy conceptually
but would force every hot-path progress signal through a central node,
obscuring ownership and complicating tests.

## Decision

**Use both, for different jobs.**

- **Native signals on the owning class** for high-frequency, domain-local
  events where the listener already has a reference to the owner.
  PluginManager, GDDManager, and CredentialStore all declare their own
  signals (e.g. `plugin_task_progress`, `retry_scheduled`).
- **`EventBus` autoload** for coarse, app-wide broadcasts. EventBus has
  named signals like `gdd_updated`, `gdd_snapshot_created`,
  `credential_store_unlocked`, `cost_incurred`. Owners call
  `EventBus.post(event_name, args)` to emit, via a safe `_post_event`
  helper that **no-ops if the autoload is absent** (so unit tests without
  the autoload don't need a shim).

The decision rule:

> If a typical listener could already have a reference to the emitter, use
> a native signal. If the listener is a cross-cutting observer (logging,
> toasts, budget, telemetry) that shouldn't know about the emitter, use
> EventBus.

## Consequences

- Tests can construct `PluginManager` and `GDDManager` in isolation without
  spinning up the autoload tree.
- UIs get the ergonomic `await manager.plugin_task_completed` path for the
  task they just kicked off.
- Cross-cutting features (a cost HUD, a telemetry uploader) subscribe once
  to EventBus and don't need to know about every emitter.
- Small duplication: some events appear both on the owner and on EventBus
  (e.g. `cost_incurred`). We treat that as acceptable.

## Alternatives considered

- **EventBus only.** Rejected: every unit test needs the autoload, and
  domain locality is lost.
- **Native signals only.** Rejected: cross-cutting observers would couple
  to every emitter.
