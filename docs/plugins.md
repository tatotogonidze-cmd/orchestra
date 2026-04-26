# Writing an Orchestra plugin

This is the field guide for anyone adding a new AI provider to Orchestra
(Stability, Meshy, Suno, DeepSeek, Inworld, anything else). It covers the
contract, the HTTP helper, testing conventions, and the small set of
mistakes that keep biting us — so you don't have to relearn them.

Read this before writing the plugin. It's short.

## 1. Which base class do I extend?

- **`HttpPluginBase`** if your provider is a normal HTTP/JSON (or HTTP/binary)
  service. You get `_http_request()`, status-code mapping, and Retry-After
  parsing for free. This is what `TripoPlugin`, `ElevenLabsPlugin`, and
  `ClaudePlugin` all do.
- **`BasePlugin`** directly if you're using a SDK-style provider (native
  library, websocket, local process). Rare for the kinds of providers we
  integrate with, but the option is there.

## 2. The contract you must honor

Every plugin overrides:

```gdscript
func initialize(config: Dictionary) -> Dictionary      # {success, error?}
func health_check() -> Dictionary                       # {healthy, message}
func generate(prompt: String, params: Dictionary) -> String   # returns task_id
func cancel(task_id: String) -> bool
func estimate_cost(prompt: String, params: Dictionary) -> float
func get_metadata() -> Dictionary
func get_param_schema() -> Dictionary
```

And emits these signals from `BasePlugin`:

```
task_progress(task_id, progress: float, message: String)   # optional, any number
task_completed(task_id, result: Dictionary)                # exactly once per success
task_failed(task_id, error: Dictionary)                    # exactly once per failure
task_stream_chunk(task_id, chunk)                          # optional, if streaming
```

Never emit both `task_completed` and `task_failed` for the same task.

## 3. The standard error shape

Every `task_failed` error is:

```gdscript
{
    "code": String,          # ERR_* constant from BasePlugin
    "message": String,
    "retryable": bool,
    "retry_after_ms": int,   # optional, hint for backoff
    "raw": Variant,          # optional, provider-specific
}
```

Use `_make_error()` (or `_make_http_error()` on HttpPluginBase) — do not
hand-roll this dict.

The `code` values and their meaning:

| Code                   | When                                      | Retryable by default |
|------------------------|-------------------------------------------|----------------------|
| `RATE_LIMIT`           | 429 or provider "too many requests"        | **yes**              |
| `AUTH_FAILED`          | 401, 403, invalid key                      | no                   |
| `NETWORK`              | DNS/TLS/timeout before any response        | **yes**              |
| `INVALID_PARAMS`       | 4xx other than 429, param validation       | no                   |
| `PROVIDER_ERROR`       | 5xx, unparseable response                  | **yes** (5xx) / no (parse) |
| `TIMEOUT`              | 408/504 or your own poll timeout           | **yes**              |
| `CANCELLED`            | `cancel()` caused the task to end          | no                   |
| `INSUFFICIENT_BUDGET`  | the app's budget guard refused the call   | no                   |
| `UNKNOWN`              | nothing else fit                           | no                   |

`PluginManager` retries iff `retryable == true`.

## 4. The generate() pattern

The winning shape for most plugins is:

```gdscript
func generate(prompt: String, params: Dictionary) -> String:
    # 1. Validate BEFORE issuing a task id. If invalid, emit the failure
    #    via call_deferred so subscribers that attach after generate()
    #    returns still see it.
    var v := _validate_params(prompt, params)
    if not v["valid"]:
        var dummy_id := _make_task_id()
        call_deferred("_emit_param_error", dummy_id, v["error"])
        return dummy_id

    # 2. Issue id, register in _tasks, kick off the coroutine.
    var tid := _make_task_id()
    _tasks[tid] = {"state": "Running", "cancelled": false, ...}
    _run_real_work(tid, prompt, params)   # NOT awaited — fire-and-track
    return tid
```

The `_run_real_work` coroutine does the HTTP call(s), checks cancellation
at each `await` point, and ends with exactly one of:
- `emit_signal("task_completed", tid, result)` + `_tasks.erase(tid)`
- `emit_signal("task_failed", tid, error)`   + `_tasks.erase(tid)`

Use the `_task_aborted(tid)` helper between awaits. It emits the
`CANCELLED` error and cleans up if the task has been cancelled.

## 5. The result dictionary

On success, `task_completed`'s second argument MUST contain:

```gdscript
{
    "asset_type": String,     # "3d" | "audio" | "text" | "image" | ...
    "format": String,         # "glb" | "mp3" | "plain" | "png" | ...
    "path": String,           # user:// path OR remote URL OR inline "text"
    "cost": float,            # actual USD cost (or estimate if unknown)
    "plugin": String,         # your plugin_name
    # ...any provider-specific extras
}
```

`PluginManager` pipes `cost` into the `cost_incurred` signal — keep it
accurate so the budget HUD tracks reality.

## 6. Cost modeling

Two patterns:

- **Per-call flat fee** (Tripo): return the estimate from `estimate_cost()`
  and use the same value in `result.cost`. Easy, lossless.
- **Per-token / per-char** (Claude, ElevenLabs): `estimate_cost()` is a
  guess based on the prompt length and `max_tokens`; the actual cost on
  `result.cost` comes from the provider's `usage` block / char count.

The schema says `cost_unit: "USD"`. If you integrate a provider that bills
in credits, convert at init time.

## 7. Param schema — let the UI render you a form

`get_param_schema()` returns a JSON-Schema-like structure:

```gdscript
{
    "type": "object",
    "properties": {
        "style": {
            "type": "string",
            "enum": ["realistic", "lowpoly"],
            "default": "realistic",
            "description": "..."
        },
        ...
    },
    "required": []
}
```

Supported types: `string`, `integer`, `number`, `boolean`. For strings, use
`enum` for picker widgets. For numbers, use `minimum`/`maximum`. Include
`default` so the Plugin Hub UI can pre-fill.

## 8. Testing

Unit tests live at `tests/test_<plugin>.gd`. They MUST NOT hit real APIs.
Cover:

- `get_metadata()` returns the expected keys, category, capabilities.
- `get_param_schema()` has all the properties you document.
- `initialize({})` rejects missing api_key.
- `health_check()` is unhealthy without a key.
- `generate(bad_params)` emits `task_failed` with `ERR_INVALID_PARAMS`.
- `generate(valid_params)` with no api_key emits `ERR_AUTH_FAILED`.

The existing three plugins follow this pattern — copy-paste is fine.

Integration tests against real APIs are manual. Document them in a
README block; do not commit API keys.

## 9. Common mistakes

- **Using `.bind()` to connect plugin signals** — see ADR 003. Always
  lambdas. The test suite catches this one, but only in PluginManager.
- **Forgetting to erase from `_tasks`** on completion / failure / cancel
  — leaks memory and confuses `get_all_tasks()`.
- **Emitting both `task_completed` and `task_failed`** after a cancelled
  retry. Use `_task_aborted()` to early-return.
- **Setting `retryable: true` on auth errors** — the user's key is wrong;
  retrying burns their budget on guaranteed failures.
- **Assuming `get_tree()` is non-null** — unit tests sometimes construct
  the plugin outside the scene tree. Guard with:
  ```gdscript
  var tree := get_tree()
  if tree == null:
      _fail(tid, _make_error(ERR_UNKNOWN, "not in scene tree", false))
      return
  ```

## 10. Registering with the app

Once the plugin lives in `plugins/<name>_plugin.gd`, wire it up at the
app's startup code:

```gdscript
var plug := preload("res://plugins/tripo_plugin.gd").new()
add_child(plug)
var cfg := CredentialStore.get_plugin_config("tripo")
PluginManager.register_plugin("tripo", plug, cfg)
PluginManager.enable_plugin("tripo")
```

`register_plugin` calls `initialize(cfg)` — so `cfg` is where the api_key
(from the encrypted store) lands.

That's all. Welcome to the plugin roster.
