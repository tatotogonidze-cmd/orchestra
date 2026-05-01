# ADR 032: Per-entity custom fields in form-edit

- **Status:** Accepted
- **Date:** 2026-04-25

## Context

ADR 018 shipped form-based GDD edit with a uniform shape: every entity
type rendered as `[id, description]`. ADR 018 explicitly noted this
as the biggest scope-gap:

> **Per-entity custom fields.** `character.name`,
> `scene.connections`, `dialogue.lines`. Each entity type can ship
> its own row template — the form would dispatch by type. Likely
> the largest follow-up to actually close this out.

Looking at the schema, the uniformity was wrong:

- `characters[].name` is required, but Phase 18 didn't render it.
- `scenes[].name` is required, but Phase 18 hid it under "description"
  (which doesn't exist on scenes).
- `tasks[].title` is the primary field, NOT description.
- `dialogues[].character_id` is required and links to the characters
  pool.

A user could load a GDD into form-edit and SAVE it back as broken —
the form would write `description` to a scene that doesn't accept
that key, surviving only because validate is shallow.

The decisions to make:

1. **Per-type field set: hard-coded or schema-derived?**
2. **Field shapes for MVP:** strings only, or also booleans / arrays
   / dicts?
3. **Layout per type:** how do field widths flex when types have 2
   vs 4 fields?
4. **Backwards compatibility with Phase 18 row API?**
5. **What about fields the form STILL won't render** (character.stats
   dict, scene.entry_points array)?

## Decision

1. **Hard-coded per-entity field spec.** A
   `_ENTITY_FIELD_SPEC: Dictionary` constant in `gdd_edit_form.gd`,
   keyed by entity_type, listing `[{key, min_width, expand}, ...]`.
   The schema COULD drive this — we'd parse `properties` for each
   entity, infer fields — but:
   - The schema declares MORE fields than we want to render
     (timestamps, structured sub-fields).
   - "Which fields are user-editable in MVP" is a UX decision, not
     a structural one.
   - Schema-derived rendering is its own future concern (a real
     "render whatever the schema says" mode would join param_form's
     pattern at the top level — different ADR).

2. **Strings only for MVP.** Every spec field renders as a LineEdit.
   No CheckBoxes, no SpinBoxes, no list editors.
   - Booleans (e.g. `assets[].generated_by` shape) are rare in the
     "primary fields" set we render.
   - Arrays (`tasks[].dependencies`, `scenes[].entry_points`) need
     dedicated UI; their cross-ref wiring also intersects with
     ADR 029's auto-fix.
   - Dicts (`character.stats`) need typed-key/value editors.
   These all stay un-rendered and pass through via the buffer.

3. **Per-field `min_width` + `expand`.** Each spec field declares
   its visual hint:
   - `min_width: int` — pinned column width for fixed-shape fields
     (id, type tags).
   - `expand: bool` — whether the LineEdit takes remaining space.
   At most one expand-field per row (the description-style
   long-text field). This keeps rows visually consistent across
   types.

4. **Row API change: `inputs` dict, not `id` + `desc` properties.**
   The Phase 18 row entry was `{row, id, desc, original}`. Phase
   32 changes to `{row, inputs: {key: LineEdit}, original}`.
   Tests + `_read_entity_array` updated. Cleaner generalisation
   — adding a new field to the spec doesn't change the row entry
   shape.

5. **Buffer-preserves-extras still applies.** Fields NOT in
   `_ENTITY_FIELD_SPEC[type]` (character.stats, scene.entry_points,
   dialogue.nodes, every metadata-style timestamp) survive a
   round-trip via the original-record deep-copy in
   `_read_entity_array`. Same trick as Phase 18, unchanged.

## Settings registry

No new settings keys. The spec is hard-coded, so no per-user
configuration to persist.

## Per-type field rendering (MVP)

| Entity type   | Rendered fields              | Un-rendered (preserved in buffer)                          |
|---------------|-------------------------------|------------------------------------------------------------|
| mechanics     | id, description               | dependencies                                                |
| assets        | id, type, path                | status, generated_by, version, parent_asset_id, tags, created_at |
| tasks         | id, title, description        | status, priority, dependencies, related_*_ids, blocked_by, dates, assigned_to |
| scenes        | id, name                      | related_asset_ids, entry_points                             |
| characters    | id, name, role                | stats, asset_id                                             |
| dialogues     | id, character_id              | nodes                                                       |

## Consequences

- **Form-edit can author every entity type without breaking it.**
  A user creating a new character types id + name + role — no
  invented "description" field that would write garbage.
- **Phase 18 round-trip semantics preserved.** Extras still pass
  through, so deleting a row still preserves anything you didn't
  edit, etc.
- **Existing tests need a one-line update.** The
  `row_entry["id"]` / `row_entry["desc"]` accessors become
  `row_entry["inputs"]["id"]` / `row_entry["inputs"]["description"]`.
  Same shape, slightly deeper nesting.
- **Adding a new entity type is one entry in the spec.** Whatever
  primary fields it declares become editable. The cross-ref
  validator (ADR 019) still needs separate updating per its own
  reference table — they're decoupled.
- **The form's vertical real estate grows per type.** Tasks now
  show 3 fields per row, characters show 3, scenes 2. Layout
  budget is fine — modal width is 720px.
- **The "description" field for entity types that don't have one
  in the schema is now gone from the form.** Scene's "description"
  was never persisted (additionalProperties=false rejected it on
  save). Phase 18 silently dropped the field; Phase 32 doesn't
  render it. Behaviourally identical, just visually correct now.

## Alternatives considered

- **Schema-driven rendering.** Parse the JSON Schema at load time
  and render fields from `properties`. Considered. Rejected for
  MVP: the schema declares MORE than the user wants to edit
  inline, and the render-by-type table makes the UX
  intentional ("these are the fields").
- **Per-type subclasses of a base RowController.** Class hierarchy
  per entity type. Overkill for "render N LineEdits". The spec
  table is data; the row builder is one polymorphic function.
- **Inline expansion for nested structures.** A character row
  with a [+] that expands stats into a sub-form. Considered for
  MVP. Rejected as scope-creep — character.stats is a Dictionary
  whose keys vary per genre. Needs its own editor design.
- **Shipping description for everything.** Match Phase 18's
  uniformity, just rename per type ("name" for characters,
  "title" for tasks, ...). Cosmetic; doesn't fix the structural
  issue (writing a non-schema field to scenes).
- **Renderer plugins per entity type.** Each entity type ships
  its own `xxx_row_form.gd`. Heavy abstraction for what's a
  small data table.

## Follow-ups

- **Array-field editors.** A reusable "string list" sub-widget
  for `tasks[].dependencies`, `scenes[].related_asset_ids`,
  `entry_points`, `dialogue.nodes[].next_node_ids`. Pairs with
  the cross-ref validator (ADR 019) — these arrays should
  ideally pick from a dropdown of valid ids.
- **Dict editors.** `character.stats` needs a typed key/value
  editor. Probably waits for a "genre profile" abstraction
  (combat stats vs roleplaying stats vs story stats).
- **Entry-point editor.** `scenes[].entry_points` is an array
  of objects with id + from_scene_id + position[3]. Specialised
  sub-form.
- **Dialogue node editor.** `dialogues[].nodes` is the most
  structured field — text + conditions + next_node_ids. Real
  dialogue-tree editor is its own ADR.
- **Schema-aware enum constraints.** `assets[].type` is an
  enum (3D, Audio, ...); should render as OptionButton. Same
  for `tasks[].status`, `tasks[].priority`. Needs schema
  introspection wired into the spec table.
- **Schema-driven defaults.** Auto-populate fields from the
  schema's `default` when the user adds a new row. Today the
  + button creates a row with empty fields.
- **Reorderable rows.** Drag rows up/down to change ordering
  in the array. Useful for tasks (dependency order) and
  scenes (presentation order).
