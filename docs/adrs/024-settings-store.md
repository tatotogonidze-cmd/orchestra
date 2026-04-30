# ADR 024: Settings store — central persistent preferences

- **Status:** Accepted
- **Date:** 2026-04-25

## Context

Phases 10-23 each accumulated user-state-that-should-persist:

- ADR 013's CostTracker had a session limit that died at app exit.
- ADR 010's unlock dialog had no "always skip" preference; users
  who only used env-vars saw the modal every launch.
- ADR 016's GDD panel asked the user to retype `user://gdd.json`
  every time, even though everyone keeps their GDD at the same
  path.
- ADR 022's "test connection" couldn't remember a successful
  probe, so subsequent launches re-ran them.

Each ADR documented a follow-up "persist X" item. None individually
justified a new module; together they did. Phase 24 ships a single
SettingsManager that gives the orchestrator a real persistent
preferences layer, then demonstrates the pattern with three
representative integrations.

The decisions to make:

1. **Encrypted or plain?** SettingsManager values look superficially
   like CredentialStore values (string keys, persisted across runs).
   But credentials are SECRETS; preferences are not.
2. **Scope.** What goes in settings, what doesn't?
3. **API shape.** How do consumers read / write?
4. **Persistence policy.** Save on each mutation, or batched?
5. **Defaults.** Where do they live — in the manager, or in each
   consumer?
6. **Key naming.** Free-form strings, hierarchical, namespaced?

## Decision

1. **Plain JSON at `user://settings.json`.** No encryption. The
   alternative — running everything through CredentialStore —
   would be wrong on two counts:
   - The credential store needs unlocking with a master password
     before reads. We need to read `credentials.always_skip`
     BEFORE the unlock decision; chicken/egg.
   - Settings aren't secrets. Encrypting them just complicates
     debugging without a security benefit.

2. **Scope: non-secret user preferences.** Concrete types we ship:
   - `cost.session_limit` (float)
   - `credentials.always_skip` (bool)
   - `gdd.last_path` (String)
   The line between "preference" and "secret" is "would I be
   embarrassed if this leaked?" — settings should answer no.

3. **`get_value` / `set_value` etc., NOT `get` / `set`.** Node
   already exposes `get(property)` and `set(property, value)` for
   property-system access; overriding those would silently break
   anything that used them. Long names keep the surface clear.

4. **Persist on each mutation.** No `save()` method. Every
   `set_value` and `remove_value` writes the JSON file
   immediately. Saves the user from a "I closed the app and lost
   my settings" footgun, and our settings are small enough (~few
   KB) that the disk overhead is invisible.

5. **Defaults are owned by consumers.** The manager doesn't know
   about defaults — `get_value(key, default)` takes the default
   from the caller. This means:
   - Consumers can change defaults without migrating stored data
     (existing values keep their explicit value; new installs get
     the new default).
   - The manager stays simple: one Dictionary, one schema_version
     header for forward-compatibility.

6. **Dotted, namespaced keys.** `<subsystem>.<setting>`:
   `cost.session_limit`, `credentials.always_skip`, `gdd.last_path`.
   Lowercase, ASCII, dot-separated. Documented in the manager's
   docstring + table below.

## Integration patterns

The three demos in this phase show the patterns we expect future
integrations to follow.

### Pattern A: Restored on startup

`cost_tracker` reads the persisted limit during `Orchestrator._ready`:

```gdscript
# orchestrator.gd, after creating cost_tracker
var saved_limit: float = float(
    settings_manager.get_value("cost.session_limit", 0.0))
if saved_limit > 0.0:
    cost_tracker.set_session_limit(saved_limit)
```

`BudgetHUD` writes the limit on Apply. The setting flows
**outwards** from settings on read, **inwards** to settings on
write. Used for: budget limits, "remember last used" values.

### Pattern B: Gates the autoload boot path

`main_shell._ready` reads `credentials.always_skip` BEFORE
deciding whether to show the unlock dialog. If true, we bypass
the modal entirely. Successful unlock clears the flag.

```gdscript
if _autoload_always_skip(orch):
    orch.call("register_all_available")  # env-vars only
else:
    unlock_dialog.show_dialog()
```

Used for: feature toggles that change boot behaviour.

### Pattern C: Prefills UI on open

`gdd_panel.show_dialog` reads `gdd.last_path` if no path is
already loaded this session. `_on_load_pressed` writes the
persisted value on success.

```gdscript
if _current_gdd_path.is_empty():
    var saved: String = _read_last_path()
    if not saved.is_empty():
        _path_input.text = saved
```

Used for: last-used paths, last-used filters, last-used selections.

## Consequences

- **Sessions feel sticky.** Open the app, your budget limit is
  back. Set "always skip" once, never see the dialog again. Type
  `user://my_gdd.json` once, never type it again.
- **Settings are ungoverned by encryption.** A reader of disk can
  see `credentials.always_skip: true` — but they can also see
  every uncreated empty file. Acceptable; no actual secret
  exposed.
- **Each consumer manages its own defaults.** Means we can
  evolve defaults across versions without writing migrations.
  Means we have to remember to pass the SAME default at every
  read site of a given key. Documented in code via the
  `_SETTING_KEY_*` constants the integrations adopt.
- **Orchestrator gains a 7th manager.** `settings_manager` joins
  plugin / credential / asset / cost / gdd / scene as a
  first-class child node. Lifetimes match.
- **`SettingsManager` is loaded BEFORE the other managers.**
  cost_tracker needs settings during its own bootstrap (to
  restore session_limit). The construction order in
  `Orchestrator._ready` enforces that.
- **Tests pollute `user://_test_settings_*.json` files.**
  Every test gets a unique path under `user://`, cleaned up in
  after_each. Same hygiene as the other manager tests.

## Settings registry

Source-of-truth listing for the keys we ship today. New keys
follow the naming convention; new subsystems add a row here.

| Key                         | Type   | Default  | Owner          | Notes                          |
|-----------------------------|--------|----------|----------------|--------------------------------|
| `cost.session_limit`        | float  | `0.0`    | CostTracker    | 0.0 = no limit                 |
| `credentials.always_skip`   | bool   | `false`  | unlock_dialog  | autoload bypasses modal when true |
| `gdd.last_path`             | String | `""`     | gdd_panel      | "" = use DEFAULT_PATH on first run |

## Alternatives considered

- **Run settings through `CredentialStore`.** Encrypts everything
  uniformly. Rejected because the unlock dialog itself needs to
  read a setting (always_skip) BEFORE asking for the master
  password — circular.
- **`ProjectSettings` / Godot's editor settings store.**
  Half-tempting because Godot already has machinery. Rejected:
  ProjectSettings is editor-side and shipping a setting through
  it requires an editor-side dance; it also pollutes the
  project's own settings namespace.
- **Settings as a flat top-level JSON object (no `values` wrapper).**
  Easier to read by hand but no room for forward-compat fields
  (schema_version, etc). The wrapper costs us 4 bytes of JSON.
- **Explicit `save()` instead of save-on-mutation.** Tempting if
  settings were big or write-heavy. Ours aren't — handful of
  values, written once on user action. Save-on-mutation
  eliminates a state we'd otherwise have to track ("are there
  unsaved changes?").
- **Defaults stored in the manager.** Considered. Rejected
  because two consumers reading the same key could disagree
  about defaults; centralising defaults would require a
  registry that consumers also have to update. Pushing the
  default to the call site is simpler and slightly more
  flexible.
- **Watch-style API: emit when ANY setting changes, consumers
  filter.** We emit `setting_changed(key, value)` so consumers
  can subscribe. They MUST filter — we don't bother with
  per-key signals. Same trade-off as cost_tracker's
  `cost_updated`.
- **Dot-separated keys vs slash vs dict-of-dicts.** Considered.
  Dot-separated wins for readability and grep-ability; slash
  conflicts with path semantics; dict-of-dicts is real work.

## Follow-ups

- **Settings UI overlay.** A modal where the user can see + edit
  every setting in a typed form (similar to param_form). For
  now they're set indirectly through their consumer UIs.
- **Schema validation.** Today the manager accepts any
  Variant. A typed schema (key → expected type) would reject
  garbage values + power a settings UI generator.
- **Environment-variable overrides.** `ORCHESTRA_COST_LIMIT=20`
  could override `cost.session_limit` for the session without
  persisting. Useful for CI / testing.
- **Migration story.** When a key's shape changes, today there's
  nothing. A `schema_version` bump + per-version migration
  function would handle this gracefully.
- **Per-plugin param persistence.** ADR 015 follow-up. Each
  plugin's last-used params (model, temperature, etc) belong
  in settings: `plugin.<name>.params.<field>`.
- **Reset-to-defaults button.** A settings UI affordance that
  drops a key (so the next read returns the default).
- **Background settings sync** (cloud sync, multi-machine). Way
  out of scope but worth mentioning so the on-disk layout
  stays portable.
- **Test-local Orchestrator that accepts a settings path
  override.** For testing the cost_tracker restore-on-startup
  flow end-to-end without polluting `user://settings.json`.
  Today the SettingsManager unit tests + orchestrator
  child-node assertion cover the wiring; a true integration
  test waits on this hook.
