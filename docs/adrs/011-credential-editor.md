# ADR 011: Credential Editor — per-plugin API key management UI

- **Status:** Accepted
- **Date:** 2026-04-25

## Context

ADR 010 shipped a credential unlock UI: a master-password modal at app
startup that calls `Orchestrator.unlock_and_register(password)`. That
let users *load* saved credentials, but it didn't let them *manage*
those credentials from inside the app — adding, editing, or removing
api_keys still required either env vars or scripted calls into
`CredentialStore.set_credential(...)` from `tools/integration/`.

For a daily-driver / demo-ready experience we needed a UI surface where
the user can:

1. See which plugins have a saved api_key and which don't.
2. Enter or update an api_key for any plugin known to PluginRegistry.
3. Delete a saved api_key.
4. Toggle visibility of the key text (it's stored encrypted; the
   plaintext should still default to dots so over-the-shoulder users
   can't read it off the screen).

The reference design (image attached to the phase brief) shows a modal
titled "Manage Credentials" with one row per plugin: name + masked
input + show/hide toggle + delete button + Save / Cancel.

The decisions to make:

1. **Where does it live?** A separate panel? A page? A modal?
2. **What scope?** api_key only, or every key per plugin
   (`per_char_cost_usd`, `pricing`, etc.)?
3. **Save semantics?** Per-field auto-save, or batched on a Save
   button?
4. **What about the locked-store case?** A user with a locked store who
   clicks "Manage credentials" needs to do *something* useful, not just
   stare at a dialog they can't use.
5. **How does it surface the unlock flow?** Reuse the existing
   unlock_dialog or roll a second password prompt inside the editor?

## Decision

1. **Modal overlay, same shape as `unlock_dialog`.** Full-screen
   `Control` with a dim layer and a centered `PanelContainer`. Entry
   point is a "Manage credentials…" `Button` at the bottom of
   `plugin_panel`. The panel emits `manage_credentials_requested`;
   `main_shell` listens and calls `credential_editor.show_dialog()`.
   The panel never reaches for the editor by name — that signal hop
   keeps the sidebar testable in isolation.

2. **MVP scope: `api_key` only.** PluginRegistry entries declare other
   `config_keys` (`per_char_cost_usd`, `pricing`), but those are
   tuning knobs, not secrets — they need typed inputs (a number
   slider for the float, a structured editor for the dict). Bundling
   them into this phase would have meant designing a per-plugin
   schema renderer too. Punted to a follow-up. The store still
   accepts arbitrary keys; `tools/integration/` and unit tests can
   set them directly.

3. **Batched Save.** The user edits any number of rows; nothing
   persists until Save is pressed. Cancel discards everything,
   including pending Delete marks. We compare each row's current
   text to a `initial_value` snapshot taken at `show_dialog()` time
   and only call `set_credential` for rows that actually changed.
   Empty-after-edit is treated as `remove_credential` — saving `""`
   as an api_key would just be junk in the store.

4. **Locked-store branch shows a clear notice + an Unlock button.**
   On `show_dialog()` we ask `credential_store.is_unlocked()`. If
   false, we render no plugin rows — just a status message and a
   button labeled "Unlock". Pressing it emits `unlock_requested`,
   which `main_shell` wires to its existing `unlock_dialog`. Same
   handler chain as a fresh launch — `_on_dialog_unlocked` logs
   diagnostics, plugins re-register. Then the user can re-open the
   editor and see their saved keys.

5. **Save → re-register pass.** A row that just got an api_key for a
   previously-unconfigured plugin should flip its panel marker from
   `[unregistered]` to `[active]` without forcing a relaunch. After
   the editor emits `saved`, `main_shell` calls
   `Orchestrator.register_all_available()` and runs the diagnostic
   logger.

6. **Tests via internal handler hooks.** Same pattern as
   `test_unlock_dialog` and `test_ui_shell` — exposed `_rows`,
   `_on_save_pressed`, `_on_cancel_pressed`, `_on_delete_pressed`.
   Tests use a real `Orchestrator` + `CredentialStore` pre-unlocked
   at a unique `user://_test_creds_editor_*.enc` path so the real
   `user://credentials.enc` is never touched.

## Consequences

- **The CredentialStore is now usable from inside the app.** Users
  who never want to think about env vars can type their master
  password once at startup, manage keys from the sidebar, and never
  open `tools/integration/` again.
- **Plugin panel grows one button.** Layout-neutral but it's the
  panel's first interactive widget — until now it was pure status.
  The button-driven `manage_credentials_requested` signal sets the
  pattern for further actions ("Disable plugin", "Reload config",
  ...) we'll likely add later.
- **Editor isn't a static `.tscn`.** Same call as ADR 009: built
  programmatically in `_ready`. Rows are torn down and rebuilt on
  every `show_dialog()` so the editor always reflects the current
  store state — no stale snapshot.
- **Lambdas, not `.bind()`.** Per ADR 003. The Show/Hide toggle and
  per-row Delete button each capture their row's controls in a
  lambda closure; this is the same idiom PluginManager uses for
  signal forwarding.
- **`unlock_dialog` is reused as-is.** Editor's "Unlock" button does
  NOT prompt for a password itself — it surfaces the existing
  unlock_dialog. Two unlock flows would be two places to update next
  time auth changes.

## Alternatives considered

- **Inline editing in `plugin_panel`.** Rejected. The sidebar is
  ~220px wide and shows ItemList rows; cramming a text field, a
  toggle, and a delete button per plugin would have made it noisy
  even for the locked-state default render. A modal keeps the
  sidebar a status surface and the editor a focused tool.
- **One field per credential type, with typed inputs.** Tempting —
  it would have closed out the `per_char_cost_usd` / `pricing`
  follow-ups in this phase. Rejected because typed inputs need
  per-plugin schema awareness, and `BasePlugin.get_param_schema()`
  was designed for *runtime params*, not credentials. Designing a
  separate "credential schema" surface is its own decision worth
  its own ADR.
- **Per-field auto-save (no Save button).** Rejected. A typo
  midway through a 40-char api_key would persist immediately as a
  broken credential, and the user would have to re-paste cleanly.
  Batched Save also makes Cancel meaningful — discard staged edits
  in one click.
- **Reload the whole `credential_store` on `show_dialog`.** No need —
  the store is the live in-memory copy. We just re-read its
  `get_credential` for each plugin to refresh `initial_value`. This
  also gives us the desired "external mutation reflected on
  re-open" property essentially for free.
- **Show a second password prompt inside the editor (locked
  branch).** Rejected. We already have `unlock_dialog` and its tests;
  forking the auth surface would mean two code paths to keep in
  sync next time we change anything about unlock (e.g. when we add
  OS keyring support).

## Follow-ups

- **Typed editors for non-secret keys.** `claude.pricing`,
  `elevenlabs.per_char_cost_usd`. These need a per-plugin form
  schema and per-type widgets (number, dict). One follow-up phase.
- **"Test connection" button per row.** A cheap probe — Claude:
  1-token messages call; ElevenLabs: voices list; Tripo: account
  endpoint. Surfaces auth failures *immediately* instead of on the
  next real generation. Needs a per-plugin `test_credentials()`
  method on `BasePlugin`.
- **Lock button.** Already on the ADR 010 follow-up list. The
  editor would gain a "Lock now" button next to Save that calls
  `CredentialStore.lock()` and re-shows the unlock_dialog.
- **Strength meter / minimum length on master password.** A
  separate UX concern from this phase but worth doing alongside the
  Lock button.
- **Read-only "last saved" timestamp per row.** Helpful auditing
  affordance once we have multiple machines / multiple stores.
  Cheap to add — `_persist` already touches mtime on the file.
