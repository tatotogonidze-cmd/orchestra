# Integration tests (real network)

The GUT suite never hits real APIs — every unit test uses mock plugins or
tests validation paths before any request goes out. **This folder is the
only place in the codebase where real provider endpoints are called.**

Run these manually when:
- You're bringing up a new provider key and want to see one end-to-end call.
- You've changed a plugin's HTTP plumbing and want to confirm it still works.
- You're investigating a regression against a live API.

**Do not put API keys into `.env` files that could be committed.** Use a
shell-scoped `$env:` assignment (PowerShell) or `export` (bash) so the key
only lives for the duration of the terminal session.

## The one entry point

Everything goes through `smoke.gd`, a headless SceneTree script that
registers one plugin, submits one `generate()` call, and prints the result.

```powershell
godot --headless -s tools/integration/smoke.gd -- `
      --plugin=<name> --prompt="<text>" [--params='<json>'] [--out=<path>] [--timeout=<sec>]
```

The `--` after the script path is required: everything after it is passed
through to the smoke script, not consumed by Godot.

Flags:

- `--plugin` — required. One of `tripo`, `elevenlabs`, `claude`, `openai_image`.
- `--prompt` — required. The generation prompt.
- `--params` — optional JSON object merged into the plugin's params. Use
  single-quotes around the JSON in PowerShell so `"` isn't eaten.
- `--out` — optional host path where the generated binary (audio) is copied
  after success. Ignored for text / remote-URL results.
- `--timeout` — optional overall timeout in seconds (default 180).

Exit codes: `0` success, `1` CLI/config error, `2` plugin registration
failed, `3` task failed, `4` timed out.

## Claude — text

```powershell
$env:ANTHROPIC_API_KEY = "sk-ant-..."
godot --headless -s tools/integration/smoke.gd -- `
      --plugin=claude `
      --prompt="write a haiku about unit tests" `
      --params='{"model":"claude-haiku-4-5","max_tokens":256}'
```

Expected output:

```
[smoke] smoke: plugin=claude prompt_len=29 timeout=180s
[smoke] generating…
[smoke] progress claude:<id> 5% submitting
[smoke] OK asset_type=text format=plain cost=$0.000456
[smoke]   path=
[smoke]   text: Green checkmarks align …
```

Haiku is the default model choice for smoke tests — cheap and fast. Sonnet
is the production default but you rarely need a $0.01 smoke test.

## ElevenLabs — audio

```powershell
$env:ELEVENLABS_API_KEY = "xi-..."
godot --headless -s tools/integration/smoke.gd -- `
      --plugin=elevenlabs `
      --prompt="Hello, this is a smoke test." `
      --out=out/smoke.mp3
```

The plugin saves to `user://assets/audio/<task_id>.mp3`. The smoke script
copies that out to `./out/smoke.mp3` for easy listening.

You can override the voice/model in params:

```powershell
--params='{"voice_id":"pNInz6obpgDQGcFmaJgB","model_id":"eleven_turbo_v2"}'
```

## Tripo — text-to-3D

```powershell
$env:TRIPO_API_KEY = "tripo_..."
godot --headless -s tools/integration/smoke.gd -- `
      --plugin=tripo `
      --prompt="a low-poly wooden treasure chest" `
      --params='{"style":"lowpoly","pbr":true}' `
      --timeout=300
```

Tripo takes 30–120 seconds because of the poll loop. `result.path` is a
remote URL (not a `user://` file), so `--out` is ignored — open the URL in
a browser to download the `.glb`.

Longer timeouts are fine. Tripo's own pipeline has a deadline.

## OpenAI — image

```powershell
$env:OPENAI_API_KEY = "sk-..."
godot --headless -s tools/integration/smoke.gd -- `
      --plugin=openai_image `
      --prompt="a cozy stone cottage by a misty lake, painterly" `
      --out=out/cottage.png
```

The plugin saves to `user://assets/image/<task_id>.png` and the smoke
script copies that out to `./out/cottage.png`. Single-POST sync — no
polling — so `--timeout=60` is usually enough.

You can override model / size / quality in params:

```powershell
--params='{"model":"gpt-image-1","size":"1024x1792","quality":"hd"}'
```

`size` accepts `1024x1024`, `1024x1792`, `1792x1024`. `quality` is
`standard` or `hd`. The result includes a `revised_prompt` field —
OpenAI may rewrite the prompt to suit the model; the rewritten text
is in the smoke output.

## When smoke fails

The script prints the error code and HTTP body (truncated to 500 chars) so
you can tell auth failures from rate-limit failures from provider crashes:

```
[smoke] FAILED code=AUTH_FAILED retryable=false message=HTTP 401: {"error":"Invalid API key"}
```

Common causes:
- **`AUTH_FAILED`** — key is wrong, expired, or the env var name is off by
  one letter. Re-check `$env:<NAME>` in the same terminal.
- **`RATE_LIMIT`** — retried 3× by the plugin manager already; if still
  failing, you're being throttled hard. Wait a minute.
- **`NETWORK`** — DNS/TLS/timeout. Usually firewall, proxy, or offline.
- **`TIMEOUT`** (exit 4) — increase `--timeout`. Tripo in particular can
  take several minutes on busy days.

## Why this isn't in the GUT suite

GUT runs in CI, on contributors' machines, and in pre-commit hooks. Any of
those contexts calling real APIs would (a) burn credits we don't control,
(b) fail noisily when offline, and (c) leak keys into logs. The smoke
harness here is deliberate, manual, and single-shot.
