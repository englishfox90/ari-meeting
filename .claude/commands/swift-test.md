---
description: Run the Swift test suites — AriKit + sidecars (swift test) and app targets (xcodebuild test).
---

Run the Swift tests and report honestly (show failing output; never declare a partial pass green).

- **AriKit + sidecars** (SwiftPM packages):
  - MCP: `swift_package_test` on the package dir.
  - CLI: `cd AriKit && swift test` (or `cd <sidecar> && swift test`).
- **App targets** (Phase 2+): `xcodebuild test` via XcodeBuildMCP `test_macos_proj` / `test_sim`.

What the tests protect (plan principle 6 — preserve the invariants as ported suites):
- **Recall safety shell** — loopback-only local path, bounded context, **never invents citations**. When the recall engine ports to `AriKit.Recall`, these are the first tests that must be green (dual-run against the Rust incumbent per principle 2).
- **Consent-before-record** and **No-Fake-State** — behavioral invariants that survive the port verbatim.

New code uses the **Swift Testing** framework (`import Testing`, `@Test`/`@Suite`, `#expect`); XCTest only when porting an existing XCTest suite.

If `$ARGUMENTS` names a target, scope to it; otherwise run AriKit and any sidecar touched by the current diff.
