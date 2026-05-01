# ADR 030: Word-level diff stats + auto-frame model AABB

- **Status:** Accepted
- **Date:** 2026-04-25

## Context

Two follow-ups from the diff + 3D viewport phases:

1. **ADR 020** shipped LCS line-level diff highlighting. Listed:

   > Word-level diff for `description` fields. In a future pass,
   > if a long description text changed, intra-line diff would
   > help spot the actual edit.

2. **ADR 021** shipped the orbital-camera 3D viewport. Listed:

   > Auto-frame the loaded model. Compute its AABB and choose
   > `_3d_distance` to fit. Today the camera always sits at
   > distance 5 — fine for normal-sized meshes, too close or
   > too far for outliers.

Phase 30 closes both. They're independently small, both pure-
function helpers (testable in isolation), and both ship
visible-quality wins.

The decisions to make:

1. **Word-diff scope.** Inline highlighting (red/green per word
   inside lines), summary-level stat ("words: -3 +5"), or both?
2. **Word-diff token granularity.** Whitespace? Punctuation
   boundaries? CJK character-level?
3. **Auto-frame AABB walk.** All MeshInstance3Ds, or only the
   "main" one? Local AABB or world transform?
4. **Distance math.** Bounding-sphere radius / FOV trig, or
   simpler heuristic?
5. **Headless test strategy for AABB.**

## Decision

1. **Summary-level stat for now, NOT inline highlighting.**
   Reasons:
   - The diff preview already uses `TextEdit.set_line_background_color`
     for line highlights. Per-word inline highlights would
     require either switching to `RichTextLabel` (loses TextEdit
     scroll/select), or rendering a third widget alongside the
     existing two.
   - The summary's word-diff stat ("words: -3 +5") tells the
     user how much PROSE changed even when the structural
     summary says "no entity-count changes". That's the
     primary signal.
   - Inline highlights remain a documented follow-up.

2. **Whitespace-token granularity for word diff.** Splits on
   any whitespace run (spaces, tabs, newlines). No punctuation
   handling — "fox," and "fox." count as different tokens.
   Acceptable for the heuristic role: the goal is "did the
   prose change a lot?", not "exactly which words". CJK
   handling is documented as a follow-up.

3. **All MeshInstance3Ds, world-space AABBs, merged.**
   `_compute_aabb_for_node(root)` recursively walks the loaded
   scene, finds every `MeshInstance3D`, transforms its local
   `mesh.get_aabb()` into world space via
   `global_transform`, and merges them. This handles
   multi-mesh GLTFs (typical for characters, vehicles, etc)
   without singling out any "main" mesh. Empty subtrees
   (no meshes) return a zero-size AABB, which the framing
   helper treats as a degenerate case (keeps default
   distance).

4. **Bounding-sphere + camera-FOV math.**
   `radius = aabb.size.length() / 2`,
   `distance = radius / sin(fov_rad / 2)`,
   then ×1.5 for visual padding (the model shouldn't be
   pressed against the viewport edges).
   Why bounding-sphere over per-axis fitting:
   - Orbital camera circles the target; sphere fitting is
     rotation-invariant.
   - Per-axis fitting would re-frame on every yaw/pitch
     change.

5. **Tests construct synthetic Node3D trees.** No real GLTF
   fixtures needed: build `MeshInstance3D`s with `BoxMesh`
   at known positions, walk them with `_compute_aabb_for_node`,
   assert merged dimensions. For framing, drive
   `_frame_camera_to_aabb` with a hand-crafted AABB and check
   `_3d_target` + `_3d_distance` math.

## Consequences

- **Small models look big enough to inspect; big models fit.**
  A 0.1-unit Tripo mesh no longer renders as a tiny dot 5
  units away; a 50-unit megastructure no longer requires
  manually scrolling out 90+ ticks.
- **Orbital input still works the same.** Drag still rotates
  yaw/pitch; scroll still adjusts distance — but starting
  from a sensible default per model.
- **Word-diff is a dump-the-stat-in-the-summary win.** No
  rendering complexity, no widget changes, no contention
  with the existing line-level highlights. Users who want
  precise per-word visibility scroll the existing TextEdits.
- **MeshInstance3D coverage is the right abstraction.** GLTF
  scenes from Tripo / Meshy / etc. invariably ship as
  Node3D + MultiMeshInstance3D / MeshInstance3D children.
  We'll need to extend this to MultiMeshInstance3D in a
  follow-up if we adopt providers that emit them.
- **Tokenization is permissive.** "fox," and "fox" being
  different tokens means a comma added/removed counts as
  one word change. Accurate for the "rough edit volume"
  use case; would be wrong for "spot the exact word swaps"
  (the inline-highlight follow-up).
- **Padding factor is hardcoded.** 1.5× isn't user-configurable
  yet. If we add a "fit tightly" / "loose framing" toggle
  later, it goes in SettingsManager.
- **Re-frame on user input is NOT done.** The auto-frame
  applies once per render. If the user scrolls in/out, we
  preserve their preference for the rest of that view.
  Re-show resets back to auto-frame.

## Alternatives considered

- **Inline word-level highlighting via RichTextLabel.**
  Better visual fidelity but two-widget juggle (or full
  switch from TextEdit). Punted.
- **Punctuation-aware tokenization.** "fox," / "fox" as the
  same token requires a strip step. Cheap, but the heuristic
  goal doesn't need it.
- **CJK character-level token splitting.** A Chinese / Japanese
  / Korean GDD's "word" diff would be character-level
  effectively. Documented as a follow-up; the current target
  audience writes in Latin-script languages.
- **Single-mesh AABB selection.** Pick the first / largest
  MeshInstance3D and frame to that. Loses subordinate parts
  (a character's weapon, a vehicle's wheels). Merging is
  correct.
- **Per-axis fit (separate horizontal / vertical FOV).**
  Camera3D in Godot uses vertical FOV; horizontal is derived
  from the viewport aspect. Per-axis fitting would need
  aspect-aware math. Bounding-sphere works regardless of
  aspect.
- **Auto-frame after every camera input.** Surprising —
  scroll-out gets snapped back. The user's input wins.
- **Re-frame on subviewport resize.** Defensible (the model
  should fit even if the panel is resized) but the asset
  preview's container is fixed-size today.

## Follow-ups

- **Inline word highlights.** RichTextLabel rendering or a
  `TextEdit.add_theme_color_override` per region. Would
  require a richer diff data structure (per-line word
  positions, not just counts).
- **Punctuation-aware tokenization.** Split on a regex like
  `\W+` so "fox," and "fox" merge. Cheap but adds a regex
  dependency.
- **MultiMeshInstance3D support.** Extend `_walk_meshes` to
  handle multimesh AABBs. Requires per-instance transforms.
- **CSGShape3D / Sprite3D / Particle systems.** Future model
  inputs may include these node types. Generalize the AABB
  walk to anything with a `get_aabb()`-like accessor.
- **Configurable padding.** A "frame padding" SettingsManager
  key under `viewport.frame_padding`.
- **Re-frame button in the UI.** A "↺ frame" button next to
  the asset preview's footer that resets to auto-frame
  after manual adjustments.
- **Lighting auto-frame.** When a new model loads, also
  position the key light relative to its AABB so the
  highlights/shadows look reasonable. Today the light is
  fixed at 45°/30° from world origin.
