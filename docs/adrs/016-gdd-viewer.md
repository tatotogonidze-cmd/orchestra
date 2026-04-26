# ADR 016: GDD viewer — read-only modal over the existing GDDManager

- **Status:** Accepted
- **Date:** 2026-04-25

## Context

GDDManager has been in the codebase since Phase 5 (ADR 006): schema-
backed validation, JSON load/save, linear snapshot versioning,
rollback. Until now, none of it had a UI surface. The user could
only interact with the GDD by editing JSON in their editor of
choice, then watching `tools/integration/` scripts read it. The
orchestrator's whole reason to exist — driving game development
from a structured design document — was effectively invisible.

The Phase 16 goal: a read-only viewer that exposes the GDD in the
app. A user can:

- Pick a path and load a `.json` GDD.
- See top-level fields (title, genres, core loop) at a glance.
- See entity counts (mechanics / assets / tasks / scenes / chars
  / dialogues).
- See the snapshot timeline and roll back to a prior version.
- Get clear feedback when the GDD is loaded but invalid (missing
  required fields, unknown root keys, bad ID prefixes).

Not in scope:

- Editing fields. Comes in Phase 17 (form-based and/or Claude
  chat-edit).
- Cross-reference integrity (GDDManager itself defers this).
- Scene-tester / runtime preview of the GDD's mechanics.

The decisions to make:

1. **Where does the GDD live in the UI?** Top-level panel,
   embedded sidebar, or modal overlay?
2. **What about edit?** Ship view-only first, or include a JSON
   editor textarea as a fallback?
3. **How do we present the snapshot timeline?** Inline rows, a
   dedicated tab, a separate dialog?
4. **Path picking.** Free-form text input, FileDialog, or
   hardcoded conventional path?
5. **Where do we add the entry point?** New header bar, new
   button somewhere, hijack the cost_footer?

## Decision

1. **Modal overlay, same shape as the others.** The GDD is too
   large to embed in any of the existing panels (mechanics +
   assets + tasks + characters + dialogues + snapshot timeline),
   and adding a fifth main-shell panel would crowd the layout.
   The overlay pattern we've been using (full-screen Control +
   dim layer + centered panel) is by now well-trodden, with
   matching test idioms.

2. **Read-only first.** Editing the GDD is its own decision (or
   set of decisions) about form layout, validation feedback,
   undo, cross-reference health, and Claude chat-edit. Shipping
   view-only:
   - Closes a real visibility gap immediately.
   - Lets us learn what the user actually wants to see before
     committing to an editor shape.
   - Keeps Phase 16 small enough to land in one session.

3. **Snapshot timeline lives in the same overlay, below the
   summary.** Sorted newest-first. Each row is `vN — path —
   [Rollback]`. Clicking Rollback calls
   `gdd_manager.rollback(version)`, surfaces the result back into
   the panel's `_current_gdd`, and emits a signal so other
   subsystems can react.

4. **Path: free-form `LineEdit` defaulting to `user://gdd.json`.**
   We considered `FileDialog`, but it pulls in an extra modal
   on top of our modal, and it's overkill for the conventional
   case where everyone keeps their GDD at the same path. Power
   users can paste any `user://` or `res://` path.

5. **Entry point: a new "GDD" button in the cost_footer.** Same
   placement reasoning as ADR 013 / 014: the footer is the only
   always-visible affordance and we already pile global
   buttons there. Three buttons (GDD / Budget HUD / Lock now)
   is the busiest the footer has been; if we add a fourth we'll
   reach for a header bar.

6. **Read GDDManager via Orchestrator.** GDDManager joins the
   other managers as a child of `Orchestrator` (constructed in
   `_ready` alongside `plugin_manager` / `credential_store` /
   `asset_manager` / `cost_tracker`). The panel's `bind(orch)`
   reaches `orch.gdd_manager`. Tests can stand up a real
   orchestrator and write fixture `.json` files into a per-test
   `user://_test_gdd_panel_*` directory.

7. **Validation results are surfaced but not blocking.** If a
   loaded GDD fails validation we still display its content and
   colour-code the status label amber, with the first three
   error messages. The user can see what's wrong AND what's
   there. A future "fix it" affordance would tighten this.

## Consequences

- **GDD is now visible in-app.** A user who's been driving the
  orchestrator from prompts can finally see the document those
  prompts feed into, alongside the asset library that comes out
  the other end.
- **Snapshot rollback has a UI.** Until now `rollback(version)`
  was a method nobody called from outside tests. The button
  surface makes the snapshot infrastructure useful.
- **Validation feedback is non-blocking.** Showing a half-broken
  GDD is the right default for a viewer — refusing to display
  invalid content would be worse UX than calling out the issues
  and letting the user look.
- **Orchestrator gains another child.** Five managers now
  (`plugin_manager`, `credential_store`, `asset_manager`,
  `cost_tracker`, `gdd_manager`). All independent; no new
  cross-cutting state.
- **The cost_footer is full.** Three buttons fit but adding more
  would be cramped — next global affordance probably wants a
  header bar.

## Alternatives considered

- **Embed GDD as a fifth main-shell panel.** Considered. Rejected
  because (a) the document is large enough to need its own
  scroll surface, and (b) the user looks at the GDD
  occasionally, not constantly — a modal matches that usage
  better.
- **JSON textarea fallback for edit-by-hand.** Tempting as a
  cheap edit path. Rejected for this phase because:
  - Hand-edited JSON skips the validate-and-save pipeline that
    GDDManager already enforces. We'd either re-implement
    validation in the textarea or end up with a "save anyway"
    button, which negates ADR 006's whole point.
  - Edit deserves its own design pass with snapshot semantics
    (every save = snapshot = rollback target).
- **Pre-load on `bind(orch)`.** We considered auto-loading
  `user://gdd.json` whenever the panel binds. Rejected —
  reading from disk on every bind feels heavy for a panel
  that may never be opened, and tests get an unwanted side
  effect.
- **Separate "Snapshots" overlay.** Could split the timeline
  into its own modal. Rejected — the timeline is short (max 20
  rows by ADR 006), and seeing it next to the document state
  is more useful than chasing it through another click.

## Follow-ups

- **Form-based edit.** Top-level fields as typed inputs (using
  the same `param_form` widget mapping idea). Lists with
  add/remove buttons. Save via `gdd_manager.save_gdd` — every
  save is a fresh snapshot.
- **Claude chat-edit.** Natural-language "make all the
  characters playable, please" → diff → preview → accept. The
  snapshot infra is built for this; the prompt flow is the
  remaining piece.
- **Cross-reference integrity validator.** ADR 006 deferred
  this; once chat-edit lands it becomes essential (Claude can
  trivially produce a `task` referencing a nonexistent
  `mech_*`).
- **Drill-down per entity type.** Click "mechanics: 5" to
  expand a sub-list with each entity's id + description.
  Trivial UI work; we just chose to focus on counts for MVP.
- **FileDialog pick.** When the conventional path stops being
  enough — multi-project setups, especially.
- **Diff view between snapshots.** Show what changed between
  v3 and v4 in a unified-diff style, rather than just naming
  the version.
- **GDD source-of-truth pinning.** Have Orchestrator subscribe
  to `gdd_updated` so plugins can be told the GDD changed. So
  far we just expose the data; nothing reacts to it.
