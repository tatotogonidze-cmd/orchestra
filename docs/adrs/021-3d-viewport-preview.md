# ADR 021: 3D viewport preview — SubViewport + GLTFDocument + orbital camera

- **Status:** Accepted
- **Date:** 2026-04-25

## Context

ADR 012 shipped `asset_preview` with type-specific renderers for text,
image, audio, and a placeholder Label for 3D. The placeholder
explicitly punted to a follow-up:

> 3D placeholder. Real 3D preview needs (a) a SubViewport sized to
> the panel, (b) a GLTFDocument loader to turn .glb bytes into a
> scene, (c) an orbital camera and lights, (d) input handling for
> rotate / zoom. None of that is hard but together it's a bigger
> investment than the other three types combined.

Phase 21 redeems that follow-up. With Tripo dispatching real
text-to-3D today (and ElevenLabs audio + Claude text already
rendering), the 3D preview was the last asset type without an
in-app viewer.

The decisions to make:

1. **Viewport class.** `Viewport`, `SubViewport`, or
   `SubViewportContainer + SubViewport`?
2. **Loader.** `GLTFDocument.append_from_file` vs `ResourceLoader.load`?
3. **Camera controls.** Custom orbital, free-fly, fixed?
4. **Lighting.** Hand-rolled rig, environment map, just ambient?
5. **Headless test scope.** What can we actually verify without a
   real renderer running?

## Decision

1. **`SubViewportContainer + SubViewport`.** A bare `SubViewport` is
   a Node3D-tree host but doesn't render to a Control hierarchy on
   its own — the Container is the bridge that displays its
   contents inside our `_content_holder`. We set
   `own_world_3d = true` so this viewport's scene doesn't leak into
   any other 3D world we might add later (scene tester, etc).

2. **`GLTFDocument.append_from_file`.** `ResourceLoader.load` works
   for `res://` paths but bristles at `user://` paths in some
   build configs, and it caches resources globally — the wrong
   shape for previewing per-asset content. `GLTFDocument` is
   purpose-built: parse → `GLTFState` → `generate_scene` →
   add as a child of the SubViewport. We pre-check `FileAccess.file_exists`
   before invoking the loader so a missing file produces a
   friendly status message instead of an engine push_error.

3. **Custom orbital camera.** Three floats —
   `_3d_yaw`, `_3d_pitch`, `_3d_distance` — plus a `_3d_target` Vec3.
   Camera position recomputed from spherical coordinates whenever
   any of those change. Mouse drag (left button) adjusts yaw/pitch;
   mouse wheel adjusts distance. Pitch clamps to ±85° to avoid
   the look_at(UP) singularity at the poles.

4. **Ambient + a single directional key light.** A
   `WorldEnvironment` with `AMBIENT_SOURCE_COLOR` (a soft cool grey)
   plus one `DirectionalLight3D` rotated 45° down and 30° aside.
   Enough to make a vanilla glTF readable without authoring a real
   lighting rig. A future scene-tester might want HDRI maps; the
   current setup is the bare minimum that "looks right".

5. **Tests verify Node-tree structure, not pixels.** Headless GUT
   can't rasterise. We assert:
   - `_content_holder` has one child, a `SubViewportContainer`.
   - The SubViewport's children include `Camera3D`,
     `DirectionalLight3D`, `WorldEnvironment`.
   - `_3d_subviewport` and `_3d_camera` member refs are populated
     during a 3D render and nulled on renderer swap.
   - Synthetic `InputEventMouseMotion` with the LMB held adjusts
     yaw/pitch; without the LMB it doesn't.
   - Wheel events adjust distance; pitch clamps under heavy drag.
   - Initial camera position matches the orbital math.

   We deliberately don't fabricate a real `.glb` fixture for tests.
   The renderer always builds the scaffolding, so a missing file
   path drops a small overlay Label inside the container — visible
   to the user, and we test the structure by counting children.

## Consequences

- **3D assets are now first-class previewable.** A Tripo-generated
  `.glb` lands in the Asset Gallery, click → orbital viewer.
  Round-trip from prompt to looked-at-it is now in-app.
- **The SubViewport is owned-world.** Future 3D systems (scene
  tester, importer) get their own worlds; nothing collides.
- **Mouse handling is panel-local.** The `gui_input` signal on the
  `SubViewportContainer` is the only bridge to camera state. No
  `_unhandled_input` global listeners, so the 3D view never
  intercepts events that should reach overlays above it.
- **Failure modes are visible.** Missing file or GLTFDocument
  rejection produces a small overlay Label in the viewport. The
  empty-but-lit viewport behind the label still works — useful
  affordance for any future "Reload" button.
- **`_clear_renderer` now nulls 3D refs.** Switching renderer type
  swaps content_holder children; the `_3d_subviewport` and
  `_3d_camera` member references are cleared so they don't dangle
  on freed nodes.
- **No animation playback yet.** Static scene only. Loaded glTFs
  with embedded animations will display the rest pose. Documented
  as a follow-up.

## Alternatives considered

- **Bare `Viewport` instead of `SubViewportContainer`-wrapped `SubViewport`.**
  Rejected — `Viewport` is a window-level concept; we want a
  Control-embedded one.
- **`ResourceLoader.load(path) as PackedScene`.** Works for some
  paths but fragile across `user://` and `res://` and caches
  resources globally. `GLTFDocument` is the explicit per-load API.
- **Pre-imported `.tscn` per asset.** Convert the `.glb` once,
  cache the `.tscn`. Defers to a future "scene importer" phase
  that legitimately needs the imported form for the editor to use.
- **`Viewport.world_3d` shared with the rest of the app.** Would
  let us avoid `own_world_3d=true`, but means lights and any
  future spatial state spill across viewports. Bad isolation.
- **Free-fly WASD camera.** Closer to dev-tool conventions but
  needs keyboard focus and clashes with global Esc-to-close. The
  orbital camera is the right pattern for "look at this thing".
- **No camera controls at all (fixed angle).** Considered for
  scope. Rejected because Tripo meshes are arbitrary orientations
  and the user almost always needs to rotate to verify the model
  is what they wanted.
- **HDRI environment map.** Better looks. Pulls in a sky texture
  asset and `Sky` resource setup. Skipped for now; the current
  ambient + directional is good enough.
- **Fabricate a minimal `.glb` for tests.** A 60-byte
  empty-scene glTF is doable but brittle to maintain across
  GLTFDocument behaviour changes. The structure-only tests do
  the work without that liability.

## Follow-ups

- **Auto-frame the loaded model.** Compute its AABB and choose
  `_3d_distance` to fit. Today the camera always sits at distance
  5 — fine for normal-sized meshes, too close or too far for
  outliers.
- **Animation playback.** GLTF can carry skeletal / morph
  animations; expose play/pause + a timeline scrubber.
- **Lighting controls.** A small inline "lighting" widget for
  rotating the key light — useful when reviewing a model that
  hides shape under default lighting.
- **HDRI / environment map preset.** Pre-bundled studio HDRI for
  realistic shading.
- **Wireframe + bounding box debug overlay.** Toggleable. Helps
  spot scale issues at a glance.
- **"Open in OS" button.** `OS.shell_open(local_path)` to launch
  Blender / Windows 3D Viewer / etc. Pairs with the same
  follow-up across all asset types.
- **GPU-detect / fallback.** Some users run with `--rendering-driver
  opengl3` where shader features can vary. Test on the matrix once
  we have one.
- **Async GLTF load.** `append_from_file` is synchronous; a big
  mesh can stall the UI for a few hundred ms. Move to a worker
  thread + progress indicator if it becomes an issue.
- **Re-target the orbital camera.** Click on the model to set
  `_3d_target` to the click point. The math is in place; needs a
  raycast + click handler.
