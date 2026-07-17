# Build & Run

Target platform: **macOS Apple Silicon only.**

## Prerequisites

- Rust (via rustup) — `cargo` on PATH
- **cmake** (`brew install cmake`) — whisper.cpp/llama.cpp compile Metal/CoreML kernels
- **Full Xcode** (not just Command Line Tools) — `cidre` (system-audio bindings) and `compile-macos-icon.mjs` (`actool`) require it. After installing: `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer && sudo xcodebuild -runFirstLaunch`
- **pnpm** (`corepack enable pnpm`) + Node 22
- ffmpeg is auto-downloaded at build time by `build.rs` — no manual install.

## The build sequence

```bash
# 1. Build the llama-helper sidecar (Metal) and stage it where Tauri expects it
cargo build --release -p llama-helper --features metal
mkdir -p frontend/src-tauri/binaries
cp target/release/llama-helper frontend/src-tauri/binaries/llama-helper-aarch64-apple-darwin

# 2. Install frontend deps
cd frontend && pnpm install

# 3. Run the desktop app (Next.js HMR + Rust backend)
pnpm run tauri:dev
```

`tauri:dev` runs `node scripts/tauri-auto.js dev`, which auto-detects the GPU feature (Apple Silicon → `coreml`, which pulls Metal too) and launches `tauri dev -- --features <feat>`. On macOS, `whisper-rs` is compiled with metal+coreml as a baseline regardless.

### Sidecars & assets

- **`binaries/`** (gitignored) holds two `externalBin` sidecars with target-triple suffixes: `llama-helper-aarch64-apple-darwin` (built above) and `ffmpeg-aarch64-apple-darwin` (auto-downloaded by `build.rs`).
- **Models download at runtime on demand** into the OS app-data dir (`~/Library/Application Support/<bundle-id>/models/`), NOT the repo: Parakeet ONNX (~640 MB), summary GGUF (~2.6 GB), ggml whisper models. First real use downloads them once, then they're cached.

## Dev workflow: use the app, not the browser

Default to `pnpm run tauri:dev` (the desktop app). ~150 frontend files call Tauri `invoke()` — recording, transcription, summaries, DB, everything is backend-driven.

- Frontend edits (`.tsx`, styles) **hot-reload live in the app window** — no Rust rebuild.
- Rust edits trigger an automatic recompile + relaunch.
- `pnpm run dev` (plain Next.js in a browser at `localhost:3118`) has **no Tauri runtime** — every `invoke()` throws. Only useful for isolated pure-UI work.

## Testing native macOS permissions — use the signed bundle

`tauri dev` runs a **bare, ad-hoc-signed binary with no bundle identity**. macOS TCC ties every privacy grant (Calendar, Microphone, Screen Recording) to the app's code identity, so under `tauri dev`:
- **Calendar / EventKit can never be granted** — a bare binary has no LaunchServices identity, so `requestFullAccessToEvents` returns `granted=false` / stays `notDetermined` with no dialog.
- Mic/Screen grants **reset every rebuild** (each ad-hoc build gets a new cdhash).

So whenever you need real permissions (anything touching `calendar/`, mic, or system audio), run the **signed bundle** instead:

```bash
cd frontend && pnpm run app:local        # scripts/run-local.sh
```

This one command: checks the signing cert, stages the `llama-helper` sidecar on first run, builds `pnpm tauri build --debug --bundles app` with the stable **`Ari Dev Signing`** identity, then kills+`open`s `target/debug/bundle/macos/Ari Meeting.app`. Grant Calendar/Mic/Screen **once**; the stable identity makes the grants persist across rebuilds.

Key facts:
- **The signing identity** is a one-time self-signed cert (Keychain Access ▸ Certificate Assistant ▸ *Self Signed Root* / *Code Signing*, named `Ari Dev Signing`), wired into `bundle.macOS.signingIdentity` in `tauri.conf.json`. Without a stable identity, TCC re-prompts every build.
- `--bundles app` skips the flaky `bundle_dmg.sh`; `createUpdaterArtifacts: false` avoids the `TAURI_SIGNING_PRIVATE_KEY` error that otherwise exits non-zero after a good build.
- **The frontend is statically baked into the `.app`**, so ANY change (frontend OR Rust) needs a rebuild + relaunch to see it in the bundle — there is no HMR here. Use plain `pnpm run tauri:dev` for fast pure-UI iteration where permissions don't matter.
- **App data persists across builds**: SQLite DB (settings, recordings, calendar cache/selection) lives in `~/Library/Application Support/com.meetily.ai/`, keyed by bundle id — rebuilding never clears it. Reset a stuck grant with `tccutil reset Calendar com.meetily.ai` (or `Microphone` / `ScreenCapture`).
- `pnpm run tauri:dev:signed` (`scripts/dev-signed.sh`) re-signs the bare dev binary — it fixes mic/screen persistence but **still cannot grant Calendar** (no LaunchServices identity). Prefer `app:local`.

## QA launch modes

`pnpm run tauri:dev:qa*` variants set `NEXT_PUBLIC_MEETILY_NATIVE_QA_MODE` (`routes` | `onboarding` | `meeting-error`) + a paired `tauri.qa.*.conf.json` with a distinct bundle identifier so QA installs don't collide with real app data. They bypass onboarding, deep-link to a route/overlay/tab, force a theme, and skip auto model-downloads. Config: `src/lib/native-qa-mode.ts`.

## Checks (run before committing non-trivial changes)

```bash
# Frontend (from frontend/)
node --test tests/lib/*.test.mjs        # note: no package.json test script
npx tsc --noEmit
pnpm lint && pnpm build

# One TS test is Bun-only:
bun test tests/lib/blocknote-markdown.test.ts

# Rust (from repo root)
cargo check
cargo test
```

Many frontend tests are **source-regex / "visual-system" assertions** (they read source + `DESIGN.md`/`DESIGN.json` and assert conventions). Changing UI copy, tokens, or lifecycle strings will fail them unless you update the tests in lockstep.

## Debugging

- Rust logs: `RUST_LOG=debug` (or scoped, e.g. `RUST_LOG=app_lib::audio=debug`).
- DevTools in the app: `Cmd+Shift+I`.
- Hot-path logging uses `perf_debug!` / `perf_trace!` (compiled out of release) — not raw `log::debug!`.
