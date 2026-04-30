# ADR 023: Scene tester / preview pipeline — metadata-only scenes

- **Status:** Accepted
- **Date:** 2026-04-25

## Context

Phase 21 (ADR 021) shipped the per-asset 3D preview: a SubViewport
that renders one `.glb` at a time when the user opens an asset from
the gallery. That covers "look at this thing I just generated", but
not "compose a scene out of multiple things".

A scene tester closes that gap. The user needs to:

- Bundle multiple assets into a named "scene" (a dragon mesh + a
  ground plane mesh + an ambient sound + a dialogue file).
- Preview the scene as a unit, not one asset at a time.
- Add / remove assets after the fact.
- Persist scenes across sessions.

Phase 23 ships an MVP of this. Big-feature in scope (more code than
a polish phase) but tightly scoped — the goal is the round-trip,
not a full Godot-native scene editor.

The decisions to make:

1. **What IS a scene?** A real Godot `.tscn` file (PackedScene
   serialized to disk), or just metadata (a name + an asset_id list)?
2. **Where does scene state live?** Its own manager (`SceneManager`)
   or piggyback on `AssetManager`?
3. **What does the preview render?** All asset types, or 3D only
   for MVP?
4. **How is "Add to Scene" surfaced?** From asset_preview, from
   asset_gallery, both, neither?
5. **What's the layout of the scene panel?** Single-pane modal,
   side-by-side, full-screen?

## Decision

1. **Metadata-only scenes.** A scene is just:

   ```gdscript
   {
     "id":         "scene_<unix_ms>_<rand>",
     "name":       String,
     "asset_ids":  Array[String],
     "created_at": int,
     "updated_at": int,
   }
   ```

   Persisted to `user://scenes/index.json`, mirrors `AssetManager`'s
   layout. We deliberately do NOT serialize Godot `PackedScene`
   files. That would mean:
   - Loading every asset at save time (GLTFDocument /
     AudioStreamMP3 / etc.) into Godot resources.
   - Resolving asset paths through Godot's import pipeline (which
     is what `.import` files manage; resources keyed off them).
   - Surviving Godot version changes in the serialization format.

   Genuine work; punted as a follow-up. For MVP, on-the-fly
   re-rendering during preview is enough — and it has a real
   benefit: scenes are always in sync with current asset state
   (no broken references baked into a `.tscn`).

2. **Standalone `SceneManager` as a child of Orchestrator.** Same
   shape as `AssetManager` / `CostTracker` / `GDDManager`:
   `configure(root)` for tests, persistent index, EventBus events
   (`scene_created`, `scene_updated`, `scene_deleted`). Scenes are
   conceptually adjacent to assets but functionally distinct
   (a scene has 0 or more assets; multiple scenes can reference
   the same asset). Separate manager keeps each concern's API
   clean.

3. **3D-only preview rendering for MVP.** The `scene_panel`'s
   SubViewport only knows how to instantiate 3D assets via
   `GLTFDocument.append_from_file`. Other types (text, audio,
   image) appear in the side asset list with their type tag, but
   don't get a spatial representation. Documented as a follow-up
   — adding audio markers, image planes, etc, is straightforward
   but not the load-bearing case for this phase.

4. **"Add to Scene" lives in `asset_preview`.** Footer button next
   to Close / Delete. Click → emits `add_to_scene_requested(asset_id)`.
   `main_shell` catches it and:
   - Reads the asset's `prompt` field, truncates to 40 chars.
   - Creates a fresh scene with that name, seeded with this
     asset_id.
   - Pre-selects the new scene in `scene_panel`.
   - Surfaces `scene_panel`.

   Simplest possible flow. The user can rename later
   (`SceneManager.rename_scene` exists); they can add to existing
   scenes via a future picker (documented as follow-up).

5. **Two-column scene panel.** Left: scene list + new-scene input.
   Right: preview SubViewport + asset list + delete button. Same
   modal pattern as the other overlays — full-screen Control +
   dim layer + centered PanelContainer. Esc-to-close, same as
   ADR 014.

6. **Tests cover the manager + the panel structure separately.**
   `test_scene_manager.gd`: pure metadata round-trips, asset
   existence validation, persistence, signals. `test_scene_panel.gd`:
   build, list rendering, selection wiring, delete flow, missing-
   asset display. The 3D-rendering path inside the panel is NOT
   exercised end-to-end in tests (would need a real `.glb`
   fixture); the SubViewport scaffolding pattern is already
   covered by `test_asset_preview` (Phase 21).

## Consequences

- **Round-trip from prompt to scene preview works in-app.** A user
  generates a 3D mesh via Tripo, opens the preview, clicks "Add
  to Scene", lands in the scene panel with the scene already
  selected. To add more, generate more, click "Add to Scene"
  again — same flow.
- **Asset deletion leaves dangling refs.** The scene panel's
  asset list flags missing assets as `[missing] <asset_id>`,
  but doesn't auto-clean. The user's mental model: "the scene
  remembered I had this thing; I deleted the thing; I can
  remove the row". Auto-cascade deletion is a follow-up.
- **No `.tscn` export yet.** Sharing a scene with another tool
  (or another orchestrator install) means re-creating it from
  the constituent assets. The metadata index is portable JSON;
  it just isn't directly loadable as a Godot scene.
- **One more overlay + one more cost-footer button.** Footer now
  hosts FOUR action buttons: GDD, Scenes, Budget HUD, Lock now.
  We're at the threshold where a header bar starts to make more
  sense; documented as the next layout-level call to make.
- **Scene preview re-loads every selection.** No caching of
  GLTFDocument scenes. Fine for MVP; if users complain about
  click latency on big scenes, we'll cache.
- **Six managers under Orchestrator now.** `plugin_manager`,
  `credential_store`, `asset_manager`, `cost_tracker`,
  `gdd_manager`, `scene_manager`. Each is independent and small;
  the parent stays a coordinator, not a god-object.

## Alternatives considered

- **Real `.tscn` serialization.** Discussed above. The right
  long-term move; deferred because the MVP works without it and
  the work to do it well (resource pathing, import pipeline,
  cross-platform path normalisation) is its own phase.
- **Embed scene metadata in `AssetManager`.** Asset records gain
  an optional `scene_ids` field, "scene" becomes a virtual
  filter. Rejected — conflates two concerns and makes scene
  persistence a second-class citizen.
- **Render every asset type in the scene preview.** Audio:
  position marker + AudioStreamPlayer3D. Image: textured quad.
  Text: floating label. Doable but each is its own widget; we
  punt to keep the phase scoped to "the round-trip works".
- **Picker UI for "Add to scene".** Drop-down of existing scenes
  + "+ New scene". More user-friendly, more code. The current
  flow ("clicking Add to Scene always creates a new scene") is
  the simplest useful path; a follow-up adds the picker.
- **Auto-cascade asset deletion → remove from scenes.**
  Considered. Rejected because we'd need a reverse index
  (asset_id → scene_ids) maintained alongside the forward one.
  The "[missing]" label is good enough for MVP and explicit
  removal is a one-double-click operation.
- **Scene preview as a panel rather than a modal.** Considered.
  Rejected because the panel HBox is already busy and a fifth
  panel would crowd everything. Modal is the right call until
  we redesign the layout.

## Follow-ups

- **Real `.tscn` export.** The complete serialization path so
  scenes are portable. Pairs with importing scenes from disk.
- **Picker UI for "Add to existing scene".** OptionButton or
  PopupMenu with the scene list, plus "+ New scene…" at the
  bottom. asset_preview's button gets a small dropdown.
- **Audio / image / text rendering in scene preview.**
  AudioStreamPlayer3D markers, textured quads, floating text
  labels. Each is small but they accumulate.
- **Spatial layout / transforms.** Currently every asset stacks
  at the origin. A simple "drag to position in the SubViewport"
  affordance unlocks meaningful composition.
- **Orbital camera in scene preview.** Phase 21's per-asset
  preview has it; the scene preview is fixed angle for MVP.
  Lift the input handler unchanged.
- **Auto-cascade on asset delete.** Maintain a reverse index
  `asset_id → scene_ids`; on `asset_deleted`, walk the scenes
  and remove. Pairs with a "Cleanup dangling refs" button.
- **Rename UI.** `SceneManager.rename_scene` exists; the panel
  needs an inline edit affordance. Probably double-click on the
  scene list row.
- **Scene metadata in `cost_tracker`.** A scene's total cost
  (sum of its assets' `cost` fields) on hover would be a nice
  cross-reference once we have it.
- **Drag-from-gallery to scene-panel.** Skipping the "add to
  scene" button entirely and dragging would be the "real" UX.
  Pairs with full Godot drag-and-drop integration.
- **Header bar refactor.** Four cost-footer buttons is the
  threshold. A real header with menus / tabs starts being worth
  the layout cost.
