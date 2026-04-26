# ADR 019: Cross-reference integrity validator

- **Status:** Accepted
- **Date:** 2026-04-25

## Context

ADR 006 designed the GDD validator as a SHALLOW structural check:
required fields, `additionalProperties=false`, and id-prefix patterns
(`mech_*`, `asset_*`, `task_*`, ...). It explicitly deferred
cross-reference integrity:

> Full cross-reference integrity (e.g. every dependency id exists)
> is a separate concern — TODO: add in a follow-up once chat-edit
> flow lands.

Phase 17 (chat-edit) and Phase 18 (form-edit) made the deferral
expensive. Both edit paths can introduce dangling references in
ways the shallow validator didn't catch:

- Claude can produce a `task` with `depends_on: ["task_nope"]` when
  asked to "add a quest" and inventing a non-existent prerequisite.
- A user form-renaming `mech_combat → mech_battle` orphans every
  `task.related_mechanic_ids: ["mech_combat"]` reference elsewhere.
- A user who deletes a `character` row through the form leaves
  every `dialogue.character_id` pointing at it dangling.

None of those are *structural* violations — every id matches its
prefix pattern. But every one breaks the document's semantic
integrity.

The decisions to make:

1. **What to validate.** Cross-entity refs only (mech↔mech, task→
   asset, character→asset, ...) or also intra-document graphs
   (dialogue node → next_node within the same dialogue)?
2. **Where to run it.** As part of `validate()` always, or only
   on save? Or as a separate "lint" call?
3. **Error message shape.** Generic ("unknown id 'task_nope'") or
   specific ("task 'task_b' references unknown task 'task_nope'")?
4. **Severity model.** Hard fail (`valid: false`) or warning?
5. **Performance.** Cross-ref check walks every reference field
   in O(N + R). Concerning at scale?

## Decision

1. **Cross-entity refs in this phase, intra-document graphs
   deferred.** Cross-entity refs (the table in this ADR's
   "Reference map" section) are the load-bearing case for
   chat-edit and form-edit. Intra-document graphs — currently
   just `dialogues[].nodes[].next_node_ids` — are smaller and
   more local; a dialogue editor will validate its own graph
   when it lands.

2. **Always run inside `validate()`.** Cross-ref integrity is
   part of "is this GDD valid" — same as required fields. Running
   it only on save would let an in-memory invalid GDD slip
   through the chat-edit preview unnoticed. Running it as a
   separate "lint" call would mean callers needed to know to
   call both.

3. **Specific error messages.** Format:
   ```
   <owner_kind> '<owner_id>' references unknown <target_kind>: '<bad_id>'
   ```
   Examples:
   ```
   task 'task_b' references unknown task: 'task_nope'
   character 'char_hero' references unknown asset: 'asset_ghost'
   scene.entry_point 'scene_b' references unknown scene: 'scene_phantom'
   ```
   Consistent with `_check_id_patterns`'s message shape — easy to
   surface in the chat-edit / form-edit status banners.

4. **Hard fail.** Adds the bad refs to `errors[]`; `valid` flips
   to false. Save through `GDDManager.save_gdd` refuses the
   write. Both edit paths surface the failure in their status
   labels and stay in their pending / edit state so the user
   can correct.

5. **Performance is a non-concern.** Real GDDs are small (tens
   to low hundreds of items per type). Building five
   `{id: true}` pools and walking every reference array is
   O(N) — well under a millisecond for any GDD anyone will
   author by hand. If this ever shows up in a profile we'll
   memoise per-GDD-version.

6. **Reference map is hand-maintained.** We could parse the
   schema for every `pattern: "^prefix_[a-z0-9_]+$"` and infer
   the ref topology, but the schema also has prefix-bearing
   fields that are NOT references (the `id` itself, for
   instance). Maintaining `_check_cross_references` by hand is
   ~80 lines and we get the locality of "if you add a new ref
   field to the schema, also add it here". Documented in the
   ADR + as a comment block in the function.

## Reference map

Sourced from `schemas/gdd_schema.json`:

| Owner field                              | Target |
|------------------------------------------|--------|
| `mechanics[].dependencies`               | mechanics |
| `assets[].parent_asset_id` (nullable)    | assets |
| `tasks[].dependencies`                   | tasks |
| `tasks[].blocked_by`                     | tasks |
| `tasks[].related_asset_ids`              | assets |
| `tasks[].related_mechanic_ids`           | mechanics |
| `scenes[].related_asset_ids`             | assets |
| `scenes[].entry_points[].from_scene_id` (nullable) | scenes |
| `characters[].asset_id` (nullable)       | assets |
| `dialogues[].character_id` (required)    | characters |

## Consequences

- **chat-edit's silent breakage class is closed.** Claude can
  still propose dangling refs, but `validate()` catches them
  before the diff preview goes live. The user sees a clear
  "task 'task_b' references unknown task 'task_nope'" message
  and rejects.
- **form-edit's rename problem is closed.** Renaming
  `mech_combat → mech_battle` and trying to save fails until
  the user updates references. (Auto-rename across all
  references is a separate, harder problem; see follow-ups.)
- **Existing fixtures unaffected.** Every test GDD in the
  suite leaves cross-ref arrays empty or omitted. The new
  validator is a no-op on those fixtures.
- **Adding new entity types has a new step.** Whenever the
  schema gains a new entity type or a new id-typed field,
  `_check_cross_references` must be updated. Code comment
  + ADR table + the table in `docs/architecture.md` should
  keep this discoverable.
- **No auto-fix.** A broken reference is reported, not
  resolved. Chat-edit and form-edit show the error and stop;
  the user fixes it. Auto-fix (rename propagation, dangling-
  ref removal) is a follow-up.

## Alternatives considered

- **Separate `lint(gdd) → errors` call.** Cleaner separation
  of concerns, but multiple call sites (chat-edit preview,
  form save, viewer load) would all need to remember to call
  it. Folding into `validate()` keeps the contract simple.
- **Warning-level (does not flip `valid: false`).** Considered
  for "load but warn" semantics. Rejected because save_gdd
  reuses validate, and a save with dangling refs is exactly
  the case we want to refuse.
- **Schema-driven inference.** Parse the JSON Schema for
  every `pattern: "^prefix_*"` field and infer ref topology
  automatically. The schema doesn't distinguish "this is an
  id" from "this is a reference to that kind of id" — we'd
  need an annotation system. Not worth it for ~10 ref fields.
- **Walk references on every `set_credential`-style mutation.**
  We don't have a streaming editor; `validate()` runs at the
  full-document boundary which is fine for our edit shapes.

## Follow-ups

- **Intra-dialogue node-graph validation.** Each
  `dialogue.nodes[].next_node_ids` should reference a node
  within the same dialogue. Adds graph-cycle detection too.
  Lands with the dialogue editor.
- **Auto-fix for renames.** When a user renames `mech_combat
  → mech_battle`, sweep all references and offer
  "update them too?" Pairs with form-edit.
- **Auto-cleanup for dangling refs.** A "fix-it" button next
  to the validation error: "remove all references to
  task_nope". Cheap once we surface errors with the offending
  id stamped on them — already done.
- **Cross-ref errors in chat-edit's diff preview.** Today
  errors appear in the panel's status label. Showing them
  inline, attached to the offending entity row, would be
  better.
- **Memoise pools per `_buffer` revision.** If validation
  becomes a hot path on streaming edits.
- **`docs/architecture.md` table sync.** Keep the reference
  map in this ADR + the architecture doc + the `_check_cross_references`
  comment block in lockstep when adding new ref fields.
