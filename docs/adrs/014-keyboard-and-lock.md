# ADR 014: Keyboard shortcuts + Lock Now button

- **Status:** Accepted
- **Date:** 2026-04-25

## Context

After Phases 10-13 the daily-driver flow worked end-to-end through
mouse clicks: unlock → manage credentials → generate → preview → check
budget. But two ergonomic gaps remained:

1. **Submitting a prompt required a mouse trip to the Generate
   button.** Heads-down prompting wants Ctrl+Enter from the text
   field.
2. **There was no way to lock the credential store mid-session.**
   ADR 010 docked this as a follow-up — useful on shared machines, or
   when the user steps away with secrets unlocked in memory.
3. **Overlays could only be dismissed by clicking Close / Cancel /
   Skip.** Esc is the desktop convention.

The decisions to make:

1. **Submit shortcut: Ctrl+Enter, plain Enter, or both?**
2. **Where does the Lock Now button live?** Header bar (we don't have
   one), the credential editor, the cost footer, somewhere else?
3. **Esc semantics per overlay** — same handler as the Close button,
   or a softer "discard" affordance?
4. **`_input` vs `_unhandled_input` vs `gui_input` for the keybinds?**
5. **How do we test keyboard input headlessly?**

## Decision

1. **Ctrl+Enter (or Cmd+Enter on macOS) submits.** Plain Enter
   inserts a newline — TextEdit's default. Subscript: a real
   `command_or_control` shortcut would be cleaner, but we wire it
   manually inside `_on_prompt_input` because the form's TextEdit
   is constructed in code (no scene-tree InputEventAction
   plumbing). The handler accepts both `Ctrl+Enter` and the macOS
   `Cmd+Enter` via `key.meta_pressed`.

2. **Lock Now lives in the cost footer.** Two reasons: (a) the
   footer is the only persistent affordance that's always visible
   regardless of which overlay is up; (b) we already added the
   Budget HUD button there in Phase 13, so a second status-bar
   button reuses the same pattern. Click → emit `lock_requested`
   signal; main_shell wires that to
   `credential_store.lock()` + `unlock_dialog.show_dialog()`. The
   footer doesn't drive credential state itself — single code
   path for unlock.

3. **Esc maps to each overlay's "soft dismiss" handler.**
   - `unlock_dialog` → `_on_skip_pressed` (acts like Skip).
   - `credential_editor` → `_on_cancel_pressed` (discards staged
     edits — Save still requires an explicit click).
   - `asset_preview` → `_on_close_pressed`.
   - `budget_hud` → `_on_close_pressed`.
   In every case Esc behaves like the *less destructive* of the
   available options: discard, never apply.

4. **`_unhandled_input(event)` per overlay, gated on
   `if not visible: return`.** This is the shape the engine offers
   for global-but-overrideable keyboard handling. We deliberately
   don't use `_input` because that would intercept events even when
   the overlay is hidden, which can clash with whatever else has
   focus. `gui_input` would only fire when the overlay specifically
   has focus, which it usually doesn't (focus goes to the inner
   LineEdit / TextEdit / Button). `_unhandled_input` lands events
   that no Control has consumed yet — exactly what an overlay's
   "global Esc" should hook.

   For the Ctrl+Enter shortcut on the prompt, we DO use
   `gui_input` because the user is, by definition, focused on the
   prompt while typing. Scoping the bind to the prompt's events
   prevents it from firing from anywhere else.

5. **Tests construct synthetic `InputEventKey` objects and call
   the handlers directly.** Same idiom as the rest of our UI
   tests — never simulate clicks. `InputEventKey.new()` plus
   `keycode`, `pressed`, `ctrl_pressed` is a 4-line fixture that
   exercises the production code path.

## Consequences

- **Daily-driver loop is keyboard-friendly.** Type prompt →
  Ctrl+Enter → result. Esc dismisses dialogs without rotating
  the mouse over to a button. Both wins compound during
  iterative prompting.
- **Locking is a first-class action.** The user can step away
  from a shared machine with the store locked, instead of
  exiting the app entirely.
- **Esc can NOT save.** A user who types a new credential into
  the editor and hits Esc loses the entry. We considered making
  Esc on `credential_editor` ask for confirmation but decided
  the consistent "Esc = discard" rule across all four overlays
  is simpler to teach than per-overlay variants. Save still
  requires a deliberate click.
- **No global hotkeys.** We didn't add app-level shortcuts like
  Ctrl+K to focus the prompt, Ctrl+, to open settings, etc. That
  belongs in a future "shortcuts" pass once we have more than
  one panel competing for the same key.
- **One more `_unhandled_input` override per overlay.** Four
  added handlers. Each one is six lines. They're independent —
  no cross-overlay coordination needed because each gates on
  `visible`.

## Alternatives considered

- **Plain Enter submits, Shift+Enter newlines.** Standard chat-app
  pattern. Rejected: TextEdit is a multiline field by design here
  (long prompts wrap), so flipping the convention would feel
  surprising. We can revisit if the prompt becomes a single-line
  LineEdit.
- **Lock Now as its own header bar.** We don't have a header
  bar. Adding one for one button felt premature. The footer
  already exists.
- **Esc on `credential_editor` saves staged edits.** That's how
  some "auto-save" apps behave. Rejected — the editor is
  modal-with-explicit-Save, and Esc-to-save would surprise users
  who hit it expecting "discard".
- **Use the InputMap action system (`ui_cancel`).** Cleaner in
  principle: register an action, bind it once, every overlay
  listens. Rejected for this phase because the action would need
  per-overlay handlers anyway (different methods to call), the
  setup overhead doesn't pay back, and adding to InputMap from
  code is verbose. If we end up with a dozen shortcuts, this
  becomes the right move.
- **Actually simulate mouse clicks in tests.** Same call as ADR
  010 / 011 / 012 — internal handlers as test seams.

## Follow-ups

- **Arrow-key nav inside `task_list`.** Up/Down moves a focus
  highlight; Enter shows task details. Skipped this phase because
  task rows are built from a list of plugin-task-progress events,
  not from a stable index, and focus management without a real
  display server is fiddly.
- **Ctrl+/ to focus the prompt.** Once we have a header bar or a
  command palette this becomes natural.
- **Tab navigation between panels.** Godot honours focus_neighbor
  if we set it; sketching this once we have more interactive
  elements per panel.
- **Confirm-on-Esc for in-progress edits.** A "you have unsaved
  changes" prompt on `credential_editor` Esc would protect users
  who touch the wrong key. Worth doing once we add more long-form
  edit surfaces (param editor, GDD editor, ...).
- **Keyboard discovery affordance.** A footer hint or a `?`
  overlay that lists every shortcut. Today we rely on tooltips
  for the buttons, which is enough for the three shortcuts we
  ship.
- **Bind `command_or_control` via InputMap action.** Avoids the
  manual macOS Cmd-vs-Ctrl branch in `_on_prompt_input`.
