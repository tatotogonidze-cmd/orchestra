# ADR 006: Linear GDD snapshot versioning with retention cap

- **Status:** Accepted
- **Date:** 2026-04-23

## Context

The Game Design Document (GDD) is the app's source of truth for what the
user is building. It is edited both by humans and by Claude via the
chat-edit flow. We need:

- **Undo** for at least the last handful of saves ("I didn't mean to let
  the agent rewrite the whole mechanics list").
- **Auditability** — the ability to see how the doc evolved.
- **Rollback** to a specific prior version.

We don't need full git-style branching or merge conflict resolution; this
is a single-user design tool, not a collaborative editor.

## Decision

- **Snapshot on every successful `save_gdd()`.** Validation runs first;
  invalid documents don't produce snapshots.
- **Linear numbering:** `gdd_v1.json`, `gdd_v2.json`, ... in
  `user://gdd_snapshots/` (configurable via `GDDManager.snapshot_dir` for
  tests).
- **Retention:** keep the most recent `MAX_SNAPSHOTS = 20`. Older ones are
  pruned during each save.
- **`rollback(version)`** loads and returns the requested snapshot but
  does **not** auto-apply it. The caller decides whether to pass it back
  to `save_gdd()` (which itself snapshots, giving rollback-of-rollback a
  clean history). The app posts `gdd_rollback_performed(version)` on the
  EventBus.

## Consequences

- "Show me v5" is trivial. "Diff v5 to v7" is a future feature but the
  data is already there.
- 20 snapshots of a small-to-medium GDD is a few hundred KB at worst;
  disk cost is negligible.
- Linear numbering means retention doesn't reuse ids; v1 being pruned
  leaves a gap in the sequence. Callers must not assume
  `list_snapshots()[0].version == 1`.
- Validation-gated saves guarantee every snapshot is a valid document —
  an invaluant property for chat-edit workflows where the agent might try
  something malformed.

## Alternatives considered

- **Snapshot on every keystroke.** Rejected: noisy, and the GDD isn't
  edited keystroke-by-keystroke — saves are explicit acts.
- **Git under the hood.** Rejected: overkill; adds a runtime dependency
  on git, complicates installer, and single-user undo doesn't need it.
- **Content-addressed (hash-named) snapshots.** Rejected: nicer
  dedupe story but harder for humans to scan. "v5" is a better affordance
  than `a3f91c2...`.
