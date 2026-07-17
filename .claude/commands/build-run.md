---
description: Build the llama-helper sidecar and launch the Ari Meeting desktop app (macOS).
---

Build and run the Ari Meeting desktop app on macOS Apple Silicon.

Steps:

1. Confirm prerequisites are available (cargo, cmake, pnpm, and full Xcode active via `xcode-select -p`). If Xcode isn't active or a `cidre`/`actool` error appears, that's the fix — not the code.
2. Build the sidecar and stage it:
   ```bash
   cargo build --release -p llama-helper --features metal
   mkdir -p frontend/src-tauri/binaries
   cp target/release/llama-helper frontend/src-tauri/binaries/llama-helper-aarch64-apple-darwin
   ```
3. Ensure frontend deps: `cd frontend && pnpm install`
4. Launch: `pnpm run tauri:dev` (auto-detects coreml/metal; runs Next.js HMR + Rust backend).

Notes:
- Run `tauri:dev` as a background process and monitor its output for the compile to finish and the window to launch. The first build compiles whisper.cpp/llama.cpp/ONNX natively — it takes several minutes.
- ffmpeg auto-downloads at build time; models (Parakeet ~640 MB, summary GGUF ~2.6 GB) download at runtime on first use into the app-data dir.
- For isolated pure-UI work only, `pnpm run dev` serves Next.js in a browser (no Tauri runtime — `invoke()` will throw).

Full detail: `.claude/context/build-and-run.md`.
