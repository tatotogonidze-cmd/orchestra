# ADR 010: Credential unlock UI

- **Status:** Accepted
- **Date:** 2026-04-25

## Context

The CredentialStore has shipped (ADR 002): an AES-256-CBC-encrypted
key/value file at `user://credentials.enc`, opened by a master password
held in memory only while unlocked. The Orchestrator already exposes
`unlock_and_register(master_password)` — it unlocks the store and calls
`register_all_available()` in one step.

Until now, the only way to drive the unlock at runtime was env vars. That
worked for smoke tests and CI, but it was a poor daily-driver experience:

- Anyone who launched the editor outside their authenticated shell saw
  zero plugins register, with no obvious recourse.
- Saved credentials were inaccessible from the UI — the encrypted store
  may as well not have existed for non-CLI users.
- ADR 009 explicitly punted on this with a follow-up: "Credential unlock
  UX. A modal dialog that calls `Orchestrator.unlock_and_register(password)`
  instead of requiring env vars."

The decisions to make were:

1. **Modal vs non-modal?** Block all UI on unlock, or offer it as an
   optional sidebar?
2. **First-run UX?** A separate "create your store" wizard, or fold it
   into the same dialog?
3. **Skip path?** Do we *force* a master password, or allow users who
   only ever want env-vars to bypass it?
4. **Credential editor?** Should this phase ship a CRUD UI for adding,
   editing, removing keys per plugin, or punt that to a later phase?

## Decision

1. **Full-screen modal on app startup.** A `Control` overlay with a
   semi-opaque dim layer and a centered `PanelContainer`. It sits on top
   of the panel HBox and absorbs mouse input until dismissed. This
   matches user expectation that "do I want to load saved keys?" is the
   first question, not a sidebar option to be discovered later.

2. **One dialog for both first-run and existing-store cases.** The
   helper text under the header swaps based on whether
   `user://credentials.enc` exists. CredentialStore.unlock already
   creates the file on first write, so the underlying flow is identical
   either way — only the explanation changes. This is simpler than a
   two-stage wizard and avoids a coupling between the dialog and a
   non-existent "create store" code path.

3. **Skip is supported.** A second button next to Unlock dismisses the
   dialog without unlocking the store. The shell's `_on_dialog_skipped`
   handler then calls `register_all_available()` so env-var-only users
   still get their plugins. This preserves the smoke-test / CI flow
   verbatim — anyone with `ANTHROPIC_API_KEY` (etc.) exported can keep
   bypassing the credential store.

4. **No credential editor in this phase.** Adding/removing/editing keys
   inside the app is real work — input validation, plugin-specific
   schemas, persistence, undo. Punted to a follow-up. For now users
   manage credentials by either:
   - Setting env vars (the original path), or
   - Calling `CredentialStore.set_credential(...)` from a tools/integration
     script and then unlocking via this dialog.

5. **Dialog is testable through internal handler hooks.** GUT runs
   headless and can't reliably synthesize mouse clicks, so the dialog
   exposes `_on_unlock_pressed`, `_on_skip_pressed`, and
   `_on_password_submitted` as test seams. Tests drive these directly
   and observe `unlocked` / `skipped` signals.

## Consequences

- **No daily-driver dependency on env vars.** Users can launch the
  editor however they want, type their master password, and get back to
  saved credentials. Env vars become a CI / smoke-test convenience, not
  a daily requirement.
- **`scripts/ui/main_shell.gd` no longer auto-registers immediately on
  startup.** It now waits for the dialog to resolve (Unlock or Skip)
  before registering plugins. Existing GUT tests that `bind_orchestrator`
  themselves are unaffected, because they don't go through the autoload
  branch in `_ready`.
- **Master password stays in `CredentialStore`.** The dialog forwards
  the typed password to `Orchestrator.unlock_and_register` and does NOT
  retain it. After the call returns we don't even hold a reference; the
  field text is overwritten on the next render.
- **Skip is a real escape hatch.** A user who never wants to deal with
  the encrypted store can dismiss the dialog every launch. We considered
  remembering "always skip" in a settings flag, but that's a follow-up
  — for MVP, one click on Skip is cheap.
- **`UnlockDialogScript.store_path` is overrideable.** Tests use this to
  point the helper-text branch detection at a known-existent or
  known-nonexistent path so they can verify both messages without
  touching the user's real `user://credentials.enc`.

## Alternatives considered

- **Force unlock (no Skip).** Rejected. Smoke tests, CI, and users who
  never opt into the encrypted store would have to enter a sentinel
  password every launch. The friction wasn't worth the marginal "you
  must use the store" enforcement.
- **Two dialogs (Create vs Unlock).** Rejected. The flows differ only
  in copy. CredentialStore.unlock already handles both transparently,
  so two UIs would be duplicating presentation for no behavior win.
- **Offer the unlock as a sidebar button instead of a modal.** Rejected.
  The unlock is the *first* decision a user makes — sidebar buttons get
  ignored. A modal forces the answer up-front, then never bothers them
  again that session.
- **Ship the credential editor in the same phase.** Rejected for scope.
  An editor needs plugin-specific schemas (list of expected keys per
  plugin, validation per key), confirmation dialogs for removal,
  ideally a "test connection" affordance. It's a real feature in its
  own right; bundling it here would have delayed unlock.
- **Synthesize input events for headless tests.** Considered: GUT can
  send `InputEvent`s. Rejected because the resulting tests are flaky —
  they depend on focus, control geometry, and the input-event pipeline,
  none of which work reliably without a real display server. Internal
  handler hooks are the codebase's existing pattern (used in
  `test_ui_shell.gd`).

## Follow-ups

- **Credential editor.** Per-plugin CRUD: `plugin_panel` grows a "Manage
  keys…" affordance that opens an editor showing every key from
  `plugin.get_param_schema()`. Save persists via `CredentialStore.set_credential`,
  delete via `remove_credential`. Should also offer a "test connection"
  button that runs a cheap probe through the plugin (e.g. a 1-token
  generation for Claude).
- **Lock button.** A small "Lock" affordance in the header that calls
  `CredentialStore.lock()` and re-shows the unlock dialog. Useful for
  long-lived sessions on shared machines. Currently a session ends only
  when the app quits.
- **OS keyring integration.** ADR 002 already calls this out — replace
  the in-memory master password with a system keyring lookup
  (DPAPI on Windows, libsecret on Linux, Keychain on macOS) so users
  don't retype it every launch. Gated behind a future setting.
- **"Always skip" preference.** Persist a flag in settings so users who
  exclusively use env-vars don't see the dialog at all after the first
  Skip. Cheap to add once we have a settings store.
- **Lockout / rate limit.** A wrong-password retry counter to slow
  brute-force attempts. Low priority while the store sits on the user's
  own disk, but worth thinking about for any future remote-store
  variants.
