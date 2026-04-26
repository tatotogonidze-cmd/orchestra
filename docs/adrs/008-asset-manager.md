# ADR 008: Asset Manager — content-hashed ingest of plugin outputs

- **Status:** Accepted
- **Date:** 2026-04-24

## Context

With Orchestrator + plugins in place, successful generations produced `result`
dictionaries that nobody owned. A Claude call returned text in memory, a Tripo
call returned a remote CDN URL, an ElevenLabs call wrote a `user://` `.mp3`
under its own path. Three different shapes, three different lifecycles, and
nothing to answer basic questions:

- "What did we generate so far?"
- "Where's the `.glb` for task X?"
- "If the same prompt runs twice, do we pay for storage twice?"
- "If the app crashes mid-generation, does the output survive?"

We needed a layer between `plugin_task_completed` and the rest of the app that
normalizes these three shapes into a single, durable catalog.

Open questions going in:

1. **Where do managed files live on disk?** One folder? By type? By plugin?
2. **How do we name files?** By task id? By content hash? By counter?
3. **How do we persist metadata across restarts?** A JSON index? SQLite?
4. **Who's responsible for downloading Tripo's remote URLs?** The plugin? The
   asset layer? A separate downloader service?
5. **Do we deduplicate?** Two prompts that happen to produce identical bytes
   — is that one asset or two?

## Decision

1. **`scripts/asset_manager.gd`** — a single `Node` module, child of
   `Orchestrator`, owning `user://assets/<type>/<id>.<ext>` and a sibling
   `index.json`.

2. **Asset IDs are derived from `sha256(content)[:16]`.** Content-hash
   addressing gives us automatic dedup — two generations producing identical
   bytes collapse to one on-disk file and one index row. The 16-hex-char
   prefix (64 bits) is more than enough collision space for a personal asset
   catalog.

3. **Three ingest modes, one public entry point.** `ingest(source_plugin,
   source_task_id, result, prompt)` switches on `result.asset_type`:
   - `"text"` → bytes are `result.text` UTF-8-encoded; no file copy.
   - `"audio"` / `"image"` → `result.path` is a `user://` file the plugin
     already wrote; we read the bytes and re-persist under our layout.
   - `"3d"` → `result.path` is an `http(s)` URL; we fetch it via
     `HTTPRequest` and persist the body.

4. **Wiring lives in `Orchestrator`.** The orchestrator hooks
   `PluginManager.plugin_task_completed` → `AssetManager.ingest` and
   maintains a small prompt cache (`_prompts_by_task`) populated by the
   `generate()` facade. Prompts travel with the asset as provenance.

5. **Persistence is a JSON index** (`user://assets/index.json`). Written on
   every mutation (ingest, delete); loaded on construction. Schema-versioned
   so we can migrate later without breaking users who upgrade.

6. **Path validation on binary ingest.** Plugin-declared `path` must start
   with `user://` and must exist. Anything else fails fast with an
   `INVALID_PARAMS` error. This keeps a buggy / hostile plugin from telling
   us to ingest `/etc/passwd`.

## Consequences

- **Unified query surface.** `list_assets({asset_type: "3d"})` answers
  "what 3D models do I have?" regardless of which plugin produced them.
- **Automatic dedup.** Re-running the same Claude prompt doesn't grow the
  catalog. The second call returns `deduplicated: true` with the existing
  `asset_id`. UX implication: if a user expects two distinct rows for two
  "different" runs that happened to collide, they'll see one. We think
  that's the right tradeoff — identical bytes are identical bytes.
- **Durable after restart.** `index.json` is rewritten on every mutation,
  so a crash mid-session at worst loses the in-flight asset (not the
  catalog).
- **The catalog is byte-level, not resource-level.** AssetManager doesn't
  import `.glb`/`.mp3`/`.png` into Godot `Resource`s — that's a job for a
  scene/asset-importer layer that sits on top. We want this module to stay
  boring and testable without the editor pipeline in the loop.
- **Prompt cache in Orchestrator is lossy under direct `PluginManager.generate`.**
  Tests or tools that call the manager directly bypass the facade, so their
  generated assets will record `prompt = ""`. That's fine — the facade is
  the app's intended path, and the cost of hardening direct calls (hooking
  a `task_started` signal) isn't worth the complexity today.

## Alternatives considered

- **Flat `user://assets/<id>` layout, no subfolders.** Rejected: type
  subfolders make the directory browsable by a human and make per-type
  cleanup (e.g. "clear all 3D cache") a single `rm -rf`.
- **UUID ids, separate dedup table.** Rejected: extra state, and solves
  nothing we didn't already solve with content hashing.
- **SQLite index instead of JSON.** Rejected for MVP: JSON is inspectable
  by hand, survives text diffs, and the catalog is small (O(hundreds) for
  a personal app). Revisit if growth demands it.
- **Download 3D assets inside `TripoPlugin` itself, hand `user://` path to
  AssetManager.** Rejected: bloats the plugin contract, and every future
  remote-URL plugin would repeat the same HTTP boilerplate. Centralizing
  the fetch in AssetManager keeps plugins thin.
- **Don't dedupe.** Rejected: zero code savings (we still need the hash for
  the id), and identical-bytes-as-two-assets just confuses the user.
- **Pass `prompt` through the `result` dictionary.** Rejected: would force
  every plugin to echo its input back, and a misbehaving plugin could
  rewrite history. Orchestrator already knows the prompt it sent; easier
  and safer to track it there.

## Follow-ups

- **Thumbnails / previews.** A derived-asset concept (`derived_from:
  <asset_id>`) for cheap JPEGs of 3D models, waveform PNGs for audio, etc.
- **GC policy.** Today `delete_asset` is the only way bytes leave the
  catalog. A "delete everything older than N days / over M MB" policy will
  matter once real generation gets rolling.
- **Budget integration.** `result.cost` is already tracked per asset;
  summing it per plugin gives a cheap "what did I spend?" dashboard
  without a separate ledger. May feed into the budget-tracker phase.
- **Scene import layer.** The Godot-resource side of things: `.glb →
  PackedScene`, `.mp3 → AudioStream`, etc. That's deliberately out of scope
  here.
