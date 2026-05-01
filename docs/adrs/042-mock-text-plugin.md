# ADR 042: Mock text plugin

- **Status:** Accepted
- **Date:** 2026-05-01

## Context

Phases 7, 14, 37 established the "real + mock per asset category"
pattern:

| Category | Real plugin           | Mock plugin              |
|----------|-----------------------|---------------------------|
| audio    | elevenlabs_plugin     | mock_audio_plugin (Phase 7) |
| 3d       | tripo_plugin          | mock_3d_plugin (early)    |
| image    | openai_image_plugin   | mock_image_plugin (Phase 37) |
| **text** | **claude_plugin**     | **MISSING**               |

ADR 037 closed the image asymmetry; ADR 042 closes the last one.

The text gap was less urgent than image because:
- Claude is cheap (~$0.0005 per smoke call). Tests can afford to
  hit it more easily than DALL-E.
- Many text tests run validation paths before any network goes
  out; those don't need a mock.

But three concrete coverage gaps still benefit from a mock:

1. **Retry coverage on text-typed responses.** Audio and image
   exercise PluginManager's retry/backoff layer via the
   first-request RATE_LIMIT trick. Text never did — Claude's
   real plugin doesn't synthesize a fake retryable failure.
2. **Deterministic chat-edit harness.** ADR 017's chat-edit
   currently dispatches through Claude. A mock_text plugin
   gives us a path to write end-to-end chat-edit tests where
   the response is bit-stable. (Future work — this ADR doesn't
   wire that, but the mock is the prerequisite.)
3. **AssetManager text-typed ingest.** Same coverage argument
   as image — exercising the ingest pipeline against a real
   producer pipeline (vs hand-rolled text fixtures) catches
   regressions in shape mapping.

## Decision

1. **Echo-style response.** `[mock] <prompt>` — preserves the
   prompt so tests can verify the plugin received the right
   input. Considered:
   - **Reverse the prompt.** Cute, hard to use. Rejected.
   - **Constant string.** Doesn't verify input plumbing.
   - **Word count.** Useful for one assertion, not for general
     content checks.
   Echo wins on the "useful for tests" axis.

2. **Same first-request RATE_LIMIT pattern as audio / image.**
   `fail_first_request: bool = true` toggle so happy-path tests
   can bypass it. Symmetric across categories — retry coverage
   is now uniform.

3. **`max_words` clamp param.** Text-specific knob: useful for
   testing UI that consumes long-vs-short text outputs. Default
   `0` = no clamp (full echo). Other values clamp to N space-
   separated words.

4. **Result shape matches `claude_plugin`'s.** `asset_type:
   "text"`, `format: "plain"`, `text: "<body>"`, `path: ""`.
   Consumers (asset_preview, task_list, generate_form) treat
   them interchangeably. Anything that works against Claude
   works against the mock.

5. **NOT registered in PluginRegistry.** Same as the other mocks
   — tests construct it directly, the orchestrator doesn't auto-
   load. Keeps real-app flows clean.

## Behaviour

- **First request** fails with `RATE_LIMIT` (retryable=true,
  retry_after_ms=100). Mirrors mock_audio / mock_image.
- **Subsequent requests** echo the prompt with `[mock] ` prefix.
- **`max_words`** clamps echo to N words. The prefix counts as
  one word (so `max_words=3` for prompt "one two three four"
  produces `"[mock] one two"` — 3 words total).
- **Cost** is a flat `$0.001` per request. Small enough to not
  dominate cost-tracker tests; non-zero so cost flow is
  exercised.
- **Cancellation** honored at every progress tick — task_failed
  with `ERR_CANCELLED`, task erased.

## Consequences

- **Coverage uniformity.** Every asset category exercises every
  PluginManager codepath against a deterministic backend.
- **Chat-edit tests can become deterministic.** Currently, ADR
  017's tests stub Claude responses by manually emitting
  `plugin_task_completed` signals. With mock_text in place, the
  full PluginManager dispatch + retry + result pipeline can be
  exercised with one fewer mock layer. Follow-up.
- **+1 plugin file, +14 tests, ~150 LOC plugin + ~150 LOC
  tests.** Small footprint, clean closure.
- **Mock plugin grid is now complete:** every category, every
  retry path, every ingest path testable without API quota.

## Alternatives considered

- **Synthesise via word-list bigrams.** Generate plausible-
  looking text procedurally. Rejected — more code, less
  testable. Echo gives the test surface what it needs.
- **Use claude_plugin directly with a faked HTTPRequest.**
  Considered briefly. Rejected — would require a complex
  mock at the HTTP layer; the plugin-level mock is cleaner.
- **Skip max_words.** Just echo the full prompt. Rejected —
  having one knob lets tests exercise the param-pipeline at
  least once, and clamp-handling is a useful feature to
  verify.
- **Static fixture files.** Pre-baked text snippets the mock
  serves up. Rejected — adds repo files, less flexible than
  echoing the prompt.
- **Register in PluginRegistry.** Rejected — keeps real-app
  flows clean. Tests instantiate directly.

## Settings registry

No new settings keys.

## Follow-ups

- **Deterministic chat-edit harness.** Wire the mock_text
  plugin into a Claude-substitute path so chat-edit tests don't
  need to manually emit task_completed signals. Pairs with
  Phase 17's signal-stubbing pattern.
- **Latency knob.** `simulate_latency_ms` config so cost-
  tracker / task-list tests can flex slow paths.
- **Configurable echo template.** Today the prefix is hard-
  coded `[mock] `. Tests that want to assert on a specific
  pattern could pass `template: "ECHO: {prompt}"` etc.
- **Failure injection.** A toggle to flip into "always fail
  with PROVIDER_ERROR" for testing how the rest of the app
  copes when text generation breaks.
- **Multi-turn echo.** Extend the result with a fake
  conversation thread so chat-edit's refinement-mode tests
  have something to iterate against.
