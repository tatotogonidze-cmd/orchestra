# ADR 041: Markdown copy-to-clipboard

- **Status:** Accepted
- **Date:** 2026-05-01

## Context

ADR 034 shipped Markdown export as a disk write. The user clicks
"Export .md" → a `.md` file lands next to the GDD JSON. That covers
the "save it for later" case but not the "I want to paste this into
Slack right now" case.

The first follow-up listed in ADR 034:

> **Copy to clipboard.** A `Copy Markdown` button next to Export.
> `DisplayServer.clipboard_set(...)`. Trivial when the converter
> is a pure function.

The converter (`gdd_manager.export_to_markdown`) is already pure;
this phase wires it to the clipboard.

The decisions to make:

1. **Separate button vs Export menu (Export → File / Export →
   Clipboard)?**
2. **Emit a signal alongside the clipboard write, or just write
   silently?**
3. **What about non-text deliverables (PDF, HTML)?**

## Decision

1. **Separate button** — `Copy .md` next to `Export .md`. A menu
   would mean an extra click for both paths (open menu → pick
   destination). Two buttons trade vertical-real-estate for
   immediate access. The path row already houses Load / Edit /
   Export / Create starter / Copy — five buttons fits, and they
   share a coherent "things you do with this GDD" semantic group.

2. **Emit `markdown_copied(text)` after the clipboard write.**
   - `DisplayServer.clipboard_set` returns `void` and is a no-op
     in headless contexts. We need an alternate observable for
     tests. The signal is that observable.
   - Future consumers (toast notifications, recent-copies
     history, "what did I last share?" surfaces) get a clean
     hook without re-running the converter.
   - The signal payload is the actual markdown so consumers
     don't need to recompute.

3. **Markdown only for now.** PDF / HTML follow-ups are listed in
   ADR 034 but neither has the "I want to paste this immediately"
   workflow that copy-to-clipboard solves. Adding them as
   alternative copy targets would need format-picker UI; that's
   scope for whichever ADR adds the format itself.

## UX

```
Path: [user://gdd.json] [Load] [Edit] [Export .md] [Copy .md] [Create starter]
```

Status feedback: `Copied 2,847 chars to clipboard` — concrete
confirmation that the action ran.

## Behaviour

- **Same gating as Export.** Disabled when no GDD is loaded —
  there's nothing to copy. Enabled the instant a GDD lands.
- **Idempotent.** Clicking Copy ten times overwrites the
  clipboard ten times with the same payload. No accumulation,
  no "what did I last copy?" state inside the panel.
- **Emits even on empty markdown.** If a future GDD shape is
  somehow legitimately empty, the signal still fires with `""`
  so observers can react. Tests use this property to verify
  payload structure.

## Consequences

- **Markdown export now has both writes.** Disk-bound and
  clipboard-bound flows share `export_to_markdown`. Future
  format additions (PDF, HTML) will likely follow the same
  twin-button pattern.
- **`markdown_copied` is the third Phase-34-family signal**
  alongside the existing `gdd_loaded` / `edit_saved` etc.
  Consumers that listen for "user did a thing with the GDD"
  now have a more complete signal set.
- **Headless test runs work uniformly.** `DisplayServer.
  clipboard_set` doesn't error in headless mode (it's a no-op),
  and the signal is the only observable the tests rely on.
- **Path row now has five buttons.** Visual density edges
  upward; if we ever add a sixth, a dropdown / context menu
  refactor becomes the right call.

## Alternatives considered

- **Right-click context menu on the Export button** ("Export
  to file" / "Copy to clipboard"). Rejected — discoverability
  is poor, and right-click conventions vary by platform.
- **Single Export button that also copies as a side-effect.**
  Rejected — surprising. Users who want one but not the other
  have no way to opt out.
- **Toast notification UI.** Considered. Skipped for MVP — the
  status label below the path row already provides confirmation.
  A real toast system can subscribe to `markdown_copied` later.
- **Persist last-copied text** in settings (so the user can
  "copy again" without re-clicking). Rejected — clipboard is
  ephemeral by convention; persisting it crosses lines.
- **Verify clipboard contents in tests** via
  `DisplayServer.clipboard_get`. Rejected — headless behaviour
  is platform-dependent. Signal-based observation is reliable
  on every platform.

## Settings registry

No new settings keys.

## Follow-ups

- **Toast UI for the markdown_copied signal.** A small
  status-corner notification ("Copied!") that fades after a
  couple of seconds. Pairs with a future toast infrastructure
  pass.
- **Copy as JSON.** Same pattern: button → clipboard → signal.
  Useful for paste-into-issue workflows where the user wants
  the structured data, not the rendered prose.
- **Copy as HTML.** Pandoc-style markdown→HTML conversion in
  the converter, then the same dual-button (file + clipboard)
  pattern. Pairs with ADR 034's "Export to PDF / HTML"
  follow-up.
- **Copy fragment.** Picker that lets the user copy only one
  section (mechanics / characters / etc) rather than the full
  document. Pairs with ADR 034's per-entity-type filter
  follow-up.
- **Recent-copies log.** Subscribe to `markdown_copied` and
  keep the last N payloads in memory (or settings) for "paste
  a previous version" workflows.
