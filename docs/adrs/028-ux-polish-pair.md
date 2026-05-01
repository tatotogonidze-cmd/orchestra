# ADR 028: UX polish pair — reset-to-default + scene picker

- **Status:** Accepted
- **Date:** 2026-04-25

## Context

Phase 25 (ADR 025) shipped per-plugin param persistence. ADR 025
listed a small but obvious follow-up:

> **Reset-to-default per field.** A small × button next to each row
> that removes the persisted value, falling back to the schema
> default on the next render.

Phase 23 (ADR 023) shipped scene tester. ADR 023 listed a similar
follow-up:

> **Picker UI for "Add to existing scene".** OptionButton or
> PopupMenu with the scene list, plus "+ New scene…" at the bottom.
> asset_preview's button gets a small dropdown.

Phase 28 closes both. They're independently small, both
single-file UX wins, and both leverage existing infrastructure
(SettingsManager + SceneManager).

The decisions to make:

1. **Reset button placement + glyph.** Per-row trailing button?
   Inline with the control? What symbol?
2. **What does "schema default" mean post-override?** The schema's
   own value, or the one currently displayed (which may have been
   a saved value)?
3. **Picker mechanism.** Inline OptionButton, custom modal, or
   Godot's `PopupMenu`?
4. **What about the auto-generated scene name from Phase 23?**
   When the user picks "+ New scene", do we still auto-name?
5. **How do we test PopupMenu in headless?**

## Decision

1. **Per-row trailing "↺" button.** A small Button at the end of
   the HBox row, after the input control. Tooltip: "Reset to
   schema default". Skipped for the "(unsupported type)" stub
   rows — there's nothing to reset. Layout-neutral: row already
   had `[name_label, control]`; we append a third child.

2. **"Schema default" = the value the schema declared, BEFORE any
   saved override.** Phase 25's `set_schema` already mutates the
   `effective` spec to substitute saved values for defaults. We
   capture the ORIGINAL `spec.get("default")` before that
   substitution and store it in `_rows[field]["schema_default"]`.
   Reset reads from there. Without the explicit capture, "reset"
   would restore to "what was just shown", which would be a
   no-op.

3. **`PopupMenu` for the scene picker.** Inline OptionButton in
   `asset_preview.gd` would clutter the footer. A custom modal
   for one decision is overkill. PopupMenu is Godot-native, lazy
   to build, and behaves like users expect (click → list →
   click → done). main_shell owns the popup; asset_preview's
   button just emits the existing `add_to_scene_requested`
   signal — no new API surface on the preview.

4. **Auto-naming from Phase 23 preserved.** "+ New scene…" still
   triggers `_add_asset_to_scene_choice(asset_id, "")` which
   names the new scene from the asset's prompt. The picker is
   ADDITIVE — pick existing OR pick "+ New" + auto-name.

5. **Tests target the helper, not the popup interaction.** PopupMenu
   in headless can be created and inspected (item_count, item
   labels) but `id_pressed` can't be cleanly synthesized. We
   extracted `_add_asset_to_scene_choice(asset_id, scene_id)` —
   tests call this directly with empty (new) and non-empty
   (existing) scene_ids. A separate test verifies the popup
   gets built + populated on `_on_add_to_scene_requested`.

## Consequences

- **The param form gets a real "undo my changes" path.** Without
  reset, clearing a persisted override required either editing
  `user://settings.json` by hand or clicking through to the
  schema default value the user had to remember. Now it's one
  click.
- **Resetting a schema-default field is a no-op visually.** If the
  user resets a field whose persisted value happens to equal the
  schema default, the control's value doesn't change but the
  persisted entry is removed. Subsequent renders don't override
  via settings. Side effect: a user who wants to "force" the
  schema default to be persisted explicitly would have to set it
  AND not reset. Acceptable.
- **The scene picker preserves Phase 23's "auto-create with
  prompt-as-name" flow** as one of its two branches. No
  regression for users who want quick-add-to-new-scene.
- **PopupMenu lifetime.** Built lazily on first use, kept around
  for subsequent opens. Cleared + repopulated on each show so
  newly-created or deleted scenes appear / disappear correctly.
- **Add-to-existing skips the auto-name flow.** The user picked
  a real scene; it has its own name already. We just call
  `add_asset_to_scene` and surface the scene panel.
- **`scene_panel._selected_scene_id` is set before show_dialog**
  in both branches. The user lands on the relevant scene
  whether they picked existing or just-created.

## Alternatives considered

- **OptionButton in `asset_preview` footer.** Inline visual
  noise; the footer already has Close + Delete + Add to scene.
  PopupMenu is the cleaner spawning model.
- **Custom modal overlay for the picker.** Like the existing
  unlock_dialog / credential_editor pattern. Overkill for "pick
  one item out of N".
- **× button per row instead of ↺.** "×" reads as "delete this
  row", which is wrong — reset doesn't remove the field.
- **Reset button that toggles between saved + default.** Two-
  step UX (one click to default, another to restore the saved
  value). Adds state complexity for marginal benefit. Reset is
  one-way.
- **Reset that ALSO refreshes the row UI from the latest
  `get_param_schema()`.** Could pick up new schema defaults
  when the plugin updates. Today we cache the default at
  set_schema time; if the plugin reloads with different
  defaults, the user has to re-open the form. Acceptable; rare.
- **Synthesize PopupMenu.id_pressed in tests.** Possible via
  `popup.id_pressed.emit(id)` but that bypasses the actual click
  semantics and the GUI input pipeline. The helper-method route
  is more robust against Godot version drift.

## Follow-ups

- **Bulk reset for one plugin.** "Restore claude's defaults" —
  iterates `_rows` and runs `_on_reset_pressed(field)` for each.
  Trivial follow-up; needs a UI button somewhere (HUD? settings
  overlay?).
- **Bulk-clear all settings.** A "Reset all preferences" button
  in a future Settings overlay that calls `settings.clear()`.
- **Drag-from-asset-preview-to-scene-panel.** Power-user UX
  alternative to the picker. Requires Godot drag-and-drop
  integration; bigger lift.
- **Auto-add to MOST RECENTLY OPENED scene.** A single-click
  "add to last scene" affordance for users who batch-add many
  assets to one scene. Pairs with the picker (the picker
  remembers the last pick).
- **Highlight the row when reset has happened.** A brief flash
  / fade so the user can visually confirm the field returned
  to default. Cheap with a `Tween` on `modulate`.
- **Picker shows asset count.** Done — the menu items render
  `<name> (<N> assets)` so the user can pick the relevant
  bucket.
- **Picker remembers last selection.** Persist
  `scene.last_picked_id` in settings; pre-highlight on next
  open. Minor productivity boost.
