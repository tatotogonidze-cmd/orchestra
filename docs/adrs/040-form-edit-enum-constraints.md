# ADR 040: Schema-aware enum constraints in form-edit

- **Status:** Accepted
- **Date:** 2026-05-01

## Context

ADR 032 shipped per-entity field rendering in `gdd_edit_form.gd`,
with one explicit follow-up:

> **Schema-aware enum constraints.** `assets[].type` is an enum
> (3D, Audio, ...); should render as OptionButton. Same for
> `tasks[].status`, `tasks[].priority`. Needs schema introspection
> wired into the spec table.

Today the form renders these as free-text LineEdits. A user typing
`Done` for a task's status works; typing `Don` for a typo writes
that value to the GDD. The schema rejects it on validate, but only
at save time — the user already lost the action of clicking Save
and getting bounced back. The fix is to render enums as
OptionButtons so the only values the user can pick are valid ones.

The decisions to make:

1. **Hard-coded enum values vs runtime schema introspection?**
2. **What to do with out-of-schema legacy values that already
   live in the user's GDD?**
3. **Default selection for fresh rows: first enum item, or empty?**
4. **Read-back path: branch on Control type, or store the type
   alongside the input?**

## Decision

1. **Hard-coded enum arrays in `_ENTITY_FIELD_SPEC`**, mirroring
   `gdd_schema.json`. Runtime introspection was considered and
   rejected for the same reasons as ADR 032's spec table:
   - Schema-derived rendering would either render every property
     or need a curation list — at which point we're back to a
     hard-coded table.
   - The set of "user-editable enum constraints" is a UX choice;
     the schema's `enum` keyword captures structure, not
     intent.
   - Schema evolution is rare and deliberate; updating the spec
     table is the right place to acknowledge the change.

2. **Out-of-schema values surface as `(invalid: x)` items**, NOT
   silently replaced. When `_add_entity_row` finds an entity
   record whose enum field doesn't match any allowed value:
   - It appends an extra item to the OptionButton labelled
     `(invalid: <value>)`.
   - That item is selected by default.
   - On read-back, `_read_entity_array` strips the `(invalid: …)`
     wrapper if the user didn't change the selection — the
     original value round-trips cleanly.
   - If the user picks a real enum value, the legacy value is
     overwritten on save. (That's the goal: nudge them to
     normalise.)
   This preserves legacy data while making it visible.

3. **Default selection: first enum item.** Adding a new task row
   via `+ Add` gets `status: "Ready"` and `priority: "low"`
   automatically. Rationale:
   - Enum fields are usually required by the schema. An empty
     value would fail validation; a default value is
     immediately valid.
   - The first item is the conventional "neutral" choice (Ready
     for status, low for priority — the schema authors put them
     first deliberately).
   - The user can change the selection trivially.

4. **Read-back branches on `is OptionButton` / `is LineEdit`.**
   Considered storing the input type explicitly in the row's
   metadata dict (`{"key": "status", "type": "enum", ...}`).
   Rejected — the Control's runtime type already carries the
   information, and branching on `is OptionButton` is one extra
   line vs maintaining a parallel type field.

## Spec table changes

Per-field `enum` array added to four entries:

```
"assets":
  type:   ["3D", "Audio", "Dialogue", "Code", "Image", "Texture"]

"tasks":
  status:   ["Ready", "InProgress", "Blocked", "NeedsReview", "Done", "Cancelled"]
  priority: ["low", "medium", "high", "critical"]
```

Other enum-like fields in the schema (`assets[].status` etc) stay
LineEdit-rendered for now — they aren't in the rendered field set
declared by ADR 032's spec. Adding them is a one-line change when
we decide they're worth surfacing.

## Behaviour changes

- **Adding a fresh task row via `+ Add`** now creates a record
  with `status: "Ready"` and `priority: "low"` populated, where
  before those fields would have been omitted (empty LineEdit
  text → key skipped in the read-back path).
- **Editing an existing record with no `status`** now writes
  `status: "Ready"` on save. The OptionButton's default is
  selected=0, and the read-back path doesn't distinguish
  "user didn't touch it" from "user picked Ready". This is a
  minor data-fill side-effect — but the schema requires status
  on tasks, so populating it is the right behaviour.
- **Out-of-schema legacy values are surfaced** to the user
  rather than silently passing through. The `(invalid: …)`
  label is intentionally ugly so the user wants to fix it.
- **Save round-trip is now lossy for out-of-schema values
  the user changes.** Previously: typed value preserved
  through every save. Now: changing the OptionButton selection
  overwrites the legacy value with the new in-schema one.
  This is the intended outcome (data normalisation), but it's
  worth noting.

## Consequences

- **Form-edit can no longer write invalid enum values for
  rendered fields.** The user's only path to typing them is
  by hand-editing the JSON or via chat-edit.
- **Test surface gains six new assertions** covering OptionButton
  rendering, pre-selection, change-persists, legacy preservation,
  and new-row defaults.
- **`_read_entity_array` is now polymorphic** on Control type —
  one `if/elif` branch instead of `as LineEdit`. Trivial
  pattern; opens the door to other field types (CheckBox for
  bool, SpinBox for int) when the spec wants them.
- **Existing tests continue to pass unchanged.** Tests that
  cast `inputs[key] as LineEdit` only do so for non-enum keys
  (id, title, name, description). No retrofit needed.

## Alternatives considered

- **Schema-introspected rendering at runtime.** Parse the schema
  file and dispatch on `enum`. Considered. Rejected — same
  trade-off as ADR 032's spec table.
- **Replace legacy values silently on load.** Take an
  out-of-schema `status: "LegacyValue"` and overwrite it with
  the first enum item on load. Rejected — silent data
  destruction. The `(invalid: …)` surface keeps the user in
  control.
- **Read-only "(invalid)" item that the user can't unselect.**
  Force them to pick a valid value. Rejected — breaks the
  cancel path; user opens the form to look at something, the
  status changes from `LegacyValue` to `Ready`, they hit
  Cancel, and Cancel is now lossy too (the visible state and
  the buffer have diverged).
- **Disable Save when an `(invalid:…)` is selected.** Tried
  briefly. Rejected — user should be able to save unrelated
  edits even if one task has a bad status. Auto-fix (ADR 029)
  is the right surface for forced normalisation.
- **Inline "Fix value" button next to invalid items.** Adds UI
  complexity for a rare case. Out of scope for now.

## Settings registry

No new settings keys.

## Follow-ups

- **More enum coverage.** `assets[].status` is the next obvious
  candidate; add it to the spec table when we decide it's
  worth surfacing.
- **Bool fields → CheckBox.** Same dispatch pattern. Wire when
  we add the first bool-typed primary field.
- **Min/max constraint hints on numeric fields.** Schema declares
  `polycount` ranges, etc.; surface these via SpinBox limits
  when those fields land in the rendered set.
- **Range / regex validators on free-text fields.** Schema's
  `pattern: "^mech_[a-z0-9_]+$"` could power inline validation
  for id fields.
- **Per-row "normalise" affordance.** A button that walks every
  enum field and snaps any `(invalid:…)` item to the first
  valid value. Pairs with the auto-fix story (ADR 029).
- **Schema-driven default seeding.** Auto-populate fields from
  the schema's `default` (where declared) when the user adds
  a new row.
- **Localised enum labels.** Today the enum text == the schema
  value (`InProgress`). A label-vs-value split would let us
  show "In progress" while persisting `InProgress`.
