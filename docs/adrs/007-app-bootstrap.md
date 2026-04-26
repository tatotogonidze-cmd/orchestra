# ADR 007: App bootstrap via Orchestrator autoload + plugin registry

- **Status:** Accepted
- **Date:** 2026-04-24

## Context

By the end of the contract-layer phase we had:

- `BasePlugin` + `HttpPluginBase` (contracts and HTTP helpers).
- `PluginManager` (registration, dispatch, retry, signal aggregation).
- `CredentialStore` (encrypted key-value for API keys).
- `EventBus` autoload (broadcast / pub-sub).
- Three production plugins (Tripo, ElevenLabs, Claude), validated by a full
  GUT suite but **never actually instantiated by the app** because nothing
  called `PluginManager.register_plugin()` on them.

The MVP needed a bootstrap layer: one piece of code that, at startup,
brings up `CredentialStore` and `PluginManager`, reads the list of plugins
the app knows about, resolves each plugin's config, and registers +
enables the ones whose keys are available.

Three open questions:

1. **Where does the list of known plugins live?** Hard-code it in `main.gd`?
   Scan the `plugins/` directory? Keep a registry file?
2. **How is the PluginManager reached from UI code?** Parent-walking?
   Dependency injection? An autoload?
3. **How are plugins configured for smoke tests that don't want to go
   through the encrypted credential store?**

## Decision

1. **`scripts/plugin_registry.gd` — a static dict** mapping plugin name to
   `{path, category, env_var, config_keys}`. Adding a plugin means one new
   entry here plus the plugin file itself; nothing else changes.

2. **`scripts/orchestrator.gd` autoloaded as `/root/Orchestrator`.** It
   owns both `PluginManager` and `CredentialStore` as child nodes and
   exposes a small facade (`unlock_and_register`, `generate`, `cancel`,
   `plugin_names`). UI code reaches it as `Orchestrator.<method>` with no
   plumbing.

3. **Env-var fallback.** Each registry entry declares an `env_var` (e.g.
   `ANTHROPIC_API_KEY`). When resolving a plugin's config, Orchestrator
   tries the credential store first (if unlocked) and falls back to
   `OS.get_environment(env_var)` for the `api_key` field. Missing env +
   missing store entry → the plugin is silently skipped (not an error,
   just "not configured yet").

## Consequences

- **One place** knows about the plugin roster. Registry changes are
  mechanical.
- UI / background code gets a stable entry point (`Orchestrator.generate`)
  without threading references through scene hierarchies.
- Smoke tests in `tools/integration/smoke.gd` use env-vars only; they never
  need to unlock the encrypted store. Production users can still put keys
  in the store and never touch env vars.
- The credential store takes precedence, so a developer who's set both an
  env var *and* a store entry gets the deliberate (stored) key — not
  whatever happened to be in their shell profile.
- "Plugin not configured" is **not** a startup failure. The user may have
  only set up Claude; Tripo and ElevenLabs stay dormant until keys appear.
  That's the right posture for a multi-provider app.

## Alternatives considered

- **Directory scan at startup.** Rejected: forces a naming convention on
  plugin files, complicates inner classes/aliases, and provides no place
  for metadata like the env-var name.
- **Singleton `static` methods on PluginManager.** Rejected: `PluginManager`
  is already a `Node` that needs to be in the scene tree (for HTTPRequest
  children). Promoting it to a top-level autoload duplicates state we'd
  otherwise keep in `Orchestrator`.
- **Full DI container.** Overkill for three plugins and an autoload.
- **Env-var-only config, no credential store.** Rejected: keys in env are
  fine for dev but not for a shipped desktop app where the user would
  paste keys into a UI, not set `$env:` every launch.

## Follow-ups

- A UI layer that prompts for the master password, calls
  `Orchestrator.unlock_and_register`, and displays the per-plugin status
  returned by that call.
- A per-plugin health dashboard reading from the `plugin_registration_failed`
  signal.
- Registry migration if/when plugins need more than one secret (e.g. OAuth
  client_id + client_secret). Today `api_key` is the only secret any
  production plugin takes.
