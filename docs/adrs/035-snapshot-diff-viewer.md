# ADR 035: Snapshot Diff Viewer

- **Status:** Accepted
- **Date:** 2026-05-01

## Context

The snapshot timeline shipped in Phase 16 (ADR 016) gave us
**rollback** — pick a version, restore it as current. What it
didn't give us was **read-only comparison**.

A user with five snapshots couldn't ask "what changed between v3
and now?" without rolling back, looking, and rolling forward
again — destructively, since each save creates a new snapshot.

The diff infrastructure to actually answer that question already
existed:

- ADR 020 — LCS line diff with red/green highlights, used by
  chat-edit's preview.
- ADR 030 — word-level diff with summary stats.
- `_apply_line_marks` — a generic helper that paints any TextEdit
  given a marks array.

The missing piece was a trigger + a place to show the result.
Phase 35 is that trigger.

The decisions to make:

1. **Compare against current vs pair-wise picker?**
2. **Reuse the existing `_diff_section` or build a new one?**
3. **Same diff granularity as chat-edit, or simpler?**
4. **What about diffing two un-snapshotted points (e.g. a
   pending chat-edit vs the loaded baseline)?**

## Decision

1. **Compare against current** as the only MVP affordance. The
   most common question is "what's changed since I made this
   snapshot?" — that's snapshot-vs-current, exactly what one
   button per row supports.
   - Pair-wise picker (compare any two snapshots) is a follow-up.
     Today's workflow: rollback to A → it becomes current →
     compare current with B. Slightly awkward but doesn't lose
     functionality (rollback creates a snapshot of the rollback,
     so B is still reachable).
   - Per-row Compare buttons fit the existing snapshot timeline
     visually — no new picker UI to build.

2. **New `_snapshot_diff_section`**, NOT a re-use of the chat-edit
   `_diff_section`. They look similar but have different semantics:
   - Chat-edit diff is **proposed**, with Approve / Reject.
   - Snapshot diff is **historical**, read-only with Close.
     Sharing one widget would mean conditionally swapping
     buttons, headers, and labels — more state to maintain than
     it saves in code volume. The new section is ~50 lines of
     layout and reuses every helper (_compute_line_diff,
     _apply_line_marks).

3. **Line-only granularity for snapshot diffs.** ADR 030 added
   word-level diffs to chat-edit because edits there are typically
   small and word-level highlighting helps spot prose changes.
   Snapshot comparison is a longer-range tool — versions can be
   many edits apart and diffs run long. Word-level highlighting
   on a 200-line diff becomes visual noise. Line-level scanning
   is what the user actually wants.
   - Word-diff is still available downstream — pair the
     snapshot-diff with a "show word changes" toggle as a
     follow-up if users ask.

4. **Two helpers in `gdd_manager`**, one for each pair shape:
   - `diff_versions(v_a, v_b)` — both sides resolved from disk.
   - `diff_version_against(v, current_gdd)` — one side from
     disk, one in-memory. Used by gdd_panel where the in-memory
     current state may not be on disk yet (pending chat-edit,
     unsaved form changes, etc.).
   Both return the same shape: `{success, before_text, after_text,
   before_version, after_version, error?}`. UI uses
   `diff_version_against` exclusively today; `diff_versions`
   exists for the pair-picker follow-up and tests.

## Output shape

```
[Snapshot v3 → current]
lines: -12  +18

┌────────────────────┬────────────────────┐
│ {                  │ {                  │
│   "game_title":    │   "game_title":    │
│   "Hero's Path",   │   "Hero's Story",  │  <- +/- highlighted
│   ...              │   ...              │
└────────────────────┴────────────────────┘

                                   [Close comparison]
```

Header carries the comparison subject. Summary carries the
quick-scan stats. Two side-by-side `TextEdit`s carry the pretty-
printed JSON with `_apply_line_marks` painting per-line
backgrounds. Close button dismisses; reopening Compare on a
different version overwrites the panes.

## Consequences

- **Snapshot timeline becomes useful for archaeology, not just
  rollback.** Users can introspect their edit history non-
  destructively.
- **Chat-edit and snapshot-compare have visibly distinct
  surfaces.** A user looking at one knows whether they need to
  decide (chat-edit) or just inspect (snapshot).
- **No new persistence keys, no new credentials, no schema
  changes.** Pure UI + helper expansion on existing primitives.
- **`_render_snapshots` re-runs on each `_refresh()`**, which
  fires on rollback / chat-edit-applied / form-save. That
  means each refresh frees the row containers, so any "Compare
  is highlighting which row" hint would need to live in
  state outside the rows themselves. We don't have that hint
  today; the open snapshot-diff section reflects the
  most-recently-clicked snapshot version in its header.
- **Identical-version comparison is a valid degenerate case.**
  Compare(v=1) when current === v1 produces a no-op diff
  (lines: -0 +0). That's correct; it just confirms equality.
- **Diff-helper names diverge slightly.** `diff_versions` is
  symmetric; `diff_version_against` is not (current_gdd is
  always "after"). The asymmetry is intentional — the
  current-vs-snapshot relationship is naturally directional.

## Alternatives considered

- **Pair-wise picker UI.** Two version dropdowns + a Compare
  button. Considered. Rejected for MVP — adds a non-trivial
  UI surface for a use-case that's not common, and per-row
  Compare against current covers ~90% of the question the user
  asks ("what changed since X?").
- **Reuse `_diff_section`.** Conditionally swap header text,
  hide Approve / Reject. Rejected: state-management cost
  exceeds the new-section cost, and the user model is
  cleaner with two distinct surfaces.
- **Split-pane vs unified diff.** Unified-diff (a single text
  view with `+`/`-` line prefixes) would save horizontal real
  estate. Rejected: chat-edit already uses split-pane, and
  consistency is worth more than the few hundred horizontal
  pixels.
- **Compare to disk on save.** "Show me what just changed"
  immediately after every save. Considered. Rejected — the
  chat-edit flow already does this for its own changes; adding
  a save-time diff would be redundant.
- **Word-diff for snapshot comparisons too.** Rejected for now
  — long-range diffs become visually noisy with word-level
  highlights. Worth revisiting if users ask.

## Follow-ups

- **Pair-wise picker.** Two dropdowns + Compare button at the
  top of the snapshot timeline. Reuses `diff_versions` (already
  built).
- **Word-diff toggle.** A "show word changes" checkbox in the
  snapshot-diff section for users who want fine-grained reads.
- **Highlight the row whose snapshot is currently being
  compared.** Visual hint so the user knows which Compare
  click landed.
- **Inline metadata strip.** Each snapshot row currently shows
  v# + path. Adding `created_at` (parsed from the snapshot's
  metadata.updated_at) would help the user pick by date.
- **Filter / search.** Once snapshots accumulate (we keep 20),
  a "show only snapshots from today" filter pairs naturally
  with the metadata strip above.
- **Diff in markdown export.** Export a diff between two
  versions as Markdown — combines ADR 034 with this one.
  Useful for changelog entries.
- **Snapshot annotations.** Per-snapshot label / note set by
  the user at save time (e.g. "before chat-edit refactor").
  Pairs naturally with the snapshot-diff workflow.
