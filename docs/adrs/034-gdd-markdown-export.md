# ADR 034: GDD Markdown export

- **Status:** Accepted
- **Date:** 2026-05-01

## Context

After Phases 16 → 32, a user can:

- Load and view a GDD (16).
- Edit it via natural-language chat (17, 31).
- Edit it via a typed form (18, 32).
- See diffs at line + word granularity (20, 30).
- Auto-fix dangling cross-references (29).

What they CAN'T do is *use* the result. The viewer shows JSON.
The form shows fields. The diff shows changes. None of those are
shareable artifacts. A user who wants to send the GDD to a
collaborator (or paste it into a doc, or print it) is stuck
copying JSON.

The natural close-out for the GDD story is a **Markdown export**:
turn the structured document into a presentable artifact that
renders well in any Markdown viewer (GitHub, VS Code, Obsidian,
Notion, etc.).

The decisions to make:

1. **Hard-coded section template vs schema-driven rendering?**
2. **Should export validate first, or render best-effort?**
3. **Per-entity field set: same as form-edit (ADR 032), or
   different?**
4. **Where does the file go — fixed path, sibling of JSON,
   user picks each time?**
5. **Pure converter vs convert+save?**
6. **Section ordering?**

## Decision

1. **Hard-coded sections** in `gdd_manager.gd` (function
   `export_to_markdown`). One private helper per entity type
   (`_md_mechanics_section`, `_md_assets_section`, ...) — same
   shape as ADR 032's spec table, intentionally:
   - Schema-driven rendering would either (a) emit every field
     including timestamps, or (b) need a curation table — at
     which point we're back to a hard-coded list, just expressed
     differently.
   - The output is presentation, not interchange. We want
     editorial control over which fields surface.

2. **Best-effort, no validation gate.** `export_to_markdown` and
   `save_markdown` both run regardless of whether the GDD passes
   `validate()`. Rationale:
   - A user with cross-ref issues who wants a snapshot to share
     with a collaborator (so they can help fix it) shouldn't be
     blocked.
   - The Auto-fix button (ADR 029) is the right place to clean
     up references; export is the wrong moment to enforce it.
   - Best-effort = safe: each helper guards on `is Dictionary` /
     `is Array` and skips records it can't render.

3. **Same primary fields as ADR 032 form-edit, plus the
   adjacent context-fields.** What the user types in the form
   is what shows up in the export, with a few additions:
   - **Tasks**: status, priority (italic meta-line above
     description), dependencies + blocked_by (bullets).
   - **Mechanics**: dependencies (bullet).
   - **Scenes**: related_asset_ids (bullet).
   - **Characters**: role, asset_id (bullets).
   - **Dialogues**: character_id, node count.
   - **Assets**: type (in the heading), path, status.
   These are the next-most-useful surface facts beyond the
   primary fields. Un-rendered fields (timestamps, stats dict,
   entry_points array, dialogue node bodies, generated_by)
   stay in the JSON and round-trip unchanged.

4. **Default path = sibling of the loaded JSON, persisted via
   settings.** Resolution order:
   1. `gdd.last_export_path` from settings_manager (what they
      picked last time).
   2. Sibling of `_current_gdd_path` with `.md` extension
      (`gdd.json` → `gdd.md`).
   3. `user://gdd.md` final fallback.
   Persisting `gdd.last_export_path` means the second click
   writes to the same file, with the same name. If the user
   wants a different path, they edit it via the Settings panel
   (Phase 33 already lists `gdd.last_export_path` since this
   ADR registered the key).

5. **Pure converter + save wrapper.** Two methods:
   - `export_to_markdown(gdd) -> String` — pure, no I/O. Used
     by tests, by future copy-to-clipboard, by future export-to
     -other-format consumers.
   - `save_markdown(gdd, path) -> {success, error?, path?, bytes?}`
     — runs the converter, makes the directory, writes the
     file. UI calls this.
   Same shape as `load_gdd` / `save_gdd` from ADR 016 — Result
   dicts, not exceptions.

6. **Section ordering: schema declaration order**, NOT
   ADR 032's form ordering, NOT alphabetical, NOT
   importance-weighted. Specifically: mechanics → characters →
   scenes → tasks → dialogues → assets. Rationale:
   - **Mechanics first**: they're the core game-design
     primitives. Reader needs them to interpret everything else.
   - **Characters before scenes**: scenes can reference
     characters (via dialogues / assets); reader sees the cast
     before the stages.
   - **Scenes before tasks**: tasks often relate to building
     scenes; readers benefit from knowing what scenes exist.
   - **Tasks before dialogues**: tasks are project-level;
     dialogues are content. Tasks set context.
   - **Dialogues before assets**: dialogues reference
     characters; assets are the most-reference-target field.
     End with the catalog readers can scan.
   - **Assets last**: long, tabular, low-narrative; doesn't
     gain from being above other sections.
   - Empty sections (zero entries) are skipped entirely — no
     `## Tasks (0)` filler.

## Settings registry

Adds one key to `settings_panel.gd`'s registry (Phase 33):

| Key                          | Type   | Default | Description                                                                 |
|------------------------------|--------|---------|-----------------------------------------------------------------------------|
| `gdd.last_export_path`       | string | `""`    | Default destination for the GDD viewer's Export → Markdown button.          |

Cleared via the Settings panel's per-row reset; the next export
falls back to the JSON-sibling default.

## Output shape

```markdown
# <metadata.title or "Game Design Document">

_Version: <metadata.document_version>_
_Last updated: <metadata.updated_at>_

<summary, if present>

---

## Mechanics (N)

### mech_id

<description>

- **Depends on:** mech_a, mech_b

---

## Characters (N)

### char_id — <name>

- **Role:** <role>
- **Asset:** <asset_id>

---

(...scenes, tasks, dialogues, assets follow same pattern...)
```

## Consequences

- **Closes the GDD authoring loop.** A user who's spent time in
  chat-edit + form-edit can now export a presentable artifact.
- **Pure converter is reusable.** Future work (copy-to-clipboard,
  export-to-PDF via pandoc, embed-in-presentation) can layer on
  top without touching the I/O wrapper.
- **No validation gate keeps flow open.** Even a draft GDD with
  cross-ref issues exports cleanly — the user gets a snapshot
  they can iterate on.
- **Section order is intentional.** Reorganising the schema
  doesn't reorganise the export. If the schema later adds a new
  entity type (e.g. quests, items), the export needs an explicit
  new helper + section-list entry — failing-loud is preferable
  to silently-omitting.
- **Persistence integrates with the Settings panel naturally.**
  `gdd.last_export_path` is just another row alongside
  `gdd.last_path` — no special UI handling.
- **`gdd_manager.gd` grows ~150 lines.** Most of it is per-type
  helpers; logic per type is small. Worth the surface area for
  the user-visible feature.

## Alternatives considered

- **Schema-driven rendering.** Walk `properties` recursively,
  emit `**field**: value` for each leaf. Rejected: produces
  noise (timestamps, internal version markers), and the
  rendering of references-as-bulleted-lists is editorial.
- **Validation-gated export.** Refuse to export an invalid
  GDD. Rejected: workflow-blocking. Auto-fix is the right tool
  for sanitisation; export is downstream of that decision.
- **Save-as dialog every time.** Native FileDialog popup for
  the path. Rejected for MVP: Godot's FileDialog has its own
  modal-window quirks, and the persisted-path-with-edit-via-
  settings approach is consistent with `gdd.last_path` (ADR
  024). A real Save-as can come later if users ask.
- **Multiple output formats (PDF / HTML / Notion).** Each
  format would deserve its own ADR; Markdown first because
  every other format can be derived from it (pandoc).
- **Live preview in the panel.** Render the markdown in a
  RichTextLabel inside `gdd_panel`. Considered. Rejected:
  RichTextLabel doesn't render Markdown natively (it speaks
  BBCode), and full-fidelity markdown rendering is its own
  rabbit hole. The user can see the file in any markdown
  viewer.
- **Embed images inline.** For asset paths that resolve to
  image files, generate `![](path)` references. Rejected for
  MVP: requires path-resolution logic + relative-path
  computation. Future work — Markdown export → bundle .md +
  asset folder → distributable .zip.

## Follow-ups

- **Copy to clipboard.** A `Copy Markdown` button next to
  Export. `DisplayServer.clipboard_set(...)`. Trivial when
  the converter is a pure function.
- **Embed images.** Resolve `assets[].path` to a relative
  reference and emit `![](path)` so the markdown renders
  with thumbnails.
- **Schema-aware additions.** When a new entity type joins
  the schema, fail-fast with a console warning if the
  exporter has no helper. Today an unrecognised entity type
  is silently absent.
- **Export to PDF / HTML.** Pipe the markdown through a
  pandoc-style converter (in-Godot or shell-out). Likely
  follows up after Copy-to-clipboard.
- **Per-entity-type filter.** "Export only mechanics" /
  "Export tasks for this milestone." Pairs with a section
  picker UI in the gdd_panel.
- **Diff-aware export.** "Export changes since v3" — list
  only entities added/modified since a snapshot. Pairs with
  ADR 020's diff infrastructure.
- **Custom heading-level.** Top-level heading is `#`; some
  users want to embed the GDD inside a larger doc and need
  `##` as the topmost. A heading-offset param.
