# ADR 029: Auto-fix dangling refs + probe-with-typed-key

- **Status:** Accepted
- **Date:** 2026-04-25

## Context

Two follow-ups from earlier ADRs sat unfixed:

1. **ADR 019** shipped a cross-reference integrity validator that
   surfaces dangling-id errors at load time. The validator only
   reported them — fixing them required either chat-edit, form-
   edit (deleting the whole offending field by hand), or editing
   the JSON file directly. ADR 019 listed an "Auto-fix for
   dangling refs" follow-up.
2. **ADR 022** shipped a per-credential Test button that probes
   the registered plugin's saved api_key. Users who copy-pasted a
   new key and clicked Test got a probe of the OLD saved key —
   misleading. ADR 022 listed "Probe-with-typed-key" as the
   follow-up.

Phase 29 closes both. Each is small individually; bundled, they
fit one phase.

The decisions to make:

1. **Auto-fix scope.** Bulk cleanup of every dangling ref, or
   surface per-error fix UI?
2. **Auto-fix safety.** Do we save the cleaned GDD automatically,
   or just preview the diff and ask?
3. **Probe-with-typed-key strategy.** Spin up a temp plugin
   instance, or override the registered plugin's api_key
   temporarily?
4. **What about plugins with no `api_key` field?** (Mock plugins.)
5. **How do we test these flows headlessly?**

## Decision

1. **Bulk auto-fix.** A single button "Auto-fix (N)" reads the
   `removed_count` from a dry-run of `clean_dangling_references`
   and offers a one-click cleanup. We don't surface per-error
   fix UI because:
   - Per-error UI multiplies the validation rendering surface
     (each error needs a button + handler).
   - The fix-action is uniform: "remove this dangling reference".
     Walking every reference field once is the same work as
     handling one error.
   - Users who want surgical control can chat-edit / form-edit
     specific records.

2. **Auto-fix saves immediately.** One click runs `clean_dangling_references`
   then `save_gdd` in sequence. The saved GDD is a fresh
   snapshot (ADR 006), so the user can roll back if the auto-fix
   was wrong. The alternative ("preview the diff and ask")
   replicates chat-edit's Approve/Reject flow for a strictly
   simpler operation; the snapshot infrastructure already
   provides the safety net.

3. **Override + restore the registered plugin's `api_key`.**
   Strategy:
   - Read the typed value from the row's LineEdit.
   - If non-empty AND the plugin has an `api_key` field AND the
     typed value differs from saved: store the saved value,
     write the typed value to `plugin.api_key`, run
     `test_connection()`, restore.
   - The registered plugin's state is NEVER permanently mutated
     by a Test click. The user has to actually Save to persist.
   Rejected the alternative ("spin up a temp plugin instance via
   PluginRegistry") because:
   - It needs PluginRegistry instantiation in the UI layer.
   - It pulls in test-injection complexity (factory pattern).
   - It doesn't actually exercise the same code path the user
     will see post-Save (where the registered plugin is the one
     being probed).

4. **Plugins without `api_key` ignore the typed value.** Mock
   plugins (no `api_key` field) skip the override branch entirely
   via the `"api_key" in plugin` guard — they don't auth against
   anything anyway, so the typed value is meaningless. Tests use
   the FakeCredentialPlugin which DOES declare `api_key` so the
   override path is exercised.

5. **Tests for both flows use real implementations + observable
   state.** clean_dangling_references is pure: tests verify
   `removed_count` + cleaned-GDD shape against hand-crafted
   fixtures. The Auto-fix button click is end-to-end (load, click,
   re-load from disk, assert clean). Probe-with-typed-key uses
   FakeCredentialPlugin's `_key_seen_during_test` field — the
   fake records what api_key it had at test_connection time, so
   tests can assert "the typed value reached the plugin" without
   running any real HTTP.

## Consequences

- **Dangling refs become a one-click problem.** Whether they
  came from a chat-edit gone wrong, a form-edit rename without
  reference update, or an external script, the user clicks
  Auto-fix and the GDD revalidates clean.
- **Snapshot history grows by one.** Auto-fix saves through
  `save_gdd`, which creates a snapshot. ADR 006's
  `MAX_SNAPSHOTS = 20` cap eventually evicts old ones; users
  who frequently auto-fix will see their pre-fix snapshots
  rotate out faster than users who don't.
- **Test button is now meaningful for new keys.** Copy-paste
  a new api_key from the provider's website, click Test, see
  whether it works — without going through the Save dance.
- **`api_key` is now part of the plugin contract surface.**
  Real plugins all already declared it (claude_plugin /
  elevenlabs_plugin / tripo_plugin); the new probe path
  EXPECTS this. Future plugins that auth via api_key should
  follow suit. Plugins authing via OAuth tokens etc. need
  their own probe path; documented as a follow-up.
- **No mutation of registered plugin state.** Override +
  restore is bounded to the duration of the await. Concurrent
  dispatches (rare in practice) would race; we accept that
  risk because the Test button is a deliberate user action.
- **The dialogue.character_id case erases the key.** A
  dangling required scalar leaves the record invalid in
  schema terms (missing required field). validate() will
  flag it next time. The user fixes it explicitly via form-
  edit or chat-edit.

## Alternatives considered

- **Per-error "Fix this" affordance.** Each validation error
  gets a small × button to remove that specific reference.
  Rejected: more UI surface, more wiring, no win for the
  90% case where users want everything cleaned up at once.
- **Auto-fix as preview-then-approve flow.** Like chat-edit's
  Approve/Reject. Considered. Rejected: the operation is
  strictly safe (only removes refs that point at non-existent
  ids); a snapshot makes rollback trivial; the diff would just
  show an array shrinking by one.
- **Spin up temp plugin via PluginRegistry for probe.**
  Discussed above. Cleaner separation but more code, requires
  test injection. The override-restore approach is shorter.
- **Re-initialize the registered plugin with the typed value
  permanently.** Tempting (saves a Save click) but surprising:
  Test + Cancel would persist the change without an explicit
  user Save. Confusing UX.
- **Bypass the plugin entirely and probe via raw HTTP.**
  Would mean duplicating the probe URL / headers logic outside
  the plugin. Rejected: plugins own their endpoint shapes.
- **Only show the Auto-fix button when the user explicitly
  hits validate.** Rejected: validation runs on every load
  already; the button surfacing on-load is the natural UX.

## Follow-ups

- **Granular auto-fix.** Per-error × buttons in addition to
  the bulk button. For users who want to fix some but not
  all dangling refs.
- **Auto-fix preview.** A "Show changes" affordance that
  surfaces the cleaned-vs-current diff before the click
  actually saves. Pairs with the chat-edit diff renderer
  (ADR 020).
- **Probe with multiple keys.** A "rotate" affordance that
  tests several pasted candidate keys in sequence and saves
  the first one that passes. Useful for users who have
  multiple keys (dev / prod / etc).
- **Probe non-api-key plugins.** OAuth tokens, refresh tokens,
  multi-field credentials. A `BasePlugin.test_credentials(config)`
  method that takes the typed config and probes — more
  general than the current api_key-specific override.
- **"What would change" preview before auto-fix.** A
  diff-style summary inline with the Auto-fix button so the
  user knows which refs are about to get pruned.
- **Cascade-on-delete-asset.** Hook `asset_deleted` events
  to scene_manager + gdd_manager auto-cleanup. Then dangling
  refs never accumulate from in-app actions, only from
  external edits.
