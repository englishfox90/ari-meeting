# Rule: Swift Conventions (the Swift-native tree)

This project is migrating to a **100% Swift, Apple-only** codebase (`plans/swift-migration-plan.md`). Two Swift worlds coexist during the strangler migration:

- **Sidecars** (`apple-helper/`, `ari-notch/`, `diarize-helper/`) — existing SwiftPM executables driven over NDJSON stdio. Live today.
- **`AriKit/`** — the shared domain package that the macOS `Ari` app (live: `Ari/Ari.xcodeproj`) and the later iOS `Ari Lite` app consume. **Substantially real (2026-07-21)**: Models, Store (GRDB + legacy importer), Recall (full safety shell), Engine (STT/summary/providers/persons/diarization), plus the separate `AriCapture`, `AriViewModels`, `AriKitEngineMLX`, and `AriKitDiarizationFluidAudio` targets — 750+ tests. Remaining engine gaps are tracked in `plans/swift-migration-plan.md` ("Still deferred").

**The Rust/Tauri app is FROZEN (decided 2026-07-16).** All of F1–F8 ship on the current Rust stack as-is — that frozen build is the baseline. Forward is **Swift-first and Swift-only as the go-forward track**: net-new features land in the Swift tree; the Rust app gets *reactive maintenance only*, and even those fixes are done Swift-side when the seam reasonably allows. We never extend the Rust/React app with net-new capability (plan principle 8, WIP limits). There is no parallel "keep building on Rust" track.

## Non-negotiables

- **Swift 6 language mode, strict concurrency.** New targets pin `.swiftLanguageMode(.v6)`. Resolve `Sendable`/actor-isolation warnings — do not silence them with `@unchecked Sendable` or `nonisolated(unsafe)` unless you can justify it in a comment.
- **Deployment floor: macOS 26 / iOS 26.** This is the accepted "latest-OS-only" constraint (plan principle 7) — SpeechAnalyzer + FoundationModels are 26+. No availability guards needed below the floor; do not add `@available` shims for older OSes.
- **`@Observable`-MVVM for UI state. We are NOT adopting TCA** unless that decision is explicitly revisited. View models are `@Observable` classes; views are value-type SwiftUI. No Redux/Composable-Architecture patterns.
- **Store is plain GRDB for now** (decided 2026-07-17, revising the 2026-07-16 SQLiteData pick) — real SQLite on GRDB semantics via `FetchableRecord`/`PersistableRecord` records + a repository layer. SQLiteData v1.7.0 turned out to be a `@Table`/structured-queries paradigm (not a superset of plain records) with ~8 heavy transitive deps and no benefit until CloudKit lands at **Phase 5.5**; since SQLiteData itself rests on GRDB, starting on GRDB keeps the same semantics and defers the SQLiteData-vs-hand-rolled-sync choice to 5.5. Persistence goes through the store's repository layer only (the Swift mirror of "DB access through repositories only"); no raw SQLite handles in feature code. Use the `grdb` + `sqlite-schema` skills. Store plan: `docs/plans/arikit-store.md`.
- **One process owns the database** (plan principle 3). Never open the SQLite file from two ORMs/processes. During transition, the DB owner is the Rust engine; the Swift shell talks to it over the engine protocol until the store ports.
- **Preserve the invariants as ported tests** (plan principle 6): the recall safety shell (loopback-only, bounded context, never-invents-citations), consent-before-record, and No-Fake-State survive the port as Swift test suites (Swift Testing / XCTest), not just intentions.

## Style & structure

- **Formatting is mechanical** — `.swiftformat` (repo root) owns whitespace/wrapping; `.swiftlint.yml` owns lint. The PostToolUse hook runs both on each edited `*.swift` file. Don't hand-fight the formatter.
- **Tests:** prefer the **Swift Testing** framework (`import Testing`, `@Test`/`@Suite`, `#expect`) for new code; XCTest is fine when porting an existing XCTest suite.
- **One package, gated growth:** put shared domain code in `AriKit`; keep app-only code (SwiftUI screens, capture) in the app target. Each `AriKit` feature module gets a scoped `CLAUDE.md` as it grows — same pattern as the Tauri tree's `frontend/` / `src-tauri/` scoped files.
- **Design system is Marginalia** (`brand/` — `BRAND.md` + `tokens.json`), NOT the Arivo Signal Desk system (root `DESIGN.json`/`DESIGN.md`, which governs the Tauri app only). All SwiftUI is themed from `brand/tokens.json` from the first screen.

## Build & test (agent-driven, no human in Xcode)

- Prefer the **XcodeBuildMCP** tools (configured in `.mcp.json`) for typed build/test/run + log/screenshot capture — the agent can *see* the running app.
- CLI fallbacks: `swift build` / `swift test` for `AriKit` and the sidecars; `xcodebuild` for app targets once they exist.
- Commands: `/swift-build`, `/swift-run`, `/swift-test`, `/implement-feature`. Agents: `swift-architect` (plan-only), `swift-implementer`, `swift-code-reviewer`. Skills: `grdb`, `sqlite-schema` for the Store port.
