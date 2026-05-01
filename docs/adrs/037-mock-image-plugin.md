# ADR 037: Mock image plugin

- **Status:** Accepted
- **Date:** 2026-05-01

## Context

Phase 36 (ADR 036) shipped the first real image plugin
(`openai_image_plugin`). The other three categories already had
matched mock + real pairs:

| Category | Real plugin           | Mock plugin           |
|----------|-----------------------|------------------------|
| text     | claude_plugin         | (none, claude is cheap)|
| audio    | elevenlabs_plugin     | mock_audio_plugin      |
| 3d       | tripo_plugin          | mock_3d_plugin         |
| image    | openai_image_plugin   | **MISSING**            |

A mock image plugin closes that asymmetry, AND addresses three
concrete coverage gaps:

1. **Retry coverage** — `mock_audio_plugin` fires `RATE_LIMIT` on
   the first request to drive PluginManager's retry/backoff layer.
   Image had no equivalent; retry behaviour against the image
   category was untested.
2. **End-to-end preview rehearsal** — `asset_preview._render_image`
   exists (Phase 12 / ADR 012) but the existing test there
   hand-rolls a PNG fixture rather than producing one through a
   plugin → AssetManager → preview chain.
3. **Stress-test image asset** — when working on AssetManager
   features (dedup, ingest pipeline edge cases) we want an image
   producer we can run hundreds of times against without burning
   OpenAI credit.

The decisions to make:

1. **Synthetic PNG vs static fixture file?**
2. **Real disk write vs `mock://...` fake path (matching
   mock_audio / mock_3d)?**
3. **Color/content deterministic per prompt or random?**
4. **Output dir: shared with the real plugin or separate?**

## Decision

1. **Synthetic PNG generated in-memory** via `Image.create()` +
   `Image.fill()` + `Image.save_png()`. No fixture files in the
   repo, no external assets to maintain.

2. **Real disk write to `user://assets/image_mock/`.** This is
   the deliberate divergence from `mock_audio` / `mock_3d`,
   which use fake `mock://...` paths.
   - Audio mocks can't easily produce a valid mp3 in-memory
     without a synthesis library — fake paths are the right call.
   - 3D mocks can't produce a valid GLB in-memory — same.
   - Images CAN be produced via `Image.save_png()` in a few lines
     of GDScript with no dependencies. Writing a real file lets
     `asset_preview._render_image` actually load it, which means
     the image-branch test now flows through the same plugin
     pipeline a real run would use.

3. **Deterministic color per prompt.** `_color_for_prompt(prompt)`
   maps `hash(prompt)` to an HSV hue, fixed saturation/value.
   - Same prompt → same color across runs (snapshot-friendly).
   - Different prompts → visually distinct (eyeball-friendly).
   - Tests can assert on the central-pixel color for a given
     prompt without brittle floating-point comparisons —
     `Color.from_hsv(stable_hue, 0.7, 0.9)` is bit-stable.

4. **Separate output dir** — `user://assets/image_mock/` instead
   of the real plugin's `user://assets/image/`. Mocks aren't
   "real" assets; the user shouldn't see them mixed with their
   genuine OpenAI outputs. AssetManager doesn't care about the
   subdirectory — it stores asset records by content hash, not
   path.

## Plugin metadata

```
{
  "plugin_name": "mock_image",
  "category":    "image",
  "supported_formats": ["png"],
  "capabilities": {parallel: true, streaming: false, cancel: true},
  "limits": {max_prompt_length: 2000, requests_per_minute: 60},
}
```

Same shape as `mock_audio_plugin` / `mock_3d_plugin`.

## Param schema

```
size: enum [64, 128, 256], default 64
```

Square output only — covers the assertion surface (correct
dimensions, correct format) without the orientation-handling
complexity of OpenAI's portrait/landscape sizes.

## Output shape

```
{
  asset_type: "image",
  format:     "png",
  path:       "user://assets/image_mock/<task_id>.png",
  size:       "64x64",
  cost:       0.01,
  plugin:     "mock_image",
}
```

Cost is a flat $0.01 — small enough not to dominate session
spend in tests, large enough to verify cost-tracker integration.

## Behaviour

- **First request** fails with `RATE_LIMIT` (retryable=true,
  retry_after_ms=100). Mirrors `mock_audio_plugin`.
- **`fail_first_request = false`** disables that gating —
  tests exercising the happy path skip the retry loop.
- **Two progress ticks** before completion (~100 ms total),
  same cadence as `mock_audio`.
- **Cancellation** is honored at every progress tick — task_failed
  emitted with `ERR_CANCELLED` and the task is erased.

## Plugin registry

NOT registered in `PluginRegistry`. Mocks are constructed and
configured directly by tests / tools, not auto-loaded by the
orchestrator. Same convention as `mock_audio_plugin` and
`mock_3d_plugin`.

## Consequences

- **Retry coverage now uniform across categories.** All three
  category mocks (audio / 3d via dropped plugin behaviour, image)
  exercise PluginManager's retry layer.
- **Asset-preview image path tested through a real plugin
  pipeline.** Generate → AssetManager.ingest → asset_preview.show.
  The hand-rolled fixture test still works, but isn't load-bearing.
- **AssetManager's image-typed ingest gets uniform coverage
  alongside text/audio/3d.** No behavioural changes — content-
  hash dedup works identically per type — but the surface is
  now exercised.
- **Tests can assert on color stability.** A future regression
  in `Image.from_hsv` or PNG encoding would surface here.
- **+1 plugin file, +200 LOC** (plugin + tests). Small footprint
  for the coverage win.

## Alternatives considered

- **Fake `mock://...` path like the other two mocks.** Rejected:
  asset_preview's image branch needs a real file. Diverging from
  the convention is justified by the file-format asymmetry
  (PNG is trivially synthesisable, mp3 / GLB are not).
- **Static fixture PNG checked into `tests/fixtures/`.** Rejected:
  the synthesis route is cleaner — no binary in the repo, the
  test surface verifies a real producer pipeline (encode +
  write), and the per-prompt color makes diagnostics easier.
- **Random color per call.** Rejected: tests can't make stable
  assertions without snapshotting; the determinism is a feature.
- **Multiple format support** (jpeg, webp). Rejected for MVP —
  PNG covers asset_preview's needs; extra formats expand the
  test matrix without enabling new coverage.
- **Variable failure modes** (drop the first 2 requests, fail
  with INVALID_PARAMS for some prompts, etc). Rejected — keeps
  the mock predictable. The single first-request RATE_LIMIT
  toggle is enough; richer chaos belongs in a dedicated chaos-
  test plugin if we ever need one.

## Follow-ups

- **Latency knob.** A `simulate_latency_ms` config so AssetManager
  / cost-tracker tests can exercise slow-path codepaths.
- **Variation / edit operations.** Mock the `/v1/images/edits` and
  `/v1/images/variations` shape if we add those to the real plugin
  (ADR 036 follow-up).
- **Multi-output dispatch.** When the framework grows
  one-task-many-assets, this mock is the cheapest place to
  exercise that contract.
- **Image manifest with revised_prompt.** OpenAI returns a
  `revised_prompt` field; mock could echo a fake "revised"
  version of the input so UI surfaces that show revised_prompt
  have something deterministic to render.
