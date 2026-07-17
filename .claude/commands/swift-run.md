---
description: Build and launch a Swift app/sidecar so you can see it running (analog of the Tauri app:local).
---

Launch a Swift executable and observe it — the Swift-era analog of today's `pnpm run app:local`.

Resolve what to run from `$ARGUMENTS`:

- **A sidecar** (`apple-helper`, `ari-notch`, `diarize-helper`) — these are stdio/NDJSON executables, not windows. Build and drive them over stdin:
  - `cd <sidecar> && swift run <exe>` then send NDJSON on stdin (see the sidecar's `Sources/**/Protocol.swift` for the wire contract; a `probe`/`shutdown` line is the cheapest smoke test).
- **The macOS `Ari` app** (Phase 2+, once it exists):
  - Prefer **XcodeBuildMCP**: `build_run_macos_proj` (builds + launches), then `screenshot` / `get_macos_app_logs` so you can *see* the running app and read its logs.
  - Signed-bundle path mirrors the Tauri `app:local` flow: build a Developer-ID-signed `.app` (hardened runtime, **no App Sandbox** — plan decision), then `open` it. Native TCC grants (Mic/Screen/Calendar) persist across rebuilds under a stable signing identity.
- **The iOS `Ari Lite` app** (Phase 6 — built only after the macOS Swift migration completes; full engine *minus speaker ID*, not a read-only viewer): boot a simulator (`xcrun simctl boot` / MCP `boot_sim`), `install_app_sim`, `launch_app_sim`, then `screenshot` to verify the UI.

Always confirm the thing actually ran (window up / logs clean / NDJSON reply received) — a green build is not a green run.
