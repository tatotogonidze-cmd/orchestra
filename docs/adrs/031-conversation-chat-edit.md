# ADR 031: Conversation-mode chat-edit — multi-turn refinement

- **Status:** Accepted
- **Date:** 2026-04-25

## Context

ADR 017 shipped single-shot chat-edit: type an instruction, get a
proposal, Approve / Reject. ADR 017 explicitly punted the natural
follow-up:

> **Conversation-mode chat-edit.** Multi-turn refinement: "make
> the stealth mechanic more cinematic". Would need to keep the
> prior reply in context and feed it back to Claude.

A real iterative editing flow needs to support "ok I see what you
did, now tweak it like THIS". Approving every intermediate
proposal as a saved snapshot is wrong UX — the user wants
several rapid refinements to converge on what they want, then
ONE Approve.

The decisions to make:

1. **What carries the conversation context?** A `messages: []`
   array sent through Claude's API, or the cumulative-state
   approach (each turn replaces the proposal entirely)?
2. **When does the conversation end?** Approve, Reject, or both?
3. **Submit-button policy.** Currently disabled during PREVIEW —
   the user must Approve / Reject before sending more. Phase 31
   needs Submit enabled in PREVIEW.
4. **What does "refinement" look like to Claude?** Same prompt
   shape every turn, just with the latest proposal as the
   document?
5. **How do we surface "you're in turn N"?** Status banner,
   conversation history widget, both?

## Decision

1. **Cumulative state approach: each refinement replaces the
   proposal entirely.** Claude gets the LATEST proposed GDD
   (not the saved baseline) plus the new instruction. No
   conversation history sent through the API — the document
   itself carries all the cumulative state.
   Reasons:
   - Simpler. No plugin contract changes (the prompt is still
     a single string).
   - Token-efficient. Conversation history would grow linearly
     with turn count; cumulative state stays bounded by the
     GDD size.
   - Matches the user's mental model: "the GDD now looks like
     X; tweak it to Y" rather than "remember the conversation
     so far AND now tweak".

2. **Conversation ends on Approve OR Reject.** Both reset the
   turn counter to 0 via `_clear_pending_edit`. A subsequent
   Submit starts a fresh conversation at turn 1, basing on
   the saved baseline. This matches the snapshot semantics:
   only Approve writes; Reject discards everything from the
   conversation.

3. **Submit stays enabled in PREVIEW.** The Phase 17 policy
   ("disabled while a preview is pending") forced Approve /
   Reject before any further iteration. Phase 31 inverts:
   - In-flight (mid-dispatch): disabled (avoid double-fire).
   - PREVIEW (proposal landed, awaiting user decision):
     ENABLED — Submit again to refine, Approve to accept,
     Reject to discard.
   - IDLE (no proposal, no in-flight): enabled.

4. **Refinement uses `_resolve_chat_edit_basis`.** Helper:
   ```gdscript
   func _resolve_chat_edit_basis() -> Dictionary:
       if not _pending_gdd.is_empty():
           return _pending_gdd
       return _current_gdd
   ```
   First turn → `_current_gdd` (saved baseline).
   Refinement turns → `_pending_gdd` (latest proposal).
   The same `_compose_chat_edit_prompt` runs on whichever
   basis is current. Claude sees a fresh single-shot prompt
   each turn but with the cumulative document.

5. **Turn counter in the status banner.** "turn 2: editing… task X"
   while in flight, "preview shown — type a refinement and Submit, or
   Approve / Reject" in PREVIEW. No conversation-history widget for
   MVP — the user can see the diff preview to know what's been
   accumulated.

## Consequences

- **Iterative editing feels natural.** "Add stealth → make it
  cinematic → tone down the special effects → keep that, just
  rename it" — four turns, one final Approve, one snapshot.
  Pre-Phase-31 this would have been four Approves and four
  snapshots in the timeline, polluting the rollback target list.
- **Snapshot history stays clean.** Only deliberate Approves
  produce snapshots. Refinement turns don't pollute the
  rollback timeline.
- **No plugin changes.** ClaudePlugin still receives a single
  prompt; nothing in `BasePlugin` or `PluginManager` cares about
  conversation state.
- **Refinement is bounded by document size, not turn count.**
  An hour-long refinement session over a small GDD costs the
  same per-turn as a single-shot edit. Token usage is roughly
  constant.
- **The user can see they're in a refinement.** The "turn N"
  prefix in the status banner is the cue. After Approve, status
  flips to "applied — saved as snapshot vM".
- **Reject is destructive across the whole session.** Once the
  user clicks Reject, all N turns of refinement go away. We
  don't offer "undo last turn only" — the user can re-Submit
  the previous instruction if they really wanted it.
  Documented as a follow-up.
- **Plugin's task_failed handler still works.** A network
  error mid-refinement clears `_chat_edit_task_id` and lets the
  user retry. The turn counter still increments on retry — we
  don't try to "subtract a failed turn" from the count, because
  the cost was incurred (Claude rejected the dispatch).

## Alternatives considered

- **True messages-API conversation history.** Build a
  `messages: [{role, content}, ...]` Array and pass it through
  `params` to ClaudePlugin. Plugin would need to recognize the
  override and use the array instead of synthesizing one from
  `prompt`. Cleaner protocol but more code, more tokens, no
  practical benefit for our use case (cumulative state IS the
  convergent goal).
- **Auto-Approve after N turns.** Forcing the user to converge
  is wrong UX; the user explicitly DECIDES when to commit.
- **Disable Submit again after a refinement until parse lands.**
  We do — `in_flight` disables it. The change is that PREVIEW
  state alone doesn't.
- **Pop a confirmation dialog before Reject when conversation_turn > 1.**
  Considered (the user might lose multiple turns of work).
  Rejected because it adds friction to the common case (just
  start over). Could be a per-user setting.
- **Let the user "undo last turn only".** Roll the proposed
  GDD back to the previous turn's proposal. Punted to a
  follow-up — needs a turn-by-turn cache; not worth the
  complexity for MVP.
- **Show a turn list inline.** A small history widget showing
  each turn's instruction. Useful but more UI work. Status
  banner with the turn number is enough for MVP.

## Follow-ups

- **Per-turn rollback.** "Undo last turn" reverts
  `_pending_gdd` to the prior turn's proposal. Requires a
  per-turn cache (`Array[Dictionary]`).
- **Conversation history widget.** A compact list of past
  instructions in this session, alongside the diff preview.
  Helps the user see what they've asked for.
- **Auto-truncate on schema overflow.** If `_pending_gdd`
  grows past the model's context window, surface a warning
  and offer to "compact" by Approving + saving a snapshot
  mid-session.
- **True messages-API path.** When/if we want full
  conversation context (e.g., for deeper "remember what I
  said three turns ago"). Plugin contract gains a
  `params.messages` override.
- **Reject confirmation for long sessions.** "You're about
  to discard 5 turns of refinement — sure?". Settings-gated.
- **Turn-by-turn cost preview.** Surface the cost of the
  refinement in flight. Pairs with cost_tracker's existing
  warnings.
