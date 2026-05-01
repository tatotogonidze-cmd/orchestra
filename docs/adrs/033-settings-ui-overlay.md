# ADR 033: Settings UI overlay

- **Status:** Accepted
- **Date:** 2026-05-01

## Context

Phase 24 (ADR 024) shipped `settings_manager.gd` — a JSON store
backing every persisted preference (cost limits, credential bypass
flag, last-used GDD path, plugin params). What it didn't ship was
a UI for editing those preferences directly. Instead, each consumer
UI grew a one-off editor for the keys it cared about:

- **BudgetHUD** edits `cost.session_limit` + `cost.dispatch_policy`
  (Phases 24 / 26).
- **unlock_dialog** edits `credentials.always_skip` via a checkbox
  on the dialog (Phase 24, integration B).
- **gdd_panel** persists `gdd.last_path` after each successful Open
  (Phase 24, integration C).
- **param_form** edits `plugin.<name>.params.<field>` per-plugin
  (Phase 25), with reset (Phase 28).

The user's only path to *see* "everything I have persisted" was to
poke around in `user://settings.json` directly. There's also no
"reset this one key" affordance on top — Budget HUD's Reset wipes
the WHOLE session, not just the persisted limit; param_form's
Reset (Phase 28) targets a single param but doesn't help with
non-plugin keys; nothing at all clears `credentials.always_skip`
short of editing the JSON.

The decisions to make:

1. **One overlay vs grow each consumer's editor?**
2. **Hard-coded registry vs schema introspection?**
3. **Should plugin-namespaced keys (`plugin.*.params.*`) live
   here too?**
4. **Per-row reset vs only "reset all"?**
5. **Discovery — where does the entry-point button live?**

## Decision

1. **One central overlay**, `scripts/ui/settings_panel.gd`.
   - Modal Control with the same shape as the other overlays —
     full-screen dim layer + centered PanelContainer + header /
     status / rows / footer (close + reset all).
   - Each row: Label (display name) + typed input (CheckBox /
     SpinBox / OptionButton / LineEdit by declared type) + per-row
     `↺` reset button.
   - Edits write through `settings_manager.set_value` immediately
     — same save-on-mutation convention as the manager itself.

2. **Hard-coded registry table** in `settings_panel.gd`. Each row:
   ```
   {
       "key":         "<dotted.key>",
       "label":       "<display name>",
       "type":        "string"|"bool"|"float"|"integer"|"enum",
       "enum":        [...] (only for enum type),
       "default":     <typed default>,
       "description": "<tooltip text>",
   }
   ```
   The schema-derived alternative (introspect every consumer's
   default to discover keys) was rejected for the same reasons as
   ADR 032's gdd_edit_form spec table:
   - The set of "user-editable settings" is a UX decision
     (e.g. cost-warning thresholds we want hidden today).
   - A schema-derived approach would require declaring schemas
     for settings — overhead bigger than the table itself.
   - When a new setting wants its own UI it's one entry in the
     table. The maintenance cost is in noise, not effort.

3. **Plugin-namespaced keys (`plugin.*.params.*`) intentionally
   excluded.** They:
   - Are per-plugin and only meaningful with the plugin's
     declared param schema.
   - Already have their own editor (param_form) in the Generate
     workflow, with per-row reset (Phase 28).
   - Listing every plugin's full schema in one panel would mean
     re-rendering param_form's logic, which belongs in a future
     "per-plugin settings" expansion (likely a tab strip in this
     same overlay or a separate panel) rather than today's MVP.

4. **Per-row + footer reset.** Per-row `↺` button calls
   `settings_manager.remove_value(key)` and visually restores the
   row to the registry default — so the user sees what default
   they just snapped back to. Footer `Reset all` calls
   `settings_manager.clear()` and rebuilds every row at default.
   Both are explicit user actions; no "are you sure" gate
   (consistent with Budget HUD's Reset, which also doesn't
   confirm).

5. **Entry point: header_bar, between Budget HUD and Lock now.**
   Five buttons total now. ADR 027 split header_bar specifically
   so we'd have horizontal real estate for action growth — Phase
   33 cashes that in. Settings sits AFTER Budget HUD (which
   represents a session-scoped state, not a persisted-prefs
   surface) and BEFORE Lock now (which is the trailing
   "destructive" action — locking immediately invalidates
   in-memory creds).

## Settings registry

The panel itself ships a registry of 4 rows that cover every
non-plugin persisted key the rest of the app writes today:

| Key                          | Type   | Default | Description                                                     |
|------------------------------|--------|---------|-----------------------------------------------------------------|
| `cost.session_limit`         | float  | `0.0`   | Maximum spend per session in USD. 0 = no limit.                 |
| `cost.dispatch_policy`       | enum   | `"warn"`| `warn` = soft warnings only. `hard_block` = refuse Generate.   |
| `credentials.always_skip`    | bool   | `false` | Bypass the unlock dialog at app start. Env-vars still resolved. |
| `gdd.last_path`              | string | `""`    | Pre-fills the GDD viewer's path input on open.                  |

`plugin.<name>.params.<field>` keys are NOT registered here —
they're handled by `param_form` per ADR 025 / 028.

## Consequences

- **One place to inspect / reset every persisted preference.**
  The "what does the app remember about me?" question now has
  a visible answer.
- **Existing per-consumer editors keep working.** BudgetHUD
  still edits `cost.session_limit` (it's the natural place
  during a session), and the settings panel reflects the new
  value on next open via `_rebuild_rows`. No double-source-of-
  truth issue — both paths write through `settings_manager`.
- **Adding a new setting is one entry in the registry table.**
  Type, label, default, description. No new row template, no
  new test scaffolding beyond the existing per-type coverage.
- **Plugin params remain split.** This is the correct boundary
  for now (ADR 025 / 028). If we later add tabbed sections
  (e.g. one tab per plugin) inside this same overlay, that's
  a follow-up — the registry table is shaped to allow it
  (just add a `category` field).
- **The Budget HUD Reset button still wipes the whole session
  (cost + limit).** Settings panel Reset is a distinct action
  that only clears the persisted limit (and policy), leaving
  the in-session spend intact. Two different scopes, two
  different buttons.

## Alternatives considered

- **Per-consumer editors only (status quo).** Rejected: the
  user has no global view of what's persisted, and resetting
  individual keys means editing JSON. The minute we hit 4+
  persisted keys (now), the maintenance cost of "user has to
  remember which UI controls which key" exceeds building one
  central surface.
- **Schema-introspected rendering.** Settings manager would
  expose a `describe()` API returning every known key + type +
  default. Considered. Rejected for the same reasons as ADR
  032's spec table — UX selection is intentional; we want the
  panel to render the user-tunable surface, not every internal
  preference.
- **Include plugin params in the same panel.** Rejected.
  param_form already handles them with full schema awareness.
  Re-rendering them here would either duplicate that logic or
  reduce it to "key + LineEdit" which loses the schema's
  enum / number-range information.
- **Tabbed sections (Cost / Credentials / GDD / Plugins).**
  Considered for visual organisation. Rejected for MVP — 4
  rows fit comfortably without tabs. Worth revisiting if the
  registry grows past ~12 entries.
- **Per-row save / cancel.** Each row would have its own
  Save button, edits buffered until pressed. Rejected — the
  rest of the app's settings interactions are save-on-change
  (BudgetHUD Apply notwithstanding, which is a single button
  driving a single edit). Buffered edits would be inconsistent.

## Follow-ups

- **Plugin-params expansion.** A tabbed surface inside this
  overlay where each tab renders a plugin's param_form. Would
  unify the "all the things the app remembers" view.
- **Search filter.** As the registry grows, a top-of-panel
  filter LineEdit ("type to filter rows"). Pairs with tabs.
- **Settings grouping.** Add `category` to the registry rows,
  render category headers above each group.
- **Import / Export.** "Export settings.json" + "Import…"
  buttons in the footer for moving prefs between machines.
  Probably waits on a stable schema_version migration story.
- **Live-preview for resets.** Currently reset = persist +
  rebuild row visually. A quick "(was 50.0)" tooltip after
  reset would help users undo a misclick.
- **Validation.** Today the panel writes whatever the user
  types. Adding type / range checks (e.g. negative session
  limits don't make sense) requires either schema awareness
  or per-row validators in the registry.
