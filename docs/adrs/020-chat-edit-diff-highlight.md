# ADR 020: Per-line diff highlight in chat-edit preview

- **Status:** Accepted
- **Date:** 2026-04-25

## Context

Phase 17 (ADR 017) shipped GDD chat-edit with a side-by-side preview:
the current GDD pretty-printed in one TextEdit, the proposed GDD
pretty-printed in another, and a one-line summary of entity-count
deltas above. ADR 017 explicitly punted real per-line diff to a
follow-up:

> Side-by-side JSON + summary, no per-line diff. A real diff would
> need either a third-party diff library or a hand-rolled LCS — both
> too much for one phase.

Phase 20 closes that follow-up. Now that the chat-edit flow is
load-bearing (and post-Phase 19 cross-reference integrity catches
breakage), users want to SEE what changed at a glance instead of
reading two ~200-line JSON dumps.

The decisions to make:

1. **Diff algorithm.** Hand-rolled LCS, Myers, Hunt-McIlroy, or pull
   in a Godot diff library?
2. **Granularity.** Line-level or word-level / character-level?
3. **Visualisation.** Per-line background colours, gutter markers
   (+/-), or full unified-diff text view?
4. **Headless testability.** How do we verify highlighting in tests
   that don't render?
5. **Performance.** GDDs are small but a 500×500 LCS table is ~250k
   table cells. OK?

## Decision

1. **Hand-rolled LCS in pure GDScript.** ~30 lines, no external
   dependency, easy to read and maintain. Standard DP table:
   `dp[i][j] = LCS(a[0..i], b[0..j])`, walk back to mark each line
   as `"context"` / `"removed"` / `"added"`. We use a flat
   `PackedInt32Array` for the table to avoid GDScript's per-row
   allocation overhead.

2. **Line-level granularity.** Word-level diff is nicer for prose;
   for pretty-printed JSON it adds noise (every changed string is
   an entire line so word-level just colours every character on a
   line). Line-level is the right unit for the document we're
   actually showing.

3. **Per-line background colour.** Godot 4's `TextEdit.set_line_background_color(line, color)`
   does the work natively. Red 30% alpha on the before view's
   removed lines; green 30% alpha on the after view's added lines.
   No gutter markers needed; the colour AND the side (before vs
   after) together convey the +/- semantics.

4. **Tests probe `_compute_line_diff` directly.** We don't try to
   verify pixels — GUT runs headless. The pure function takes two
   strings and returns `{before_marks: [...], after_marks: [...]}`
   which tests assert against. The downstream `_apply_line_marks`
   call into TextEdit is a thin wrapper that's small enough to
   trust by inspection.

5. **Performance is a non-concern.** A 500×500 PackedInt32Array
   is 1 MB and the inner loop runs in microseconds on any
   reasonable machine. We document it as a follow-up to switch
   to Myers if a profile ever surfaces it. Not before.

## Consequences

- **Chat-edit preview is now actually scannable.** The user sees
  red strips on removed-from-before lines and green strips on
  added-in-after lines. Side-by-side scrolling for context is
  still the primary interaction; highlights guide attention.
- **Order-sensitive diffs work as expected.** Reordering an entry
  array shows the moved entries as removed-from-old-position +
  added-in-new-position. Acceptable; a "moved" detection would
  need a second pass and is documented as a follow-up.
- **Identical lines that ALSO appear elsewhere still match.** LCS
  is a longest-COMMON-subsequence, not a longest-block. Two `}`
  closing braces in the before that align differently in the
  after will pick the alignment that maximises total match length,
  which is what users expect.
- **Empty inputs split into a single `[""]` line.** The standard
  `String.split("\n")` behaviour. Treating that as one removable
  / addable empty line is consistent with how the TextEdit views
  render an empty document. Documented in the test fixtures.
- **No external dependency.** Earlier we considered pulling in a
  diff library; we don't. Maintenance cost stays at zero.

## Alternatives considered

- **Myers' diff algorithm.** Faster on real-world inputs (O(N*D)
  where D is the edit distance). Not worth the extra code for
  GDDs ≤500 lines.
- **Hunt-McIlroy.** Older, similar O(N+M) typical-case cost.
  Same answer.
- **Word-level / character-level diff.** Useful for prose; noisy
  for JSON. Maybe a follow-up for the description fields
  specifically — they're the parts most likely to receive
  word-level edits.
- **External Godot diff plugin.** Found a couple on the asset
  library; pulling one in adds a dependency we don't need.
- **Unified-diff text view.** Render `+ added line` / `- removed
  line` interleaved in a single TextEdit. Considered but the
  side-by-side layout is the user-tested baseline from Phase 17
  and we didn't want to throw it away.
- **Mark "moved" lines distinctly.** Requires either a second pass
  or a longest-block algorithm; deferred.
- **Per-character / per-word diff INSIDE a changed line.**
  Visually rich but expensive in code; the line-level diff is
  enough for users to spot what changed.

## Follow-ups

- **Move detection.** A line that disappeared from one place and
  reappeared elsewhere should display as a "moved" colour
  (yellow?) on both sides.
- **Word-level diff for `description` fields.** In a future pass,
  if a long description text changed, intra-line diff would help
  spot the actual edit.
- **Sticky gutter markers.** A `[+]` / `[-]` glyph in the gutter
  next to highlighted lines, for users with custom themes that
  affect background colour visibility.
- **Switch to Myers if profiles say so.** Today's hand-rolled LCS
  is fine; a real-world ~500-line GDD diffs in <1 ms. Document
  the swap path in case GDDs grow.
- **Apply the same diff highlighting to the form-edit pre-save
  preview.** Right now form-edit just saves; a "preview before
  save" affordance would reuse this code.
- **Configurable diff colours / opacity.** A theme setting for
  users with red-green colour blindness would be considerate.
