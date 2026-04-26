# ADR 015: Plugin parameter editor — schema-driven typed inputs

- **Status:** Accepted
- **Date:** 2026-04-25

## Context

Every `BasePlugin` subclass already exposes `get_param_schema() ->
Dictionary` — Claude's covers model / max_tokens / temperature / system
/ stop_sequences, ElevenLabs's covers voice_id / model_id / stability /
similarity_boost / style / speaker_boost / output_format, Tripo's
covers style / texture / pbr / negative_prompt. The mock plugins
publish their own schemas as well.

Until now, none of those knobs were reachable from the UI. The
generate form sent `params = {}` for every dispatch. That meant:

- The user couldn't pick a Claude model — every call defaulted to
  `claude-sonnet-4-5`.
- Tripo always used `style: "realistic"` and `texture: true` because
  those were the schema defaults.
- A power user who wanted determinism with `temperature: 0.0` had no
  way to express that.

ADR 009 explicitly listed this as a follow-up: *"Plugin-specific param
editor. Read `plugin.get_param_schema()` and render typed inputs
(enum → dropdown, number → slider, etc)."*

The decisions to make:

1. **Where does the editor live?** Inline under the prompt, or in a
   modal "Params…" overlay?
2. **What widget types do we support?** Strict subset of JSON Schema
   or a broader mapping?
3. **Defaults vs. omission.** When the user leaves a field at its
   default, do we send the default to the plugin, or omit the key
   and let the plugin's own defaults apply?
4. **Validation.** Per-field red-state on bad input, or trust the
   plugin to reject?
5. **Cross-field dependencies.** Tripo's `pbr` is meaningful only
   when `texture` is `true`. Surface this in the UI?

## Decision

1. **Inline, under the prompt.** Adding a "Params…" modal would have
   forced an extra click on every dispatch — fine for rare options,
   bad for a daily-driver tool where we DO want users iterating on
   `temperature`. The form lives in `generate_form` and rebuilds
   whenever the dropdown selection changes.

2. **Subset of JSON Schema, mapped by type.** We support `boolean`
   → `CheckBox`, `integer` → `SpinBox` (rounded), `number` →
   `SpinBox` (float with `0.01` step), `string` → `LineEdit`,
   `string` with `enum` → `OptionButton`. Min / max bound the
   SpinBoxes; missing min/max enables `allow_lesser` / `allow_greater`.
   Description shows up as the row tooltip. Unknown types render a
   read-only "(unsupported type: X)" stub so the user sees the
   field exists but can't break it.

3. **Empty strings are omitted; everything else is sent verbatim.**
   `get_values()` skips LineEdit values that are empty, because
   sending `"system": ""` would clobber the plugin's own default.
   For typed widgets (CheckBox / SpinBox / OptionButton), the value
   is ALWAYS sent — there's no "unset" concept for a number, and
   we'd rather over-specify than have the plugin guess.

4. **No per-field validation in MVP.** SpinBox enforces min/max via
   its built-in clamp. OptionButton only lets you pick listed
   values. That's enough enforcement for now. Schema-level
   validation (cross-field rules, regex on strings) is documented
   as a follow-up. The plugin's `generate()` already validates
   incoming params and returns `ERR_INVALID_PARAMS` on bad input;
   that's the ultimate safety net.

5. **No conditional fields.** Tripo's `pbr` requires `texture`, but
   the plugin already validates this at dispatch time (returns
   `INVALID_PARAMS` if you set `pbr=true, texture=false`). Building
   conditional UI is its own design exercise. Documented as a
   follow-up.

6. **Schema is fetched per-render via `plugin.get_param_schema()`.**
   `_refresh_param_form_for_selection` reads the dropdown's current
   plugin name, looks up the plugin instance via
   `plugin_manager.active_plugins`, and calls `get_param_schema`.
   No cache — the call is cheap (returns a dict literal in every
   plugin we have today) and dynamic schemas can change without
   needing an invalidation hook.

7. **`_rows: Dictionary` as the test seam.** Each row stashes
   `{control, type, is_enum?, enum?}` so tests can index by field
   name and assert against the typed control directly. Same
   pattern as `credential_editor._rows`.

## Consequences

- **Generate Form is now actually useful.** Power users can drive
  `temperature: 0` for determinism, switch Claude models per call,
  flip Tripo's `pbr` off for cheaper renders. None of that needed
  a code change to a plugin.
- **The parameter surface is plugin-extensible by definition.** A
  new plugin's `get_param_schema()` immediately drives a UI; no
  new code in the form layer.
- **The form rebuilds on every plugin switch.** Switching from
  `claude` to `tripo` drops Claude-specific values. That's the
  correct behavior — Tripo wouldn't know what to do with
  `temperature` anyway — but means a "save params per plugin"
  feature would need separate state somewhere. Documented as a
  follow-up.
- **Empty-string omission is asymmetric.** For LineEdit only — not
  CheckBox / SpinBox / OptionButton. If a future plugin adds a
  string field where empty is meaningful (e.g. `"prefix": ""`
  intentionally meaning "no prefix"), we'd need to revisit.
- **No cross-field hint.** Tripo users will discover the
  pbr-needs-texture rule via the plugin's `INVALID_PARAMS` error
  message rather than the UI. Acceptable for MVP.

## Alternatives considered

- **Full JSON Schema validator.** There are off-the-shelf libraries
  that walk a schema and validate any input. Overkill — the four
  types we declared cover every plugin we ship and likely every
  plugin we'll add for a while. If we ever need pattern, format,
  or anyOf support, we can pull one in then.
- **Modal "Params…" overlay.** Same call as ADR 011 / 012 — the
  daily-driver flow doesn't want extra clicks. The inline form is
  also where the user already is.
- **One generic "JSON editor" textbox.** Lets users paste raw
  `{"temperature": 0.0}`. Punted because it's a worse UX (typos,
  no discoverability of fields) than a typed form.
- **Save params across plugin switches.** Tempting (some users want
  the same `temperature` regardless of which model they're calling)
  but ambiguous (what does Tripo's `temperature` even mean?). One
  follow-up: a "remember per plugin" persistence layer.
- **HSlider for numbers instead of SpinBox.** Sliders are nicer for
  small ranges, worse for fine-grained control. Tied to per-field
  hint metadata; deferred.

## Follow-ups

- **Per-field validation feedback.** Red-tinted row + label when
  a value falls outside `minimum`/`maximum`, when an enum value
  isn't actually in the enum, etc. Today the SpinBox auto-clamps,
  which is fine but invisible.
- **Conditional fields.** Surface "this field is only meaningful
  when X" in the UI. Schema would need a `dependencies` block
  (JSON Schema spec has one).
- **Per-plugin param persistence.** Remember the last-used values
  for each plugin so they survive plugin switches and app
  restarts.
- **Reset to defaults.** A small "reset" affordance per plugin
  that re-applies the schema's `default` values.
- **More widget types.** `string` with `format: "color"` →
  ColorPickerButton; `format: "filepath"` → FileDialog button;
  `format: "multiline"` → TextEdit. Each is a small mapping rule.
- **Slider variants for numbers.** Schema hint
  `"x-widget": "slider"` to opt into HSlider rendering with a
  value label.
- **Param panel collapse.** Once schemas grow, an expand/collapse
  toggle on the form so the prompt stays prominent.
- **HSpinBox alignment.** SpinBoxes default to a left-aligned
  text; matching the Label alignment makes the form look tidier.
