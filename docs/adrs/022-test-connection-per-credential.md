# ADR 022: Test connection — per-row credential probe

- **Status:** Accepted
- **Date:** 2026-04-25

## Context

ADR 011 shipped the credential editor with per-plugin api_key CRUD. A
saved key sat in the encrypted store; the user had to actually
dispatch a generation to find out whether the key worked. ADR 011
explicitly listed this as a follow-up:

> "Test connection" button per row. A cheap probe — Claude:
> 1-token messages call; ElevenLabs: voices list; Tripo: account
> endpoint. Surfaces auth failures *immediately* instead of on the
> next real generation.

Phase 22 redeems that follow-up. With chat-edit (Phase 17) and
form-edit (Phase 18) now live, an invalid key surfaces as a deep
chain of unrelated failures (a Claude chat-edit task that fails with
`AUTH_FAILED` is a confusing signal when the user just wanted to test
their key). The probe shortens that loop.

The decisions to make:

1. **Where does the probe live?** On `BasePlugin`, on `HttpPluginBase`,
   or as separate per-plugin code?
2. **Sync or async?** Probes are HTTP — by definition async — but
   the call site wants a clean `success/error` answer.
3. **Which key do we probe?** The currently-registered (saved) key,
   or the value in the LineEdit right now?
4. **What probe per provider?** Cheapest endpoint that exercises
   auth.
5. **How do we test the wiring without hitting real APIs?**

## Decision

1. **`test_connection() -> Dictionary` on `BasePlugin`.** Default
   implementation returns `{success: false, error: "test_connection
   not implemented for this plugin"}`. Each real plugin overrides
   with a minimal HTTP probe. Mock plugins override with synthetic
   success. This puts the per-provider probe code next to the rest
   of the plugin's API logic — same file, same headers, same
   timeout settings.

2. **Async via Godot's `await`.** Plugins use the existing
   `HttpPluginBase._http_request` helper, which awaits the
   underlying `HTTPRequest.request_completed` signal. The
   credential editor's click handler `await`s `plugin.test_connection()`,
   so synchronous mock probes resolve immediately and async real
   probes block only the click handler — not the rest of the UI.

3. **Probe the registered (saved) key, not the typed value.** The
   editor's Test button looks up
   `_orch.plugin_manager.active_plugins[plugin_name]` and probes
   THAT instance. Implications:
   - User must Save a new key before testing it.
   - If the plugin isn't registered (no saved key, or registration
     failed during boot), the button explains "Save first" instead
     of probing.
   The alternative — spin up a temporary plugin instance with the
   typed key — adds complexity and a temporary registered/de-
   registered state; for MVP, keep it simple. Documented as a
   follow-up.

4. **Probe choice per provider:**
   - **Claude:** `GET /v1/models`. Anthropic exposes a free
     model-list endpoint that returns 200 with valid auth, 401
     otherwise.
   - **ElevenLabs:** `GET /v1/user`. Free, returns the account
     summary (subscription tier, etc) when auth is valid.
   - **Tripo:** `GET /v2/openapi/user/balance`. Free, returns the
     account's API balance.
   - **Mock plugins:** synthetic
     `{"success": true, "message": "mock — no real backend"}`.
     Lets the credential editor's button have a deterministic
     return path for dev / test runs.

5. **Tests use a `FakeCredentialPlugin` registered under "claude".**
   `plugin_manager.register_plugin(name, instance, config)` accepts
   any `BasePlugin` subclass — we register a minimal subclass with
   a configurable `_test_result` so the editor's Test handler has a
   real plugin to await without anyone hitting Anthropic. Mock
   plugins' own `test_connection` is unit-tested directly. Real
   plugins' HTTP probes are NOT exercised in the test suite —
   they'd need a real api_key + network — but the wiring (UI →
   plugin → result → status painted) is fully covered.

## Consequences

- **Auth failures surface immediately.** The user types a key, hits
  Save, hits Test, sees ✓ or ✗ within ~one HTTP round-trip. The
  alternative — find out via a failed generate — is gone.
- **The per-row UI grew by one button + one status label.** Each
  row in the editor now has: name | input | Show/Hide | Delete |
  Test | status. Layout still fits in the 520-px modal we sized
  for ADR 011; tested via the existing structure assertions.
- **`BasePlugin`'s contract gained one method.** Every plugin now
  needs an explicit `test_connection` override (or accepts the
  default "not supported" semantics). New plugins added via the
  field guide in `docs/plugins.md` should implement one.
- **The probe uses the registered plugin instance.** Means:
  - Newly-typed keys aren't tested until the user clicks Save.
  - The Test button is meaningfully disabled / explanatory when
    the plugin isn't registered — common state when an env var
    isn't set and the credential store hasn't been populated.
- **Test cost is non-zero.** Claude's `/v1/models` is free; Tripo's
  balance endpoint is free; ElevenLabs's `/v1/user` is free. None
  of the chosen probes consume usage credits. Documented so a
  future plugin author considers this when adding their probe.
- **No plugin manager state changes.** The probe doesn't
  re-register, doesn't mutate `active_plugins`, doesn't fire
  EventBus events. Pure read-only check. Side-effect-free.

## Alternatives considered

- **Synchronous probe via `HTTPClient` directly.** Would block the
  UI thread for the duration of the call. Bad UX, bad practice.
- **Probe the typed value, not the saved one.** Spin up a temp
  plugin per click, initialize with the typed key, await
  `test_connection`, free. Adds plumbing — registry instantiation
  in the UI layer, lifecycle management. Punted as a follow-up
  with a tooltip on the Test button calling out the save-first
  rule.
- **Use `health_check()` instead of adding a new method.**
  `health_check` is currently a "deferred" check that doesn't hit
  the API. Repurposing it would change semantics across the
  codebase (orchestrator boot calls `enable_plugin` which gates on
  `health_check`; we don't want every boot to make a network call).
  A separate method keeps the contracts clean.
- **Background / streaming progress while testing.** "Probing… 2s
  elapsed". Skipped. The probes are sub-second on healthy networks
  and the disabled button + "testing…" status is enough feedback.
- **Include latency / cost in the result.** Useful but adds shape
  bikeshedding. Keep `{success, error?, message?}` minimal for MVP.
- **Cache the result for N seconds.** Premature optimisation; users
  don't spam Test.

## Follow-ups

- **Probe-with-typed-key.** Spin up a temp plugin to test the
  current LineEdit value WITHOUT requiring Save. Helpful for
  copy-paste-from-clipboard flows.
- **Structured error mapping.** Map probe HTTP statuses to the
  same `ERR_AUTH_FAILED` / `ERR_NETWORK` / etc constants the
  generation flow uses, so the row's failure message is
  consistent with the rest of the app.
- **Latency surfacing.** Show "OK (320 ms)" so the user can spot
  flaky networks.
- **Test-on-save toggle.** A "test connection automatically when
  I save" preference in the settings store (when settings ship).
- **Probe per credential KIND.** Claude has `pricing` config too —
  a future "validate pricing block" probe could go alongside.
- **Background probes after unlock.** When the credential store
  unlocks at boot, kick off a Test for each registered plugin
  and report the summary in the status bar / footer. Validates
  every key without forcing manual clicks.
- **Cache + debounce.** Avoid spamming a provider with rapid Test
  clicks; cache last-result for N seconds and disable the button
  while the cache is hot.
- **Document `test_connection` in `docs/plugins.md`.** New
  plugin authors should know what's expected; today the
  contract is "implement this method, return this shape".
