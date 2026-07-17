---
description: Build the Swift tree — AriKit package and/or the Swift sidecars — via XcodeBuildMCP or swift build.
---

Build the Swift side of the migration. Prefer **XcodeBuildMCP** tools (`.mcp.json`) so build output/errors come back typed; fall back to the CLI when the MCP server isn't up.

Pick the target from `$ARGUMENTS` (default: `AriKit`):

- **`AriKit`** (shared package):
  - MCP: `swift_package_build` on `AriKit/`.
  - CLI: `cd AriKit && swift build`
- **A sidecar** (`apple-helper`, `ari-notch`, `diarize-helper`):
  - CLI: `cd <sidecar> && swift build -c release` (these ship as release binaries staged into `frontend/src-tauri/binaries/` with a `-aarch64-apple-darwin` suffix — see each sidecar's `Package.swift` header).
- **The macOS `Ari` app target** — does not exist yet (Phase 2). Once it does: `build_macos_proj` / `build_device_proj` via XcodeBuildMCP against the `.xcodeproj`/workspace.

Notes:
- Deployment floor is **macOS 26 / iOS 26**, Swift 6 language mode. A `Sendable`/actor-isolation error is a real concurrency bug — fix it, don't suppress it.
- Report failures with the actual compiler output. Don't declare success on a partial build.
- First MCP call auto-installs XcodeBuildMCP via `npx` — that one-time fetch is expected.
