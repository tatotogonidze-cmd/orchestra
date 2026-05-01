# ADR 036: OpenAI image plugin

- **Status:** Accepted
- **Date:** 2026-05-01

## Context

The plugin roster shipped over Phases 13–16 covered three of the
four asset categories the app's `AssetManager` recognises (text,
audio, image, 3d) — but **image** had no real plugin. Mock plugins
covered audio (`mock_audio_plugin`) and 3D (`mock_3d_plugin`) for
test-suite stress, and ElevenLabs / Tripo / Claude were the real-
provider implementations. Image generation went unrepresented.

That's a real product gap. A user trying to assemble a game asset
catalog (textures, character portraits, UI elements) has no
single-API path; they have to leave the app, generate elsewhere,
then drop files in. The orchestrator's whole pitch — "one place
for AI-driven game-dev workflows" — wears thin without image
generation.

The HTTP plugin framework (ADR 013) was designed for this case.
Phase 36 cashes that in.

The decisions to make:

1. **Which API?** OpenAI Images, Stability AI, Replicate-hosted
   Stable Diffusion, Recraft, Together AI's hosted models, etc.
2. **Sync vs polling response model?**
3. **`response_format=url` vs `response_format=b64_json`?**
4. **Cost model — per-image vs per-megapixel vs per-token?**
5. **What about content policy refusals?**
6. **Same auth pattern as the other real plugins, or different?**

## Decision

1. **OpenAI's `/v1/images/generations` (gpt-image-1).**
   - Well-documented, stable.
   - Bearer-token auth (different from ElevenLabs's `xi-api-key`
     and Tripo's bearer + polling — gives the test harness a
     fourth distinct auth shape to exercise).
   - Sync response model (no polling, no webhooks) — adds a
     "single POST returns the asset" plugin to the codebase
     alongside ElevenLabs (audio) and Claude (text), and gives
     us a testbed that ISN'T as complex as Tripo's poll loop.
   - One-step setup — same `OPENAI_API_KEY` env var that many
     developers already have set.
   - Stability AI / Replicate are good follow-ups but each adds
     its own quirks (Stability's per-millicent pricing,
     Replicate's prediction polling).

2. **Sync.** OpenAI image generation completes in seconds; the
   single POST waits and returns the result. We mirror
   ElevenLabs's "post once, decode the response, write the
   file, emit task_completed" shape — no `_run_polling_loop`
   like Tripo.

3. **`response_format=b64_json`.** The other option is
   `url`, where the response carries a temporary CDN link that
   we'd have to fetch in a follow-up GET.
   - b64 keeps the asset bytes inside one HTTP transaction.
     Fewer failure modes (no second-request timeout, no expiring
     URL race).
   - The transport cost is real (~1.4 MB for a 1024×1024 PNG
     in base64) but acceptable on the single-image scale we
     work at.
   - Simpler error handling: response status === asset status.
     A URL-based flow needs to handle "POST 200, but the URL
     fetch 404'd" — extra surface for no real benefit at MVP.

4. **Per-image flat cost.** OpenAI's actual rate card varies
   by model + size + quality (gpt-image-1 standard 1024² is
   ~$0.040; hd is ~$0.080; portrait/landscape sizes shift
   prices). For MVP we ship a single `per_image_cost_usd`
   config (default $0.040) — overridable via the credential
   store. A per-config-pricing-table is a follow-up; matching
   ElevenLabs / Claude's "rough estimate, override via config"
   pattern keeps the cost surface uniform.

5. **Content-policy refusals are mapped via the existing
   HTTP error pipeline.** OpenAI returns:
   - 400 with `{"error": {"code": "content_policy_violation",
     ...}}` for content blocks.
   - 401 / 403 for bad auth.
   - 429 for rate limits (Retry-After honored).
   - 500 / 503 for provider issues.
   `_make_http_error` already handles all of those — content
   policy violations land as `INVALID_PARAMS` (since the
   request shape was rejected, not the credentials). Good
   enough; a future ADR can add a dedicated `CONTENT_POLICY`
   error code if the UI needs to react differently.

6. **Same auth pattern as Claude.** Bearer token via
   `Authorization: Bearer <api_key>`, plus the standard
   `Content-Type: application/json`. No surprises.

## Plugin metadata

```
{
  "plugin_name": "openai_image",
  "category":    "image",
  "supported_formats": ["png"],
  "capabilities": {parallel: true, streaming: false, cancel: true},
  "limits": {max_prompt_length: 4000, requests_per_minute: 50},
}
```

The 4000-char prompt cap matches OpenAI's documented limit. The
RPM hint is conservative — actual rate limits depend on the org
tier. Used by the credential editor's RPM diagnostics.

## Settings registry

No new settings keys. Cost config and api_key live in the
credential store (same convention as ElevenLabs / Tripo / Claude).
The Settings panel doesn't surface plugin-specific keys.

## Param schema

```
size:    enum ["1024x1024", "1024x1792", "1792x1024"], default "1024x1024"
quality: enum ["standard", "hd"], default "standard"
model:   string, default "gpt-image-1"
```

Three rendered fields in the param_form, matching the user's
mental model. We deliberately omit `n` (number of images per
request) — the orchestrator's task model is one-task-one-asset;
asking for `n=4` would silently discard images. A future ADR can
extend the contract to support multi-output tasks if there's
demand.

## Output shape

```
{
  asset_type:     "image",
  format:         "png",
  path:           "user://assets/image/<task_id>.png",
  model:          "gpt-image-1",
  size:           "1024x1024",
  quality:        "standard",
  revised_prompt: "<OpenAI's rewritten prompt, if any>",
  cost:           0.04,
  plugin:         "openai_image",
}
```

`revised_prompt` is OpenAI-specific — they automatically rewrite
short or ambiguous prompts. We surface it on the result so the
asset gallery / preview can show "what the model actually
rendered" alongside what the user typed.

## Consequences

- **Image generation works end-to-end without leaving the app.**
  Generate → asset gallery → asset preview shows the PNG. (The
  asset preview's image branch was already wired during ADR 012
  but exercised only by mock asset records.)
- **Three of the four real plugins now share the
  Bearer-auth + sync-POST shape (Claude, OpenAI Image, future
  OpenAI Audio) vs. one polling-loop plugin (Tripo).** Lopsided
  is fine — the framework supports both.
- **Test harness gets one more end-to-end sync plugin to lean
  on.** The smoke harness is plugin-agnostic; new entries are
  picked up automatically.
- **Image asset bytes flow through the AssetManager's existing
  ingest pipeline** — content-hashed dedup (ADR 008) works
  uniformly for the new images.
- **Param form gets the OpenAI plugin's three-field schema for
  free** via ADR 015's schema-driven inputs.
- **No mock plugin for image** — adding one would let tests
  exercise the AssetManager's image-typed ingest more
  thoroughly. Follow-up.

## Alternatives considered

- **Stable Diffusion via Replicate.** Considered. Rejected for
  MVP: Replicate's API is prediction-polling, which we already
  exercise via Tripo. Adding a third polling plugin means
  more polling-tests, less coverage. OpenAI's sync model gives
  the framework a different shape to flex.
- **Stability AI directly.** Their per-millicent pricing model
  is awkward for our flat per-call cost estimate, and their
  v2-beta image API has been moving fast. Defer until v2 GA.
- **Pollinations.ai (free, no auth).** Considered as an "always
  works" fallback. Rejected for MVP: bypasses the credential
  store flow entirely, doesn't exercise the auth pipeline,
  and Pollinations's quality / availability isn't suitable
  for production game-dev use.
- **`response_format=url` instead of b64_json.** Less transport
  overhead per request. Rejected — adds a second HTTP fetch with
  its own failure modes, and the URL expires (problematic if
  the user takes a while to inspect / save the asset).
- **Multi-image responses (n > 1).** OpenAI's API supports
  generating multiple images per request. Rejected for MVP —
  the orchestrator's task contract is one-task-one-asset;
  expanding it touches every consumer (task_list, asset_gallery,
  cost tracker). Future work.
- **DALL-E 3 (older model).** gpt-image-1 is the current
  recommendation; DALL-E 3 still works but is being deprecated.
  Default to gpt-image-1; users can override `params.model`.

## Follow-ups

- **Mock image plugin.** A `mock_image_plugin.gd` in the
  `plugins/` folder for stress tests that don't burn API
  quota. Mirrors `mock_audio_plugin` / `mock_3d_plugin`.
- **Multi-image dispatch.** Either the framework grows
  one-task-many-assets, or we ship a wrapper that fans out
  N tasks server-side and awaits all of them.
- **Image edit / variation endpoints.** OpenAI exposes
  `/v1/images/edits` (with mask) and `/v1/images/variations`.
  Both fit naturally into a per-plugin operation enum
  (`generate` | `edit` | `variation`) in the param schema.
- **Per-config pricing table.** Map `(model, size, quality) →
  cost` in the plugin config so estimates are accurate without
  manual override.
- **Content-policy error code.** A dedicated
  `ERR_CONTENT_POLICY` constant in BasePlugin.gd, with the
  credential editor surfacing the policy reason inline.
- **Save revised_prompt to asset metadata.** Currently passed
  through on the task result; could be persisted on the
  AssetManager record for later inspection.
- **Stability AI / Replicate plugins.** The next two real image
  providers, picking up a wider quality/style spectrum.
