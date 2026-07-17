# CLAUDE.md

Guidance for Claude Code working in this repository. Keep this file lean — detailed context lives in `.claude/` and is imported below.

## What this is

**Ari Meeting App** — a private, single-user, **macOS-only** meeting-intelligence tool. It records and transcribes meetings, then produces summaries that are aware of *who is in the room, who owns the meeting, and what kind of meeting it is*.

It **began** as a fork of `henryvn27/meetily_improved` (itself a fork of Zackriya's Meetily, MIT), and inherited a mature Tauri/Rust engine from it: macOS audio capture, native Whisper + Parakeet STT, a multi-provider LLM layer, SQLite persistence, and summary templates. On that foundation we built persistent speaker identity, per-person knowledge, calendar awareness, theme summaries, meeting-series ledgers, and MCP/agent extensibility. **It is now Arivo's own product**, developed in our own direction — the fork is history that explains the engine's shape, not a constraint on how we evolve it.

The product north star is `meeting-intelligence-prd.md` (repo root). Read it before any feature work.

## How we work: this is our own codebase

The project began as a fork but is now **Arivo's own**. We own the entire tree — inherited files included — and may refactor, reorganize, rename, or delete any of it. There is no upstream rebase to protect, so the former *additive-only* rule is **retired** (we no longer track or pull from Meetily).

What governs now is ordinary good-engineering discipline: refactor deliberately (for clarity/correctness, not churn), keep the codebase coherent with its conventions and its own docs, keep the checks green, and extend the engine's tests rather than dropping them. Preferring new modules/tables/commands for net-new capability is still good practice — for separation of concerns, not fork-preservation. Full detail in `.claude/rules/codebase-ownership.md`.

## Fast facts

- **Stack:** Tauri 2 (Rust, lib crate `app_lib`) + Next.js 14 (App Router, static export) + React 18 + TypeScript.
- **Build/run (macOS Apple Silicon):** `cargo build --release -p llama-helper --features metal` → copy binary to `frontend/src-tauri/binaries/llama-helper-aarch64-apple-darwin` → `cd frontend && pnpm run tauri:dev`. Requires cmake + full Xcode.
- **Testing native permissions (Calendar/Mic/Screen):** `cd frontend && pnpm run app:local` builds+launches a signed `.app`. `tauri dev` can't grant Calendar and resets mic/screen each build — details in `build-and-run.md`.
- **Frontend↔Rust invoke args — two casing layers:** top-level keys are **camelCase** (Tauri v2 maps them to snake_case Rust params); keys nested inside a struct param follow that struct's serde rule (snake_case if unrenamed). Getting the top-level layer wrong hard-errors on required params and silently drops `Option`s — see `tauri-ipc.md`.
- **Fully native — no server.** Persistence, transcription, and summarization all run in the Rust/Tauri core. The Python `backend/` is **dead** and has been moved to `archive/`. Never reintroduce a `localhost:5167` HTTP dependency.
- **Verify a module is live before editing it:** the tree once carried dead files with near-identical names to live ones (`*-old.rs`, `*.backup`, `lib_old_complex.rs`, `audio_v2/`); those have now been removed. Still confirm a module is declared/registered in `lib.rs` before building on it.
- **Swift-native migration is underway — net-new work is Swift-first.** We are migrating to a 100% Swift, Apple-only codebase (`plans/swift-migration-plan.md`). The Tauri app stays shippable and gets bugfixes in place, but new features land in the Swift tree, not the Rust/React app. Shared domain code lives in `AriKit/` (scaffold today); existing Swift sidecars are `apple-helper/`, `ari-notch/`, `diarize-helper/`. Rules in `.claude/rules/swift-conventions.md`. **Tooling:** XcodeBuildMCP (`.mcp.json`); commands `/swift-build` `/swift-run` `/swift-test` `/implement-feature`; agents `swift-architect` (plan-only) → `swift-implementer` → `swift-code-reviewer`; skills `grdb` + `sqlite-schema` for the Store port; a PostToolUse SwiftFormat/SwiftLint hook + a SessionStart toolchain report (both degrade to no-ops until `brew install swiftformat swiftlint`). Third-party reference sample projects (Apple docs samples, vendor examples) live in the **gitignored `samples/`** — read-only patterns for the port, never imported/built/shipped; see `samples/README.md`.

## Detailed context (imported)

@.claude/rules/codebase-ownership.md
@.claude/rules/swift-conventions.md
@.claude/context/product.md
@.claude/context/architecture.md
@.claude/context/build-and-run.md
@.claude/rules/tauri-ipc.md
@.claude/rules/coding-conventions.md
@.claude/rules/platform-and-deps.md
@.claude/rules/no-legacy-files.md
@.claude/rules/design-system.md
@.claude/context/open-questions.md

Backend- and frontend-scoped rules live in `frontend/src-tauri/CLAUDE.md` and `frontend/CLAUDE.md` and load automatically when you work in those trees.
