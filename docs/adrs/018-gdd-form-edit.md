# ADR 018: GDD form-based edit — typed inputs alongside chat-edit

- **Status:** Accepted
- **Date:** 2026-04-25

## Context

Phase 17 shipped Claude chat-edit (ADR 017): natural-language edits to
the GDD with diff preview and snapshot-backed Apply. It works well for
exploratory or structural changes where the user describes what they
want.

It works less well for trivial changes — "rename mech_combat to
mech_battle", "bump the document version to 0.4.0", "remove the assets
list entry I just added by mistake". For those, typing into a form is
faster than dictating to Claude AND avoids the per-call API cost.

The Phase 18 goal: a form-based editor as the second edit mode,
alongside chat-edit. Both converge on `GDDManager.save_gdd` so
snapshot semantics from ADR 006 stay uniform.

The decisions to make:

1. **Form scope.** Every field, or a focused subset?
2. **Where does the form live?** A separate overlay, or another
   section inside `gdd_panel`?
3. **How do we preserve fields the form doesn't render?** A GDD has
   keys we deliberately don't expose (e.g. `core_loop.actions`,
   `character.name`, per-entity custom fields).
4. **Save semantics.** Same two-snapshot pattern as chat-edit's
   Approve, or single-save?
5. **Validation feedback.** Surface errors inline next to the
   offending field, or as a status banner?

## Decision

1. **Focused subset.** The form ships:
   - Top-level scalars: `game_title`, `core_loop.goal`,
     `metadata.document_version`.
   - Genres (string list with add/remove).
   - Per entity type (mechanics / assets / tasks / scenes /
     characters / dialogues): `id` + `description` rows with
     add/remove.

   Fields like `core_loop.actions`, `character.name`,
   `scene.connections` are NOT rendered. They survive a
   round-trip via the form's working buffer (the deep-copied GDD
   passed to `set_gdd`), so users can edit the rendered fields
   safely without losing un-rendered ones.

2. **Sub-component, embedded in `gdd_panel`.** A new file
   `scripts/ui/gdd_edit_form.gd` is a plain `VBoxContainer` with
   a `set_gdd(dict)` / `get_gdd() -> Dictionary` API and `saved`
   / `cancelled` signals. `gdd_panel` builds one and toggles
   between the view-only widgets (summary, entities, snapshots,
   chat-edit) and the form. This mirrors how `param_form`
   embeds inside `generate_form`.

3. **Buffer-preserves-extras pattern.** `set_gdd` deep-copies
   into `_buffer`. `get_gdd` writes back from form fields but
   starts from the buffer, so any field we didn't render stays
   intact. Per-entity records use the same trick: when reading
   a row back, we duplicate the original record from the buffer
   (indexed by row, not by id, so renames work) and overwrite
   only `id` and `description`.

4. **Two snapshots per Save.** Same as ADR 017's Approve flow:
   `save_gdd(_current_gdd, path)` first (pre-state snapshot,
   rollback target), then `save_gdd(edited, path)` (post-state).
   If the post-state save fails validation we leave the user in
   edit mode with a status message; the pre-state snapshot is
   already on disk (acceptable: the snapshot is of a known-good
   state, just bumped timestamp).

5. **Status-banner validation feedback for MVP.** When the
   apply step fails, the panel's `_status_label` shows
   `"save failed: <first 3 errors>"`. Inline per-field
   feedback (red borders, etc) is a follow-up — we don't yet
   have the schema-walking infrastructure to map an error
   like `"id 'xyz' does not match prefix 'mech_'"` back to the
   specific row's `LineEdit`.

6. **Tests cover the form sub-component AND the integration.**
   - `test_gdd_edit_form.gd`: pure form tests (build, set/get
     round-trip, add/remove rows, signal emission).
   - `test_gdd_panel.gd`: integration tests (Edit button gating,
     edit-mode toggling, Save writing two snapshots, Cancel not
     writing, invalid Save staying in edit mode).

## Consequences

- **The user has two edit paths.** chat-edit for "make me think",
  form for "I know what I want to type". They share `save_gdd`
  so snapshot history is consistent across both.
- **Form is opinionated about scope.** Editing characters'
  custom `name` field requires either chat-edit or hand-editing
  the JSON file. Documented as a follow-up; many users will hit
  this within a session.
- **Re-set rebuilds the form from scratch.** Switching documents
  while in edit mode is blocked (the Load button is disabled);
  Cancel-then-Load is the explicit path. This avoids silently
  discarding an in-progress edit buffer.
- **Buffer pattern leaks slightly.** `_read_entity_array`
  preserves extras by reading the row's `original` field.
  Renaming a row's id doesn't break that lookup because we
  index by row, not by id. But removing then re-adding a row
  with the same id loses the extras (the new row's original is
  `{}`). Acceptable trade-off.
- **One more sub-component.** `param_form`, `gdd_edit_form` —
  a pattern is forming around "VBoxContainer with set/get and
  signals". Future schema-driven editors should reach for this
  shape.

## Alternatives considered

- **Render every field.** The schema has dozens of optional
  per-entity fields. Rendering them all would require either a
  schema-walking renderer (substantial work; would also need to
  duplicate effort with `param_form`) or per-entity custom
  forms. Both are out of scope for one phase.
- **JSON-textarea editor.** A `TextEdit` with the full JSON
  pretty-printed, save runs JSON.parse + validate. Considered
  for power users. Rejected because (a) we already have
  `chat-edit` as the "free-form" path, (b) it loses the
  benefits of a real form (typed inputs, list controls), (c)
  inline syntax errors would need a JSON parser hooked up
  during typing.
- **Edit overlay separate from view overlay.** Two modal
  windows for the same document. Rejected: the user wants to
  see the snapshot timeline alongside the edit form, and
  switching modals would mean opening one to refer back. Same-
  panel toggle is simpler.
- **Single save (no pre-snapshot).** A new edit always overwrites
  the previous state. Rejected for the same reason as ADR 017's
  Approve: one undeclared edit that breaks something would
  leave the user with no rollback target. Two saves cost
  pennies of disk, not a concern.
- **Render id-prefix rules at the form level.** Reject empty or
  bad-prefix ids before they reach `save_gdd`. Considered. The
  form's placeholder text shows the expected prefix
  (`mech_*`, `asset_*`, etc) which is enough hint; full
  validation runs on save and is surfaced via the status label.

## Follow-ups

- **Per-entity custom fields.** `character.name`,
  `scene.connections`, `dialogue.lines`. Each entity type can
  ship its own row template — the form would dispatch by
  type. Likely the largest follow-up to actually close this
  out.
- **`core_loop.actions` and `core_loop.rewards` editors.**
  Same string-list shape as genres; could use a shared
  `string_list_form.gd` widget.
- **Inline validation feedback.** Map `errors` from
  `GDDManager.validate` back to the offending row, paint it
  red, focus the input. Real UX win once we have it.
- **Cross-reference picker.** Editing `task.depends_on` should
  offer a dropdown of existing `task_*` ids rather than a
  free-form LineEdit. Same widget pattern as
  `param_form`'s enum case.
- **Undo within edit mode.** A small undo stack so the user
  can step back through field edits without Cancel-and-restart.
- **Confirm-on-Cancel when buffer is dirty.** "You have
  unsaved changes — discard?" Pairs with the keyboard-Esc-to-
  cancel from ADR 014 if/when we extend it to the edit form.
- **Side-by-side view + edit.** Some users want to see the
  view mode while editing. Could split the panel horizontally
  or make the view a read-only sticky column. Probably its own
  ADR.
- **Schema-driven row generation.** Parse the JSON Schema and
  render fields automatically (similar idea to
  `param_form.set_schema`). Cleanest long-term path; deferred
  because the GDD schema is structurally richer than param
  schemas (nested objects, arrays of objects).
