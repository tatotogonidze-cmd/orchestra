# Orchestra — Architecture Overview

A single-user desktop AI orchestrator for game development, built in Godot
4.2.2. It coordinates a roster of pluggable AI providers (3D mesh, audio,
dialogue, code, ...), drives them from a Game Design Document (GDD), and
stitches their outputs back into the game project.

This document is the map. Individual design calls live in `docs/adrs/`.

## 1. Layers

```
+-------------------------------------------------------------+
|                        UI / Chat                             |
|       (Sidebar, Scene Viewer, GDD Editor, Budget HUD)       |
+---------------------+----------------+----------------------+
                      |                |
                      v                v
+---------------------+---+  +---------+-----------------------+
|   PluginManager         |  |   GDDManager                    |
|   - register/enable     |  |   - validate / load_gdd / save  |
|   - generate            |  |   - linear snapshots + rollback |
|   - parallel_generate   |  +---------+-----------------------+
|   - retry/backoff       |            |
|   - cost aggregation    |            |
+----+----------+---------+            |
     |          |                      |
     v          v                      v
+----+------+  +----------+   +--------+-----------------------+
| BasePlugin|  | Credential|   | Schemas (res://schemas/*)     |
| (contract)|  |   Store   |   | - gdd_schema.json             |
+-----+-----+  |(AES-256)  |   +-------------------------------+
      |        +-----------+
      | implements
      v
+-----+----------------------------+
| Mock3DPlugin, MockAudioPlugin,   |
| (future: TripoPlugin, Eleven..., |
|  Claude, ...)                    |
+----------------------------------+

                All subsystems post to:
           +------------------------------+
           |  EventBus (autoload, Node)   |
           |  gdd_updated, cost_incurred, |
           |  plugin_*, credential_*,...  |
           +------------------------------+
```

## 2. Core contracts

### `BasePlugin` (`scripts/base_plugin.gd`)

- Declares four signals: `task_progress`, `task_completed`, `task_failed`,
  `task_stream_chunk`.
- Lifecycle: `initialize(config) -> {success, error?}`,
  `health_check() -> {healthy, message}`, `shutdown()`.
- Work: `generate(prompt, params) -> String` (returns plugin-local task
  id), `cancel(task_id) -> bool`.
- Introspection: `get_metadata()`, `get_param_schema()`, `estimate_cost()`,
  `get_status(task_id)`, `get_all_tasks()`.
- Standard error constants: `ERR_RATE_LIMIT`, `ERR_AUTH_FAILED`,
  `ERR_NETWORK`, `ERR_INVALID_PARAMS`, `ERR_PROVIDER_ERROR`, `ERR_TIMEOUT`,
  `ERR_CANCELLED`, `ERR_INSUFFICIENT_BUDGET`, `ERR_UNKNOWN`.
- `_make_error(code, message, retryable, retry_after_ms?, raw?)` helper
  produces dicts in the standard shape.

See [ADR 001](adrs/001-plugin-contract-async.md) for why this is
async/signal-based rather than synchronous.

### `PluginManager` (`scripts/plugin_manager.gd`)

- Re-emits plugin signals with plugin-namespaced task ids
  (`"plugin:inner_id"`).
- Tracks every active task in `active_tasks: Dictionary`.
- Retries retryable errors with exponential backoff. The **original task
  id is preserved across retries** via `_retry_alias`. See
  [ADR 004](adrs/004-namespaced-task-ids.md).
- Signal plumbing uses **lambda closures, not `.bind()`** — see
  [ADR 003](adrs/003-godot-version.md).
- `parallel_generate(plugin_names, prompt, params)` and
  `parallel_generate_by_category(category, ...)` fan out the same
  prompt to multiple providers.

### `GDDManager` (`scripts/gdd_manager.gd`)

- Shallow structural validation against `schemas/gdd_schema.json`
  (required fields, `additionalProperties=false`, entity id prefix
  patterns). Full cross-reference integrity is a follow-up.
- Linear snapshot versioning; keeps the last 20 saves. See
  [ADR 006](adrs/006-gdd-snapshot-versioning.md).
- All successful mutations are announced on the EventBus.

### `CredentialStore` (`scripts/credential_store.gd`)

- AES-256-CBC encrypted JSON file (`user://credentials.enc`).
- Unlocked at startup with a master password; `lock()` clears the
  in-memory cache. See [ADR 002](adrs/002-credential-store.md).

### `EventBus` (`scripts/event_bus.gd`, autoload)

- App-wide broadcasts: `gdd_updated`, `gdd_snapshot_created`,
  `gdd_rollback_performed`, `plugin_registered`, `plugin_enabled`,
  `plugin_disabled`, `cost_incurred`, `credential_store_unlocked`, ...
- Hybrid model — most domain signals stay on their owners; only
  cross-cutting events flow through the bus. See
  [ADR 005](adrs/005-event-bus-hybrid.md).

## 3. Data: the GDD

The Game Design Document is a single JSON object conforming to
`schemas/gdd_schema.json`. Top-level structure:

```
{
  "schema_version": "1.0.0",
  "game_title": String,
  "genres": [String],
  "core_loop": { "goal": String, "actions": [String], "rewards": [String] },
  "mechanics":  [{ "id": "mech_*", "description": String, ... }],
  "assets":     [{ "id": "asset_*", ... }],
  "tasks":      [{ "id": "task_*", ... }],
  "scenes":     [{ "id": "scene_*", ... }],     // optional
  "characters": [{ "id": "char_*", ... }],      // optional
  "dialogues":  [{ "id": "dlg_*", ... }],       // optional
  "metadata": {
    "document_version": String,                  // semver of the doc itself
    "created_at": ISO8601,
    "updated_at": ISO8601
  }
}
```

ID prefix conventions are enforced by `GDDManager.validate()` and by the
schema's `pattern` fields.

## 4. Failure model

- Every error is the standard dict shape (see BasePlugin).
- Retryable errors (`RATE_LIMIT`, some `NETWORK`, some `PROVIDER_ERROR`)
  go through manager retry; callers never see them unless all retries
  fail.
- Non-retryable errors (`CANCELLED`, `AUTH_FAILED`, `INVALID_PARAMS`,
  `INSUFFICIENT_BUDGET`) surface immediately as `plugin_task_failed`.
- The `retry_scheduled(task_id, attempt, delay_ms)` signal makes retry
  activity observable to UIs and tests.

## 5. Testing

- Framework: **GUT** (Godot Unit Test), installed into `addons/gut/`.
  Setup in the README.
- Suites: `tests/test_base_plugin.gd`, `tests/test_plugin_manager.gd`,
  `tests/test_gdd_manager.gd`, `tests/test_credential_store.gd`,
  `tests/test_parallel_mode.gd`, `tests/test_retry_backoff.gd`.
- Key guardrail: `test_generate_and_progress_signal_argument_order` locks
  in the signal contract and the lambda-not-`.bind()` decision from ADR
  003.
- Headless run:
  ```
  godot --headless -s addons/gut/gut_cmdln.gd -gconfig=.gutconfig.json
  ```

## 6. Developer workflow

- **Pre-commit hook** (`.githooks/pre-commit`) runs the plaintext-key
  scanner and, when Godot is on PATH, the full GUT suite. Install with
  `git config core.hooksPath .githooks`.
- **Plaintext-key scanner** (`tools/check_plaintext_keys.py`) catches
  common API-key shapes before they reach the remote. Suppress false
  positives with an `# allow-plaintext-key` same-line marker.

## 7. What's deliberately deferred

- OS keyring integration for credentials (ADR 002 Phase 2).
- Full cross-reference integrity validation in GDDManager.
- Additional real plugin implementations (Meshy, Suno, DeepSeek, Inworld,
  ...). Tripo, ElevenLabs, and Claude ship today (see `docs/plugins.md`
  for the field guide). Mock plugins still exercise the pipeline in tests.
- A UI layer. The orchestrator core is UI-agnostic; a sidebar/scene-viewer
  comes next. `Orchestrator` autoload (ADR 007) is the stable entry point
  the UI will call into.
- Claude chat-edit of the GDD. The snapshot machinery is already built to
  make this safe.
