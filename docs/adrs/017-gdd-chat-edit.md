# ADR 017: GDD chat-edit — natural-language editing via Claude

- **Status:** Accepted
- **Date:** 2026-04-25

## Context

Phase 16 shipped a read-only GDD viewer (ADR 016). Phase 17 was the
fork: ship traditional form-based edit, or ship the chat-edit flow
that ADR 006's snapshot infrastructure was explicitly designed to
support? The user picked chat-edit as the orchestrator's "AI
co-author" capability — the differentiator that makes this app more
than a generate-and-collect tool.

The flow we wanted:

1. User has a GDD loaded in the viewer.
2. User types a natural-language instruction (e.g. "add a stealth
   mechanic", "rename the protagonist to Mira").
3. We compose a prompt that gives Claude the schema + current
   document + instruction and instructs it to return the updated
   JSON.
4. The reply comes back, we parse it, render a side-by-side preview,
   and ask the user to Approve or Reject.
5. Approve writes two snapshots — the pre-state for rollback, then
   the post-state — and updates the panel to the new document.
6. Reject discards the proposal; nothing on disk changes.

The decisions to make:

1. **Where does chat-edit live in the UI?** Inside `gdd_panel`,
   alongside the viewer, or in a separate overlay?
2. **Prompt shape.** Include the full schema or a precis? Include
   the current GDD pretty-printed or compact?
3. **Response parsing — how strict?** Claude sometimes wraps in
   code fences despite "no code fences"; do we tolerate that?
4. **Diff presentation.** Real diff (red/green per line) or just a
   side-by-side view + a small summary?
5. **Snapshot semantics on Approve.** Just save the new state and
   rely on `save_gdd`'s built-in snapshot? Or explicitly snapshot
   the pre-state first so the user can roll back to where they
   were?
6. **Tests when the flow involves a real network call.** How do we
   exercise the parser / state machine without hitting Claude?

## Decision

1. **Inside `gdd_panel`.** Two new sections appended below the
   viewer's existing content:
   - **Chat-edit**: TextEdit input + Submit button + status label.
   - **Proposed change**: summary line + side-by-side
     before/after `TextEdit`s (read-only) + Approve / Reject.
   The proposed-change section is hidden until a parse succeeds.
   Keeping both the viewer and the editor in one overlay means
   the user can see what they have, what they're changing, and
   what they'll get without juggling windows.

2. **Prompt: full schema, full GDD, both pretty-printed.** Token
   cost is modest (the schema is ~3KB, GDDs typically <2KB) and
   Claude consistently honours the structure when the schema is
   present. We append:
   ```
   You are editing a Game Design Document. Apply the requested
   change and return ONLY the updated JSON document.
   The document conforms to this JSON Schema: <schema_json>
   The current document is: <gdd_json>
   Apply this edit: <instruction>
   Return ONLY the updated JSON document. No prose, no code
   fences, no commentary.
   ```
   The "ONLY JSON" instruction is doubled (start and end) because
   in practice repetition reduces fence/preamble drift.

3. **Tolerant parser.** `_parse_chat_edit_response` strips a
   leading ```` ```json ```` fence if present. This is the single
   most common deviation; everything else (preamble, postamble,
   code-fence-without-language) we treat as a parse failure with a
   clear error message. We surface the error and keep the user's
   instruction visible so they can retry.

4. **Side-by-side JSON + summary, no per-line diff.** A real diff
   would need either a third-party diff library or a hand-rolled
   LCS — both too much for one phase. The summary line is
   semantic-ish:
   ```
   Changes: mechanics: 2 → 3, ~game_title
   ```
   Entity-array count deltas + `~field` for top-level changes.
   Pretty-printed JSON in two `TextEdit`s lets the user scroll
   and visually compare; an in-IDE diff view is a follow-up.

5. **Two saves on Approve, two snapshots.** `save_gdd(current,
   path)` first — overwrites the file with itself but creates a
   snapshot — and then `save_gdd(proposed, path)`. After Approve
   the snapshot timeline shows `vN: pre-state, vN+1:
   post-state`. The user can roll back to vN if they regret the
   chat-edit. The redundant first write is cheap and keeps the
   `_create_snapshot` API private.

6. **Tests drive the internal handlers, never the network.** The
   chat-edit dispatch is `Orchestrator.generate("claude", ...)`
   under the hood. We can't call that in headless tests without
   a real API key. Instead the tests:
   - Verify `_compose_chat_edit_prompt` produces a string with
     the expected substrings.
   - Verify `_parse_chat_edit_response` for valid JSON, fenced
     JSON, invalid JSON, empty input.
   - Verify `_compute_diff_summary` on hand-crafted before/after
     pairs.
   - Drive `_on_chat_edit_completed(plugin, task_id, result)`
     directly with a synthetic result dictionary — both for our
     own task id and for a different one, to exercise the
     filter.
   - Drive `_on_approve_pressed` after manually setting
     `_pending_gdd`, then assert two snapshots landed and the
     disk file was updated.

## Consequences

- **The orchestrator is now an AI co-author.** Until this phase
  the GDD was a JSON file the user had to edit by hand. The
  chat-edit flow turns it into a thing you talk to. ADR 006's
  snapshot infrastructure finally pays off.
- **The chat-edit dispatch goes through the same pipeline as
  user-initiated `Orchestrator.generate` calls.** That means
  cost is recorded by `cost_tracker`, the task shows up in
  `task_list`, and any failure (auth, network, rate limit)
  surfaces through the same `plugin_task_failed` signal. The
  user can see "what's running" without separate plumbing.
- **Snapshots accumulate fast.** Approving N edits produces
  2N snapshots. ADR 006's `MAX_SNAPSHOTS = 20` cap keeps the
  user disk from filling, but the user-perceived "rollback to
  before this session" target gets evicted within ten edits.
  Documented as a follow-up.
- **The schema gets sent to Claude on every edit.** ~3KB extra
  per dispatch. We could cache an "I already showed you this
  schema" hint and rely on Claude's session, but the messages
  API doesn't preserve cross-call state. Acceptable cost.
- **Approve has a small race window.** Between the two
  `save_gdd` calls, the file on disk briefly equals the pre-
  state with refreshed timestamps. If another process reads
  during that window it sees the stale doc. For a single-user
  desktop app this is fine; if we ever go multi-process we'd
  need a real transactional write.

## Alternatives considered

- **Form-based edit instead of chat-edit.** Standard, predictable,
  cheaper to ship — but doesn't differentiate the orchestrator
  from any other JSON editor. Punted to a follow-up.
- **Stream Claude's response.** `task_stream_chunk` is part of
  `BasePlugin`'s contract. Streaming a partial GDD doesn't help
  here — we can't show a partial JSON document, and the parse
  only succeeds once the response is complete. Skip.
- **Send only a diff/patch instruction to Claude.** "Apply this
  patch" workflow. Worse for natural-language edits where the
  user doesn't think in patch-shape. Better for follow-up
  power-user flow.
- **Real per-line diff.** Considered hand-rolled LCS. Rejected
  for scope; side-by-side TextEdits + summary line is enough
  for MVP.
- **Roll back via the rollback button rather than auto-pre-
  snapshot.** That works, but only if the user remembered to
  save before chat-editing. Auto-pre-snapshot makes "I want my
  pre-edit GDD back" a one-click operation regardless of save
  hygiene.
- **Text-mode "are you sure?" before Approve.** The diff view
  IS the are-you-sure. Adding a second confirmation modal is
  belt-and-braces past the point of helpful.
- **Reject also writes a snapshot of the proposal "for science".**
  Tempting (record what Claude wanted to do even when the user
  said no) but pollutes the rollback target list. Skip.

## Follow-ups

- **Real per-line diff with red/green highlighting.** Either
  pull in a diff library or roll LCS by hand. The infrastructure
  (two TextEdits side-by-side) is in place.
- **Conversation-mode chat-edit.** Multi-turn refinement: "make
  the stealth mechanic more cinematic". Would need to keep the
  prior reply in context and feed it back to Claude.
- **"Test connection" probe before dispatching.** Currently a
  stale or wrong api_key shows up as a failure mid-flow. A
  pre-check would surface the same error before the user types
  the instruction.
- **Token / cost preview before Submit.** Estimate cost from
  prompt size + max_tokens and surface it inline. Already a
  follow-up from ADR 015's param editor.
- **Cross-reference integrity validator.** Claude can produce
  a `task` referencing a nonexistent `mech_*`. ADR 006 deferred
  this; chat-edit makes it more pressing.
- **Session-level snapshot pruning.** Right now MAX_SNAPSHOTS=20
  uses FIFO. A "preserve the snapshot tagged 'manually saved'"
  flag would let the user pin a known-good baseline.
- **Form-based edit alongside chat-edit.** Some changes
  ("rename one field") are faster to type by hand. The two
  edit modes can coexist.
- **Diff filtering.** "Only show entities that changed" view —
  useful when the GDD gets large and the side-by-side becomes
  unmanageable.
- **Streaming progress while Claude thinks.** A simple "thinking
  for X seconds" tick driven by `_process` would soften the
  perceived latency on long edits.
