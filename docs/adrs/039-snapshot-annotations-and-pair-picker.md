# ADR 039: Snapshot annotations + pair-wise picker

- **Status:** Accepted
- **Date:** 2026-05-01

## Context

ADR 035 shipped Compare-against-current — pick a snapshot, see what
changed since then. Two follow-ups were called out at the time and
deferred:

1. **Pair-wise picker** — compare any two snapshots, not just
   snapshot-vs-current. The diff helper (`diff_versions`) was
   already built; the UI surface wasn't.
2. **Annotations** — per-snapshot user-typed note. Five snapshots
   in, `v3` doesn't tell you whether that's "before stealth
   refactor" or "after content-policy fix" without rolling back
   to look. Snapshots are mostly disposable, but the ones the
   user wants to remember should be labelable.

Both follow-ups close out ADR 035. Combining them into one phase
keeps the surface area focused on the snapshot-timeline UI and
shares test infrastructure (multiple-snapshot fixtures).

The decisions to make:

1. **Annotation storage: inside the snapshot JSON or sidecar?**
2. **Sidecar location: per-snapshot or single shared file?**
3. **Trim/empty semantics: what's "no annotation"?**
4. **Pair picker UX: two dropdowns, two list-pickers, or
   click-to-select-A then click-to-select-B?**
5. **Default selection in the dropdowns?**

## Decision

1. **Sidecar JSON, NOT inside the snapshot.** The snapshot file is
   a verbatim GDD copy — adding non-GDD fields would either:
   - Break `validate()` if we put it at the root.
   - Pollute `metadata` with non-GDD fields.
   - Both have downstream cleanup implications.
   A sidecar (`gdd_snapshots/annotations.json`) keeps the
   snapshot files unchanged and gives us one place to read every
   annotation when listing.

2. **Single shared annotations file**, NOT per-snapshot
   `gdd_v3.note.txt`. Reasons:
   - One file ⇒ one `_load_annotations()` call covers all
     versions in `list_snapshots()`. Per-snapshot files would
     need N reads.
   - One file ⇒ one place to clean up when `_prune_snapshots()`
     drops old versions; we erase the entry from the dict and
     re-save. Per-snapshot files would need separate `remove`
     calls per pruned version.
   - One file ⇒ cleaner test isolation (one path, one
     `_rmdir_recursive` call covers everything).

3. **Whitespace trimmed; empty string clears.** `set_snapshot_
   annotation(v, "   ")` is treated as `set("")` which erases
   the entry. Matches the LineEdit's commit semantics — typing
   spaces and committing means "I don't want a note" rather than
   "my note is three spaces".

4. **Two dropdowns + Compare button.** Considered:
   - **List-pickers** (`ItemList`, click to select). More clicks
     for the user; doesn't scale to many snapshots.
   - **Click-to-select-A-then-B model**. Feels clever but breaks
     the "one click = one action" convention used everywhere
     else.
   - **Two dropdowns** scale to MAX_SNAPSHOTS (20) without
     overwhelming the UI, work with keyboard navigation, and
     visually communicate "pick two things, then Diff".
   The `Compare:` label + `→` between dropdowns make the order
   obvious (A is the "before" side; B is the "after" side).

5. **Default selection: oldest A, newest B.** "What changed from
   the start to now?" is the most common pair-picker question.
   Users who want a different pair just pick from the dropdowns;
   the default minimises clicks for the common case.

## Storage shape

```
user://gdd_snapshots/
  ├── gdd_v1.json
  ├── gdd_v2.json
  ├── gdd_v3.json
  └── annotations.json    ← new in Phase 39

annotations.json content:
  {
    "1": "first cut",
    "3": "before stealth refactor"
  }
```

Keys are stringified versions (JSON object keys are always strings).
Versions without an annotation are absent from the dict; the
`get_snapshot_annotation(v)` API returns `""` for absent keys.

## Snapshot row layout change

**Before (ADR 035):**
```
[v1] [path label, expand]    [Compare] [Rollback]
```

**After (ADR 039):**
```
[v1] [annotation LineEdit, expand]    [Compare] [Rollback]
                                                 ↑
Path moved to the v-label's tooltip — discoverable on hover
without competing with the annotation input for space.
```

The annotation LineEdit:
- Pre-fills with the saved annotation (or empty + placeholder).
- Persists on `text_submitted` (Enter) and `focus_exited` (click
  away). Same convention as the credential editor + GDD edit
  form (Phase 18 / 32).

## Pair-picker layout

```
[Compare:] [v1 — first cut ▾]  →  [v3 — before stealth ▾]  [Diff]
```

The dropdown labels show `vN` plus the annotation when present
(`v3 — before stealth refactor`) so the user can pick by name
rather than version number. Falls back to bare `vN` for snapshots
without annotations.

## Settings registry

No new keys — annotations live with the snapshots they describe,
not in user preferences. The `gdd.last_path` setting indirectly
controls which snapshot directory annotations apply to (via
`gdd_manager.snapshot_dir` defaulting to `user://gdd_snapshots/`).

## Consequences

- **Snapshots become labelable.** The user can mark "the one
  before the big refactor" so they can find it later without
  rolling back through every version.
- **`list_snapshots()` return shape grew one field.** Existing
  callers that read `version` / `path` are unaffected (extra
  fields are ignored). The two callers that needed annotations
  (`_render_snapshots`, `_build_pair_picker`) read it explicitly.
- **`_prune_snapshots()` cleans up annotations for dropped
  versions.** Otherwise the sidecar would accumulate orphan
  notes for snapshots that no longer exist on disk.
- **Pair picker is the second consumer of `_snapshot_diff_section`.**
  Compare-against-current and pair-wise compare share the same
  rendering surface — they overwrite the panes and header. Both
  call `_compute_line_diff` + `_apply_line_marks`; styling stays
  uniform.
- **Sidecar file is human-readable JSON.** Power users can edit it
  directly; the manager re-reads on every operation. No caching =
  no staleness bugs.
- **Annotation trim / empty-clear semantics propagate to the
  UI layer for free.** The LineEdit doesn't need extra logic;
  `_on_annotation_committed` calls `set_snapshot_annotation` and
  the manager handles the trim/clear path.

## Alternatives considered

- **Annotation inside `metadata.user_note`.** Rejected: pollutes
  the GDD's own metadata, every consumer of the GDD would have
  to know to ignore it. Sidecar keeps separation clean.
- **Per-snapshot `.note` file** (`gdd_v3.note.txt`). Rejected:
  N file reads per `list_snapshots`, N delete calls per prune.
  Single JSON wins on every dimension.
- **Annotation field on the snapshot's filename.** `gdd_v3
  _before_stealth.json`. Rejected: invalidates the version-
  parsing convention (`gdd_vN.json`), and renaming files when
  notes change is fragile.
- **Pair picker via two ItemLists.** Considered. Rejected — too
  much horizontal real estate for the same operation a pair of
  dropdowns covers.
- **Inline diff per row.** Click a snapshot to see what it
  changed vs. its predecessor. Considered. Rejected — that's a
  different question from "compare arbitrary pair", and the
  pair picker covers it (pick `vN` and `vN-1`). A dedicated
  "step diff" affordance is a possible follow-up.

## Follow-ups

- **Inline step diff.** Per-row "show changes vs previous"
  button. Trivial wrapper around `diff_versions(v-1, v)`.
- **Created-at metadata strip.** Each row could surface
  `metadata.updated_at` from the snapshot's GDD content so
  the user sees timestamps alongside annotations. Pairs with
  the existing tooltip-only path display.
- **Filter by annotation.** Once snapshots accumulate, a
  "show only labelled snapshots" toggle helps power users.
- **Annotation in markdown export.** When a snapshot is
  exported via ADR 034 / `save_markdown`, prepend the
  annotation as a comment block. Useful for changelog
  generation.
- **Snapshot tags.** Comma-separated tags rather than free-form
  notes; enables filtering and grouping. Annotation is the
  v0; tags are the natural v1.
- **Branch-and-rollback.** Roll back to v3, work on it, save —
  today that creates v4-as-divergence-from-v3. A "branch from
  here" affordance makes the divergence intentional.
