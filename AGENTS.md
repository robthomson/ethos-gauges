# Agent guide

This is an **FrSky Ethos Lua** project built from the Ethos Lua VS Code template, with the CI/release model of the Rotorflight / Wingflight Ethos suites. Read this before changing code.

## About this project

`src/gauges/`: one generic gauge widget (widget key `etgauge`). The pilot drops it into any screen slot and picks, in its configure page, a **gauge type** (arc, half arc, ring, horizontal bar, vertical bar, needle dial), a **source**, a **min/max** range (one decimal, stored in tenths), a colour and whether to show the source name and the min/max labels.

- Settings are per slot: they live in the widget instance and are saved in the model by `read`/`write` (`storage.read`/`storage.write`). Never use files for widget settings.
- Stored keys: `v` (settings version), `type`, `source`, `min`, `max`, `color`, `title`, `limits`. Gauge type numbers are stored in models: never renumber them, only append. Keep `read` and `write` in the same order.
- Picking a new source pre-fills min/max from `source:minimum()/maximum()` (sticks are -1024..1024).
- `wakeup` compares the value at display precision; `paint` re-runs `layout()` only when the window size or settings change, and re-fits the value font only when the text length changes.
- `lcd.drawAnnulusSector` takes at most 180 degrees per call; `drawArc()` splits longer arcs with a 1 degree overlap (no seams).

## Where things are, and what may be edited

| Path | Edit? | What |
| --- | --- | --- |
| `src/gauges/**` | **Yes** | The Lua that runs on the radio. Deployed to `SCRIPTS:/gauges/` |
| `i18n/<lang>.json` | **Yes** | Translations for `@i18n(key)@` tags. Keep every language's keys in step with `en.json` |
| `src/gauges/ethos_lua_manifest.json` | Yes (version, introduction) | Never change `key` after a release |
| `Releases.md` | Yes | Add a `# <version>` section before tagging a release |
| `.vscode/deploy.json`, `.vscode/settings.json`, `.vscode/launch.json` inputs | Only when asked | Project name, simulator, language list |
| `.vscode/scripts/**`, `bin/package/**`, `.github/**` | **No** (shared tooling) | Change only when the task is about the tooling itself |
| `simulators/`, `dist/`, `.vscode/logs/` | Never commit | Generated |

## Ethos Lua rules (must follow)

Reference: https://frskyrc.github.io/ethos-lua-doc/ (API: `/api/`, machine-readable index: `/api/api-index.json`, best practice: `/best-practice/`).

- **Hot paths** (`wakeup`, `paint`, event handlers): no per-call table, closure or string allocation; call `lcd.invalidate()` only when something visible changed; compare values at display precision.
- **Paths:** relative paths only resolve while `main.lua` loads. Any file access from a callback must use `SCRIPTS:/gauges/...`.
- **Nil-check** `system.getSource`, `model.createSensor`, `lcd.loadBitmap`/`loadMask`, dialog handles, `io.open`.
- **Guard newer APIs** (`if system.getSources then ... end`) for older firmware.
- Widget keys are max 7 characters and must never change after a release.
- **User-facing text** goes through `@i18n(key)@` tags, with the key added to **every** `i18n/*.json`. Never hard-code display strings.
- Prefix `print()` output with `[gauges]` (see `lib/util.lua`).

## Build, deploy, test

| Goal | Command (from repo root) |
| --- | --- |
| Deploy to simulator | `python .vscode/scripts/deploy.py --lang en --step i18n` |
| Deploy to USB radio (fast) | `python .vscode/scripts/deploy.py --fileext fast --radio --lang en --step i18n` |
| Stream radio `print()` output | `python .vscode/scripts/deploy.py --radio --connect-only` (runs until stopped) |
| Build installable zips | `python bin/package/build_package.py --all-langs` |
| Validate a zip | `python bin/package/validate_ethos_manifest_zip.py dist/<zip>` |
| Lua syntax check | Build zips, unzip, `luac5.4 -p` every `.lua` (as `.github/actions/build-zips` does) |
| i18n keys check | `python bin/i18n/check_keys.py` |

Simulator deploys go to `simulators/<board>_<protocol>@<release>/scripts/gauges/` (board/protocol/release from `.vscode/settings.json`).

**Testing in the simulator without VS Code:** use [FrSkyRC/ethos-tools](https://github.com/FrSkyRC/ethos-tools). The Claude Code plugin is `ethos@ethos-tools` (already enabled in `.claude/settings.json`), or run `simulation/run_wasm.js --serve --root-directory simulators/<board>_<protocol>@<release>` directly. Lua errors appear in `node run_wasm.js getLog`, not on screen. After `reload SCRIPTS` Ethos may call `wakeup`/`write` with a nil widget (hence the nil guards); restart the simulator for a clean test. A fresh radio folder shows *Select language → Storage error → Model wizard* dialogs first.

**Done means:** no errors in the simulator log after boot, the changed UI checked with screenshots, i18n keys present in every language, and the PR workflow's checks passing (`pr.yml`).

## Releases

Same model as rfsuite / wfsuite:

| Workflow | Trigger | Output |
| --- | --- | --- |
| `pr.yml` | pull request | per-language test zips `ethos-gauges-PR-<n>-<lang>.zip` + i18n key check |
| `push.yml` | push to `main` | per-language zips `ethos-gauges-commit-<sha7>-<lang>.zip` |
| `release.yml` | tag `release/X.Y.Z` (`-rcN` = Release Candidate, pre-release) | GitHub release with per-language zips |
| `snapshot.yml` | tag `snapshot/<name>` | pre-release snapshot |

Every build goes through `.github/actions/build-zips` (package, `luac5.4 -p`, manifest validation); languages come from `i18n/*.json` (`langs.yml`).

Bump `version` in the manifest, add the `# <version>` section to `Releases.md`, commit, then push the tag. Don't push tags unless asked.

## Gotchas

- `ELECTRON_RUN_AS_NODE=1` (set inside VS Code) breaks `FrSky Suite.exe` CLI calls; `deploy.py` clears it, so do the same if you call Suite yourself.
- Ethos compiles `main.lua` to `main.luac` on load. Deploys remove stale files, but hand-copied files can leave old bytecode behind.
- After `--radio` (without `--radio-debug`) the deploy switches the radio to serial mode so it releases USB storage. Its drive disappears, and that's expected.
