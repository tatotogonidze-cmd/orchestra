# ADR 012: Asset Preview — type-specific renderers in a modal overlay

- **Status:** Accepted
- **Date:** 2026-04-25

## Context

ADR 008 shipped the AssetManager: every successful generation gets
content-hashed, copied into a managed layout, and registered with
metadata (asset_type, format, plugin, prompt, path, size, cost,
created_at). ADR 009 added the `asset_gallery` panel — a sidebar list
with a type filter + a small "details" Label that prints metadata
when a row is selected.

The gallery showed *that* an asset existed but nothing of *what* it
was. A user couldn't:

- Read the text Claude returned without opening the file in an
  editor.
- See the image a future image plugin produced.
- Audition audio from ElevenLabs.
- Glance at metadata for a 3D asset (the metadata column in the
  sidebar is too narrow for full id / path / prompt strings).

For demo-readiness this was the next shoe to drop. Phase brief
attached two reference screenshots; the relevant one shows a large
"Asset Preview" pane with the renderer on the left, a metadata column
on the right, and Download / Open in Scene / Delete actions in the
footer.

The decisions to make:

1. **Sidebar split or modal?** Embed preview into `asset_gallery`'s
   panel, or surface a separate full-screen overlay?
2. **One renderer or per-type?** A generic "show file" component, or
   typed renderers (TextEdit / TextureRect / AudioStreamPlayer / 3D
   viewport)?
3. **What about 3D?** Real 3D preview needs a SubViewport, GLTF
   loader, and a camera rig — much more work than the other types.
4. **Action surface scope?** Delete is obvious; Download / Open in
   Scene need filesystem and import-pipeline integration. Ship
   them now, or later?
5. **How do tests verify the renderer without rendering?** Audio
   playback and image decoding aren't side-effect-free.

## Decision

1. **Modal overlay, same shape as the other dialogs.** Full-screen
   `Control` + dim layer + centered `PanelContainer`, ~720×480. Two
   reasons: (a) the asset_gallery sidebar is 280px wide — too cramped
   for a usable image preview or the metadata column; (b) consistency
   with `unlock_dialog`, `credential_editor`. One overlay pattern,
   one set of test idioms.

2. **Per-type renderers, dispatched by `asset_type`.** A `match`
   statement in `show_for_asset` picks one of:

   - `text`  → `TextEdit` (read-only) loaded from `local_path`.
   - `image` → `TextureRect` populated via `Image.load_from_file`
     and `ImageTexture.create_from_image`.
   - `audio` → `AudioStreamPlayer` + `AudioStreamMP3` + Play / Stop
     buttons. mp3-only for MVP because ElevenLabs is the only
     real audio plugin and it returns mp3.
   - `3d`    → static placeholder label that points at ADR 008.

   A generic "open the file in $OS_HANDLER" was tempting (one
   button per asset) but it punts the experience entirely outside
   the app — bad for in-app review flow, bad for headless tests.

3. **3D is a placeholder.** Real 3D preview needs (a) a `SubViewport`
   sized to the panel, (b) a `GLTFDocument` loader to turn `.glb`
   bytes into a scene, (c) an orbital camera and lights, (d) input
   handling for rotate / zoom. None of that is hard but together
   it's a bigger investment than the other three types combined.
   We document the deferral and show metadata only — the asset is
   already saved correctly on disk; the user can see it via the
   metadata's `local_path`.

4. **MVP actions: Close + Delete.** Download is redundant — assets
   are already on the user's disk; they just need the path, which
   the metadata column shows. "Open in Scene" requires the
   import-into-Godot pipeline, which is its own future ADR. Delete
   emits `delete_requested(asset_id)`; `main_shell` calls
   `AssetManager.delete_asset` which fires `asset_deleted`, and
   `asset_gallery` repaints itself off that signal.

5. **Tests probe the renderer state, not the pixels.** GUT runs
   headless; we can't actually paint a `TextureRect` or play audio.
   Instead the preview exposes:

   - `_content_holder` — its single child IS the renderer.
   - `_current_renderer_type: String` — one of
     `"text" | "image" | "audio" | "3d" | "error" | ""`.
   - `_audio_player: AudioStreamPlayer` — non-null in the audio
     branch so Stop can address it.

   Tests assert the renderer NODE TYPE (TextEdit, TextureRect,
   AudioStreamPlayer presence) and `_current_renderer_type`. The
   actual byte-decoding is left as integration smoke. For audio,
   we tolerate fake bytes because `AudioStreamMP3.data = ...`
   doesn't validate at assignment time — invalid data only fails
   at `play()`, which tests never call.

6. **Renderers are torn down with `free()`, not `queue_free()`.**
   Same lesson as ADR 011: rebuilding the content on a fresh
   `show_for_asset` call without immediate eviction leaves zombie
   nodes in the tree until the next idle frame, which GUT's orphan
   tracker flags. We're not inside a signal callback for the
   content children, so synchronous `free()` is safe.

## Consequences

- **The gallery is now a launcher, not a viewer.** The inline
  `_details` Label stays as a quick-glance summary; the heavy
  lifting moves into the preview overlay.
- **Asset deletion has a real surface in the UI.** Until now the
  only way to delete an ingested asset was to call
  `AssetManager.delete_asset` from a tools/integration script.
- **Audio playback works in dev builds.** Headless test runs
  exercise the AudioStreamPlayer creation path but not actual
  sound output. The first time we see audio actually play is
  when a developer runs the editor with `--audio-driver Default`
  or higher.
- **3D preview is documented as deferred.** Anyone picking up the
  scene-import phase can come straight to the placeholder
  renderer and replace it with the real implementation; the
  metadata column already shows everything they need.
- **One more overlay.** `main_shell` now hosts four overlays
  (unlock_dialog, credential_editor, asset_preview) plus the
  four panels. We're still well below the point where this
  starts being unwieldy, and each overlay is testable in
  isolation.

## Alternatives considered

- **Inline preview inside `asset_gallery`.** Rejected. The right
  sidebar is 280px wide; a useful image or text view needs more
  room than that.
- **Generic "open file in OS handler" button per type.** Rejected
  for the in-app review flow — and untestable in headless. Worth
  adding as a SECONDARY action later (an "Open in OS" button
  next to Close), since `OS.shell_open(local_path)` is one line.
- **Build the 3D preview now.** Real cost is the import pipeline,
  not the GLTF loader itself. We'd ship a half-feature that
  loaded the bytes but couldn't navigate the camera. Defer.
- **Synthesize input events to test button presses.** Same
  call as ADR 010 / 011 — the codebase pattern is internal
  handlers as test seams. Following it.
- **Keep `_details` in the gallery and skip the overlay.**
  Rejected — the sidebar is too narrow for prompt text or full
  paths, and there's nothing for image/audio.

## Follow-ups

- **3D viewport.** SubViewport + GLTFDocument + orbital camera +
  basic lights. Replace `_render_3d_placeholder` and update this
  ADR. Probably its own phase.
- **Image zoom / pan.** Right now `STRETCH_KEEP_ASPECT_CENTERED`
  fits the image to the panel; large images get downscaled with
  no recourse. A scrollable / zoomable image view is a small but
  worthwhile polish.
- **Audio waveform / position bar.** The reference image showed a
  full timeline. We have an `AudioStreamPlayer` already; the
  scrubber needs `_process` polling on `get_playback_position()`
  and a draw routine. Cheap once we want it.
- **"Open in OS handler" button.** `OS.shell_open(local_path)` for
  text/image/audio/3d. Punted because it complicates testing —
  but a useful escape hatch.
- **"Open in Scene".** Once the scene-import layer lands, this
  becomes the bridge between "I generated a thing" and "the
  thing is now in my game". Big feature, separate phase.
- **Tags.** The reference showed "sci-fi, alien, city" tags on
  the asset. Tags need a (a) UI for editing them, (b) a place
  in `AssetManager` metadata, (c) filter integration in
  `asset_gallery`. Add when we want them; the metadata schema
  has room.
- **Multi-select / batch delete.** Right now Delete is per-asset.
  A `Ctrl+click` multi-select on the gallery + a "Delete selected"
  button is a normal next ergonomic step.
