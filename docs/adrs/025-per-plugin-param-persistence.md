# ADR 025: Per-plugin param persistence

- **Status:** Accepted
- **Date:** 2026-04-25

## Context

ADR 015 introduced the param_form: every plugin declares a JSON-Schema
shape via `get_param_schema()`, and the Generate form renders typed
inputs from it (CheckBox / SpinBox / OptionButton / LineEdit). The
form has worked well since Phase 15 — but every plugin selection
resets to the schema's defaults, even when the user has been
hammering the same `temperature: 0.0`, `max_tokens: 4096`,
`voice_id: <my favourite>` for a session.

Both ADR 015 and ADR 024 listed this as a follow-up:

> **ADR 015:** "Per-plugin param persistence — remember the
> last-used values for each plugin so they survive plugin switches
> and app restarts."
>
> **ADR 024:** "Per-plugin param persistence. Each plugin's
> last-used params (model, temperature, etc) belong in settings:
> `plugin.<name>.params.<field>`."

Phase 25 closes both. With SettingsManager (ADR 024) shipped, the
machinery is already in place — what's left is plumbing param_form
through it.

The decisions to make:

1. **Save when?** Every keystroke, on plugin selection change, or on
   submit?
2. **Save what?** Every field, only changed fields, only non-default
   fields?
3. **Restore when?** Every set_schema, only when the user actively
   opens the plugin, or never (push-only)?
4. **What about the empty-string skip rule from ADR 015?**
5. **How to keep backwards compatibility with existing tests?**

## Decision

1. **Save on submit.** `param_form.persist_values()` runs from
   `generate_form._on_submit` only AFTER `Orchestrator.generate`
   returns a non-empty task_id. Users committing to a real Generate
   click is the signal we want — accidental fiddling with a slider
   the user backs away from doesn't pollute their persisted
   preferences.

2. **Save every field that `get_values()` returns.** That filter
   already encodes "values worth saving":
   - `boolean` / `integer` / `number` / `enum-string` — always
     emitted.
   - `string` — emitted only if non-empty (ADR 015 rule preserved).
   We don't compare against schema default before writing. A user
   who sets `temperature: 1.0` (the schema default) and Generates is
   communicating "yes, exactly the default". Writing it back is
   harmless and makes the persisted value robust to future schema
   default changes.

3. **Restore on every `set_schema` call.** The form rebuilds whenever
   the dropdown selection changes (Phase 15 behaviour). On rebuild,
   for each property:
   - If `settings.has_value("plugin.<name>.params.<field>")` →
     override `default` with the saved value before passing to
     `_build_row`.
   - Else use the schema's own default.
   Effectively, persisted values DEPRECATE the schema default at
   render time.

4. **Empty-string skip rule preserved.** `get_values()` already
   omits empty strings; `persist_values` writes only what
   `get_values` returns. Saving an empty string would clobber the
   schema default for users who left a freeform LineEdit blank
   intentionally.

5. **Backwards-compatible signature.** `set_schema(schema)`
   (one arg) still works as in Phase 15. The new args are optional:
   `set_schema(schema, plugin_name = "", settings = null)`. Empty
   plugin_name OR null settings disables both the read and write
   paths. Existing tests pass schema-only and continue to work.

## Settings registry update

Adds a key family — a single ADR 024-style row would not capture
the per-plugin per-field shape, so we describe the family:

| Key family                           | Type           | Owner       | Notes                              |
|--------------------------------------|----------------|-------------|------------------------------------|
| `plugin.<name>.params.<field>`       | per-field      | param_form  | written on Generate submit, read on schema render |

Concrete examples that ship in Claude / ElevenLabs / Tripo today:
- `plugin.claude.params.max_tokens` (int)
- `plugin.claude.params.temperature` (float)
- `plugin.claude.params.model` (string from enum)
- `plugin.claude.params.system` (free-form string — empty values omitted)
- `plugin.elevenlabs.params.voice_id` (string)
- `plugin.elevenlabs.params.stability` (float)
- `plugin.tripo.params.style` (enum string)
- `plugin.tripo.params.texture` (bool)

## Consequences

- **Iterative prompting feels natural.** Set your favourite
  temperature once, every subsequent Generate uses it. Switch
  plugins — your Claude params stay yours, your Tripo params stay
  yours, no cross-pollination.
- **Saved values quietly DEPRECATE schema defaults at render time.**
  If a future plugin update changes a default (say, claude's
  default `max_tokens` from 1024 → 4096), users who'd persisted
  their preference for 1024 still see 1024 — which is what they
  asked for. They'll need to reset to default explicitly to pick
  up the new schema-side default. Documented as a follow-up.
- **No reset-to-default UI yet.** Users can't easily clear a
  persisted value back to "use the schema's choice". Settings
  store has `remove_value` so the plumbing exists; ADR 015 +
  follow-up calls for a UI button per row.
- **Tests get a no-op path.** A `set_schema(schema)` call without
  settings continues to work. Every existing test_param_form test
  passes unchanged; only the new persistence-specific tests
  exercise the new behaviour.
- **No cross-plugin namespace bleed.** The dotted key shape
  guarantees one plugin's `temperature` doesn't override another's.
  A defensive empty-plugin_name guard in
  `_setting_key_for` ensures no `plugin..params.X` keys can be
  written or read.
- **Persisted values survive type changes.** SettingsManager goes
  through JSON, which is type-tolerant: a persisted int survives
  even if the schema later widens to "number" (float). Same in
  reverse — a stored 0.5 read back into an integer SpinBox would
  truncate, but only if the schema actually changes a field type
  (rare).

## Alternatives considered

- **Save on every keystroke (debounced).** Considered. Rejected
  because (a) it commits values the user might be in the middle
  of editing, (b) it adds a debounce timer to the form layer, and
  (c) the submit-time write is the cleaner signal of intent.
- **Save only fields the user actually changed.** Required tracking
  initial values per row, like the credential editor does. Slightly
  more code, marginal benefit — the persisted values are tiny
  scalars, not megabytes of text.
- **Restore only the FIRST time the user opens a plugin.** That's
  what session-only memory would do. Persisted-across-launches is
  what users actually want.
- **Per-plugin Reset button.** Cosmetic, deferred. The follow-up.
- **Store params in CredentialStore.** Wrong layer — params aren't
  secrets and shouldn't gate on master-password unlock. The
  always-skip flag from Phase 24 already established that
  preferences live outside encryption.
- **Store params in plugin metadata.** Tempting (the plugin
  already exposes the schema). Rejected: the plugin is stateless
  by design, and re-registering it shouldn't lose the user's
  preferences.

## Follow-ups

- **Reset-to-default per field.** A small × button next to each
  row that removes the persisted value, falling back to the schema
  default on the next render. Already feasible:
  `settings.remove_value("plugin.<name>.params.<field>")`.
- **Bulk reset for one plugin.** "Restore claude's defaults" —
  iterates and removes every `plugin.claude.params.*` key.
  Settings UI follow-up.
- **Schema-default detection.** Surface "(default)" next to a row
  whose persisted value matches the schema default. Helps users
  spot when their persisted value is doing nothing.
- **Migration when a field disappears.** A future plugin update
  could remove a field; orphaned saved values stay in settings
  forever. Probably fine (they just don't render); a periodic
  cleanup pass could prune.
- **Migration when a field's type changes.** Today the saved
  value gets coerced via the SpinBox / CheckBox / etc; if it
  doesn't fit the new type, behaviour is undefined. Add explicit
  type-check + fallback to default.
- **Multiple param presets per plugin.** "Save as preset",
  "Load preset". Power-user feature; would need a UI overlay.
- **Param sharing across plugins.** Some users would want
  "temperature stays consistent across Claude AND a future
  competitor". Cross-plugin alias keys; defer.
