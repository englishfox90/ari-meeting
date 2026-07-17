# Rule: Platform Scope & Dependencies

## macOS-only

This project targets **macOS Apple Silicon only** (PRD non-goal: cross-platform). Do NOT add, maintain, or resurrect:

- Windows/Linux build scripts (`.bat`, `.ps1`, `.cmd`)
- CUDA / Vulkan / HIP / OpenBLAS build paths for our own use (the Cargo feature flags exist for upstream compatibility; don't wire new tooling around them)
- Docker files / the Python backend

The macOS acceleration path is Metal + CoreML, enabled by default for `whisper-rs` on macOS.

## Never commit binaries or models

These are gitignored and provisioned at build/runtime — never commit them:

- `frontend/src-tauri/binaries/*` (llama-helper, ffmpeg sidecars)
- Any model weights: `*.bin`, `*.gguf`, ONNX models, `**/models/`
- Build artifacts: `target/`, `.next/`, `out/`, `node_modules/`
- Never commit installers or vendored toolchains (e.g. the removed `vs_buildtools.exe`).

## Don't bump git-pinned native crates

These are pinned to specific git revs for native-ABI reasons. Do NOT bump without explicit approval — a casual bump can break the build in subtle, platform-specific ways:

- `cpal` (git rev), `cidre` (git rev `a9587fa` — macOS system audio), `silero_rs` (git), `esaxx-rs` (git branch)
- `whisper-rs` 0.13.2, `ort` 2.0.0-rc.10 (ONNX Runtime), `llama-cpp-2` (in llama-helper)

## Build prerequisites are real

The build genuinely requires **cmake** and **full Xcode** (not just Command Line Tools) — `cidre` and the icon compiler need `xcodebuild`/`actool`. If a build fails with `cidre`/`xcodebuild`/`actool` errors, the fix is almost always the Xcode toolchain, not the code. See `../context/build-and-run.md`.
