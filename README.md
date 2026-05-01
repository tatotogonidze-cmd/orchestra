# Orchestrator

AI orchestrator for game development in Godot. Plugin hub, GDD manager, task dashboard, asset manager, chat module — all in one modular environment.

Status: MVP foundation in progress. Contract layer + Plugin Manager + GDD Manager + Credential Store + first mock plugins + test suite.

## Requirements

- **Godot 4.2.x** (pinned; see `docs/adrs/003-godot-version.md`)
- **GUT** (Godot Unit Test) — install instructions below
- Python 3.8+ (for the pre-commit `check_plaintext_keys` tool)

## Installing GUT

GUT is a GDScript unit-test framework. This project expects it at `addons/gut/`.

### Option A: GitHub release (recommended)

1. Download the latest GUT 9.x release for Godot 4 from https://github.com/bitwes/Gut/releases
2. Extract the `addons/gut/` folder into `C:\orchestra\addons\gut\`
3. Open the project in Godot → `Project → Project Settings → Plugins` → enable **Gut**
4. Reload the project

### Option B: Asset library

1. Open the project in Godot
2. `AssetLib` tab → search for **Gut**
3. Install, enable in `Project → Project Settings → Plugins`

### Running tests

From the editor:
- Click the **Gut** bottom panel → set `Tests Directory` to `res://tests/` → **Run All**

From the command line (requires Godot in PATH). The repo ships a
`.gutconfig.json` that points GUT at `res://tests/`:

```powershell
godot --headless -s addons/gut/gut_cmdln.gd -gconfig=.gutconfig.json
```

Equivalent long form without the config file:

```powershell
godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests/ -ginclude_subdirs -gexit
```

## Project structure

```
orchestra/
├── project.godot
├── scenes/
│   └── main.tscn             # App entry point — instantiates main_shell.gd
├── scripts/
│   ├── base_plugin.gd        # Contract for all generator plugins
│   ├── http_plugin_base.gd   # HTTP helpers, status mapping, Retry-After
│   ├── plugin_manager.gd     # Registration, dispatch, signal aggregation, retry
│   ├── plugin_registry.gd    # Known-plugins registry (path/category/env_var)
│   ├── orchestrator.gd       # Autoload: bootstrap + facade over PluginManager
│   ├── event_bus.gd          # Autoload: broadcast/pub-sub
│   ├── gdd_manager.gd        # Validate, load/save, snapshot, rollback
│   ├── credential_store.gd   # Encrypted key-value for API credentials
│   ├── asset_manager.gd      # Content-hashed ingest of plugin outputs (text/audio/image/3d)
│   ├── cost_tracker.gd       # Per-session spend + per-category breakdown + soft warnings
│   ├── scene_manager.gd      # Metadata-only scene records (asset_id bundles)
│   ├── settings_manager.gd   # Persistent user preferences (plain JSON)
│   └── ui/
│       ├── main_shell.gd     # Root Control — assembles the four panels
│       ├── plugin_panel.gd   # Plugin list + status (left sidebar)
│       ├── generate_form.gd  # Plugin dropdown + prompt + submit
│       ├── task_list.gd      # Live in-flight tasks + cancel
│       ├── asset_gallery.gd  # Asset catalog with type filter + details
│       ├── unlock_dialog.gd  # Master-password modal at app startup
│       ├── credential_editor.gd  # Per-plugin api_key CRUD modal
│       ├── asset_preview.gd  # Type-specific asset preview overlay
│       ├── cost_footer.gd    # Persistent session-cost status bar (status only)
│       ├── budget_hud.gd     # Detailed cost / breakdown / limit modal
│       ├── header_bar.gd     # Top action bar — title + GDD/Scenes/HUD/Settings/Lock buttons
│       ├── param_form.gd     # Plugin-param schema → typed inputs
│       ├── gdd_panel.gd      # GDD viewer + chat-edit + form-edit
│       ├── gdd_edit_form.gd  # Form-based GDD editor sub-component
│       ├── scene_panel.gd    # Scene tester: list + preview + add/remove assets
│       └── settings_panel.gd # Persisted-prefs editor — registry-driven typed inputs
├── plugins/
│   ├── mock_3d_plugin.gd     # Stress test: 3D generator
│   ├── mock_audio_plugin.gd  # Stress test: audio generator + RATE_LIMIT trigger
│   ├── mock_image_plugin.gd  # Stress test: image generator (writes synthetic PNGs) + RATE_LIMIT trigger
│   ├── tripo_plugin.gd       # Real: text-to-3D
│   ├── elevenlabs_plugin.gd  # Real: text-to-speech
│   ├── claude_plugin.gd      # Real: Anthropic Messages API
│   └── openai_image_plugin.gd # Real: OpenAI text-to-image
├── schemas/
│   └── gdd_schema.json       # Strict JSON schema for the GDD
├── tests/                    # GUT tests (mock plugins only, no network)
├── docs/
│   ├── architecture.md
│   ├── plugins.md            # Field guide for plugin authors
│   └── adrs/                 # Architecture Decision Records
└── tools/
    ├── check_plaintext_keys.py
    └── integration/          # Manual smoke tests against real APIs
        ├── smoke.gd
        └── README.md
```

## Key docs

- `docs/architecture.md` — the big picture
- `docs/adrs/001-plugin-contract-async.md` — async/signal-based contract
- `docs/adrs/002-credential-store.md` — MVP encrypted file (AES-256-CBC)
- `docs/adrs/003-godot-version.md` — 4.2.2 pin; lambdas over `.bind()`
- `docs/adrs/004-namespaced-task-ids.md` — retry alias for stable identity
- `docs/adrs/005-event-bus-hybrid.md` — hybrid signals vs EventBus rule
- `docs/adrs/006-gdd-snapshot-versioning.md` — linear, last 20
- `docs/adrs/007-app-bootstrap.md` — Orchestrator autoload + plugin registry
- `docs/adrs/008-asset-manager.md` — content-hashed asset ingest + dedup
- `docs/adrs/009-ui-shell.md` — programmatic Control tree + signal wiring
- `docs/adrs/010-credential-unlock-ui.md` — master-password modal + Skip path
- `docs/adrs/011-credential-editor.md` — per-plugin api_key CRUD UI
- `docs/adrs/012-asset-preview.md` — type-specific asset preview overlay
- `docs/adrs/013-cost-footer-budget-hud.md` — soft-warning cost awareness
- `docs/adrs/014-keyboard-and-lock.md` — Ctrl+Enter / Esc / Lock Now button
- `docs/adrs/015-plugin-param-editor.md` — schema-driven typed inputs
- `docs/adrs/016-gdd-viewer.md` — read-only GDD modal + snapshot timeline
- `docs/adrs/017-gdd-chat-edit.md` — natural-language editing via Claude
- `docs/adrs/018-gdd-form-edit.md` — form-based GDD editing alongside chat-edit
- `docs/adrs/019-cross-reference-integrity.md` — cross-entity id reference validator
- `docs/adrs/020-chat-edit-diff-highlight.md` — LCS per-line diff with red/green highlights
- `docs/adrs/021-3d-viewport-preview.md` — SubViewport + GLTFDocument + orbital camera
- `docs/adrs/022-test-connection-per-credential.md` — per-row credential probe
- `docs/adrs/023-scene-tester-preview-pipeline.md` — metadata-only scene tester + 3D preview
- `docs/adrs/024-settings-store.md` — central persistent preferences (plain JSON)
- `docs/adrs/025-per-plugin-param-persistence.md` — restore last-used params per plugin
- `docs/adrs/026-hard-cost-gating.md` — opt-in dispatch refusal at the limit
- `docs/adrs/027-header-bar-refactor.md` — split action surface from status footer
- `docs/adrs/028-ux-polish-pair.md` — reset-to-default per param + scene picker
- `docs/adrs/029-auto-fix-and-typed-probe.md` — bulk auto-fix dangling refs + typed-key Test
- `docs/adrs/030-word-diff-and-auto-frame.md` — word-level diff stats + auto-frame model AABB
- `docs/adrs/031-conversation-chat-edit.md` — multi-turn refinement of GDD via Claude
- `docs/adrs/032-per-entity-form-fields.md` — per-type rendered fields in form-edit
- `docs/adrs/033-settings-ui-overlay.md` — registry-driven settings editor
- `docs/adrs/034-gdd-markdown-export.md` — GDD export to Markdown
- `docs/adrs/035-snapshot-diff-viewer.md` — read-only snapshot vs current diff
- `docs/adrs/036-openai-image-plugin.md` — real text-to-image via OpenAI
- `docs/adrs/037-mock-image-plugin.md` — synthetic PNG mock for retry + preview coverage
- `docs/adrs/038-onboarding-empty-state-polish.md` — first-launch hints + starter-GDD seed
- `docs/plugins.md` — field guide for adding new provider plugins

## Integration smoke tests (real APIs)

The GUT suite never hits real endpoints. If you need to verify a live
provider call, see `tools/integration/README.md`. One-shot invocation
example:

```powershell
$env:ANTHROPIC_API_KEY = "sk-ant-..."
godot --headless -s tools/integration/smoke.gd -- `
      --plugin=claude --prompt="write a haiku about unit tests"
```

## Pre-commit hook (optional but recommended)

```powershell
git config core.hooksPath .githooks
```

This runs:
1. `python tools/check_plaintext_keys.py` — grep for likely plaintext API keys
2. (Optional, if Godot is in PATH) GUT test suite headless

## Next steps beyond MVP foundation

See `docs/architecture.md` → *Backlog* section.
