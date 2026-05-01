# ADR 043: Asset metadata editor

- **Status:** Accepted
- **Date:** 2026-05-01

## Context

The asset gallery shipped in Phase 12 (ADR 012) with read-only
asset records. Users can preview, delete, and add-to-scene, but
they can't edit the asset's metadata. That leaves three real
workflow gaps:

1. **No human-readable labels.** Asset rows show
   `[image] openai_image — a stylized purple dragon… · 1.4 MB`.
   Useful for the first asset, less useful when the gallery
   has 30 of them. Users want to name things they care about.
2. **No tagging / taxonomy.** With many assets the user wants
   ad-hoc grouping ("hero portraits", "draft", "final cut") that
   the asset_type filter can't express.
3. **Prompt typos are permanent.** A misspelled prompt becomes
   the row label forever — or the user re-generates and burns
   API quota for a typo fix.

ADR 008 (asset manager) defined the record shape. Adding mutable
fields needs deliberate design — an asset's content hash and
filesystem location define its identity, and the wrong things
becoming editable would let the user corrupt the index.

The decisions to make:

1. **Whitelist (only-these-fields-mutable) vs blacklist (anything-
   except-these)?**
2. **Which fields are "mutable" — i.e. presentation, not identity?**
3. **In-place editor in the preview overlay vs separate edit dialog?**
4. **Tag storage: Array of strings vs comma-separated string vs
   Set?**
5. **Display name fallback when blank?**

## Decision

1. **Whitelist.** `_UPDATABLE_FIELDS` is an explicit Array
   constant in `asset_manager.gd`. A new field doesn't become
   editable accidentally — adding it to the whitelist is a
   deliberate one-line change that's easy to review.

2. **Mutable: `display_name`, `tags`, `prompt`.**
   - `display_name` (String) — human-readable label. Falls back
     to prompt-snippet when empty.
   - `tags` (Array of String) — ad-hoc taxonomy. Free-form, no
     server-side validation.
   - `prompt` (String) — editable so typos can be corrected.
     Mutating prompt doesn't re-run generation; it just updates
     the record's display.
   **Immutable** (silently dropped from updates):
   - `asset_id`, `content_hash`, `local_path`, `format`,
     `asset_type`, `source_plugin`, `source_task_id`,
     `created_at`, `size_bytes`, `source_url`. These define
     identity, provenance, or storage. Mutating any of them
     would corrupt the index or de-link the asset from its
     bytes.

3. **In-place editor in the preview overlay.** A separate "edit"
   modal would mean an extra click and a context switch.
   Inline editing inside the metadata panel keeps the user in
   one mental space — preview the asset, edit it, see the
   change in the read-only summary above, done.

4. **Tags as `Array of String`.** Stored that way in the index,
   round-tripped through JSON. The UI surface is a
   comma-separated LineEdit because most users will type tags
   that way; the parse strips whitespace and drops empties on
   save. Considered a Set type — rejected because GDScript has
   no first-class Set, and de-dup-on-input is sub-feature for
   later.

5. **Display name falls back to prompt-snippet (then asset_id)
   when blank.** Empty `display_name` means "use the
   automatically-derived label" — same as not setting it at
   all. This keeps the asset gallery row format coherent for
   un-labelled assets while letting power users override.

## Schema additions to the asset record

The whitelisted fields are stored alongside existing fields in
the AssetManager's index:

```
{
  "asset_id":     "asset_<hash>",
  "asset_type":   "image",
  "content_hash": "sha256:...",
  "local_path":   "user://assets/image/...",
  "format":       "png",
  "size_bytes":   1234567,
  "source_plugin": "openai_image",
  "source_task_id": "openai_image:abc",
  "created_at":   "2026-05-01T12:34:56Z",
  "prompt":       "<editable since Phase 43>",
  "display_name": "<editable, defaults to "">",
  "tags":         ["<editable, defaults to []>"]
}
```

`display_name` and `tags` get their defaults at read time (UI
treats absent / empty consistently).

## Signal additions

```
signal asset_updated(asset_id: String, asset: Dictionary)
```

Fires after any successful `update_asset_metadata`. Asset gallery
subscribes to refresh its row labels. Future consumers (toast
notifications, search index) get a clean hook.

## UX

```
┌─────────────────────────────────────┐
│  IMAGE / PNG                        │
│  ┌─────────────┐  ┌──────────────┐  │
│  │             │  │  [metadata]  │  │
│  │   Preview   │  │              │  │
│  │             │  │  Edit        │  │
│  │             │  │  Display name│  │
│  │             │  │  [_________] │  │
│  │             │  │  Tags (...)  │  │
│  │             │  │  [_________] │  │
│  │             │  │  Prompt      │  │
│  │             │  │  [_________] │  │
│  │             │  │   [Save md]  │  │
│  └─────────────┘  └──────────────┘  │
│                       [...] [Close] │
└─────────────────────────────────────┘
```

The metadata panel grew from 240px → 280px to fit comfortably.
Read-only summary stays on top; editor section below.

## Consequences

- **Asset rows now have human-readable labels.** Display name
  wins over prompt-snippet, gallery looks tidier.
- **Asset gallery refreshes on metadata edits** via the new
  signal. No manual nudge required.
- **AssetManager whitelist is the canonical place to extend.**
  Future fields (e.g. `quality_rating`, `archived`) become
  one-line additions.
- **Update is idempotent.** Saving twice in a row produces the
  same state. No partial-state bugs.
- **Validation is type-only.** Tag strings, display name string,
  prompt string. No content checks (length limits, allowed
  characters, etc) — those would belong in their own follow-up
  if anyone hits problems.
- **Mock plugins benefit.** mock_image_plugin's deterministic
  output now has a cleaner story for "rename it after
  generating" — useful for the gallery-stress tests we'll
  inevitably write.

## Alternatives considered

- **Blacklist approach** ("everything except these is mutable").
  Rejected — defaults toward unsafe. New fields would silently
  become editable.
- **Generic key-value `metadata` sub-object.** All edits land in
  `asset.metadata.<key>`. Considered. Rejected — every UI
  surface would need to know whether to look at the top-level
  field or the metadata sub-object. Flat is fine.
- **Separate Edit modal.** Rejected — adds clicks for what's
  fundamentally a preview-and-tweak workflow.
- **Tags as PackedStringArray.** Slightly cheaper at runtime.
  Rejected — Array round-trips through JSON cleanly; the perf
  difference is negligible at the asset counts we work with.
- **Server-side tag validation** (lower-case only, no spaces,
  etc). Rejected — the user knows their own taxonomy. Free-form
  is fine; if hygiene becomes an issue we'll add a validator
  config.
- **In-place rename via gallery row double-click.** Considered.
  Rejected for MVP — discoverability is poor; preview modal
  is where users already go to interact with an asset.

## Settings registry

No new settings keys.

## Follow-ups

- **Tag autocomplete.** As the user types, suggest existing
  tags from other assets. Pairs with a future tag-index method
  on AssetManager.
- **Bulk metadata edit.** Multi-select in the gallery + apply
  the same tags to N assets. Useful when sorting a fresh batch.
- **Filter gallery by tag.** Today the asset_type dropdown is
  the only filter. Add a tag dropdown / search field once
  several assets carry tags.
- **Quality / rating field.** 1–5 stars or thumbs-up/down.
  Useful for "show me my best stuff" workflows.
- **Archived flag.** Boolean. Hides without deleting; pairs
  with the gallery filter follow-up.
- **Tag synonyms / taxonomy.** A user-managed mapping of
  "char_portrait" → ["character", "portrait"]. Out of scope
  for MVP.
- **Generation-history field.** When the user re-generates
  to fix the prompt, link the new asset to the old one
  via `parent_asset_id` so they can see the evolution.
  Schema already supports this.
