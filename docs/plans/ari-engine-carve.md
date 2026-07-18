# ari-engine carve — implementation plan

Status: implementation plan for the remaining work of **Phase 1.5** (`plans/swift-migration-plan.md`). The wire protocol and service map are already designed and frozen in `docs/plans/engine-extraction.md`; this doc plans the **code carve** that implements it. Read that doc first — this one does not re-specify the protocol, it sequences the refactor that realizes it.

Companion: `docs/plans/engine-extraction.md` (protocol + service map + deletion appendix + open questions), `plans/swift-migration-plan.md` §Phase 1.5.

## The actual problem

The method mapping in `engine-extraction.md` is close to mechanical. The hard part is **severing Tauri coupling**, measured in the tree today:

- **282** `AppHandle` / `app_handle` references
- **125** `tauri::State<…>` usages
- **74** `app.emit(...)` call sites across ~20 files
- **31** `tauri::async_runtime` uses
- **2** `run_on_main_thread` prompts (the two `[client-side]` permission paths)
- Sidecar spawning via Tauri's shell plugin in **3** files (`lib.rs`, `summary/claude_cli.rs`, `summary/summary_engine/client.rs`)

A headless engine has no `AppHandle`, no `State`, no `app.emit`, no Tauri sidecar resolver, no main-thread run loop. Every one of those touchpoints must be replaced with something the engine owns. Moving all of it in one commit is un-reviewable and leaves the build red for days — so **the carve is itself a strangler**: abstract in place → extract crate (still in-process) → add protocol → flip to cross-process. The build stays green and the app stays shippable at every step.

## Guiding constraints (from the existing rules)

- **Single DB owner** — the repository layer does not move logically; it just becomes reachable only from inside the engine. No raw SQLite outside the engine ever.
- **Behavior byte-identical from the frontend's view** — no `frontend/src` file changes in this phase. Every `invoke`/`listen` call site is unaware anything moved. That is the regression bar.
- **`[client-side]` split** — native file pickers + main-thread TCC prompts stay in the host (see `engine-extraction.md` cross-cutting rules). The engine gets the *result* (a path, a granted/denied bool), never opens a window.
- **Preserve recall invariants** (`local_recall_tests`) and every other engine test — port, don't drop.
- Don't reintroduce `localhost:5167`. Don't bump git-pinned native crates.

## Target crate topology

```
ari-engine/                      (NEW — workspace member)
  crate ari-engine (lib)         all moved engine logic; Tauri-free
  crate ari-engine (bin)         headless daemon: NDJSON stdio loop → dispatch()
ari-protocol/                    (NEW — tiny lib) envelope types shared by engine + host
frontend/src-tauri/              the Tauri HOST — becomes a thin client
  spawns ari-engine, forwards invoke → request, relays event/stream → app.emit
```

`ari-protocol` is deliberately separate and dependency-light (serde only) so the future Swift client has a Rust reference for the exact envelope shapes, and so neither engine nor host depends on the other's internals.

## The abstractions that replace Tauri

Every Tauri touchpoint maps to one owned abstraction. Introducing these **in place, in the current crate** is Stage A — no code moves out, the build stays green, and each is independently reviewable. Refined against the 2026-07-17 coupling map; the `Engine`/`EventSink`/`Paths` scaffold is **built and `cargo check`-green** (`frontend/src-tauri/src/engine/`).

| Tauri touchpoint | Reality | Replacement | Status |
|---|---|---|---|
| `app.emit(channel, payload)` | 74 sites / 20 files | `EventSink` trait — `emit_value` + `emit<T: Serialize>` helper; `TauriEventSink` wraps `AppHandle::emit` now, NDJSON-stdout sink later | **Built.** Converted per-service (see Stage A), not as a global sweep — emit sites live inside the same command logic that needs `&Engine`. |
| `tauri::State<AppState>` (db) + the 5 other `.manage()`d states | `AppState` = `{ db_manager }`, **deferred-init** (absent until a first-launch flow; host uses `try_state`). 5 managed states, one (`SystemAudioDetectorState`) **dead**. | one `Arc<Engine>` carrying `db` (deferred `Option`), `Paths`, `EventSink`, `ParallelProcessorState`, summary `ModelManagerState`, recall `EmbedModelManagerState` | **Built.** Collapses 6 states → 1. `Engine` is **non-generic** (notification manager excluded, below). Commands take `&Engine` / `State<'_, Arc<Engine>>`. |
| Path/resource resolution (`app.path()…`) | ~25 `app_data_dir` + 1 `resource_dir` (templates) + `app_log_dir` + `app_config_dir` | `Paths` resolved once at startup; subdir helpers reproduce today's layout (`models`, `models/summary`, `models/embeddings`, `templates`) | **Built** (`Paths::from_tauri`). App-data location unchanged (bundle-id keyed). |
| Sidecar spawn | **Already 100% Tauri-free** — raw `tokio::process::Command` + per-sidecar resolvers (env → `current_exe()`-relative triple-suffix → fuzzy → dev fallback). Zero shell-plugin use. | `SidecarHost` shrinks to a thin holder, or is skipped — resolvers port verbatim to a headless binary | **Deferred, off critical path.** The feared coupling barely exists. |
| `NotificationManager<tauri::Wry>` | Runtime-generic, Tauri-plugin-typed — **cannot** live headless | **Host capability** (`Notifier` seam): engine decides *when*, host *shows* | Designed when the `notifications`/`system` service migrates. The one genuinely tricky coupling. |
| `run_on_main_thread` TCC prompts + file pickers | exactly 2 prompts (`trigger_microphone_permission`, `calendar_request_access`) + pickers | **Stay in host** as `[client-side]` | Engine only *checks* status; host shows the prompt, reports the outcome. |

## Stages

### Stage A — Decouple in place (one crate, one process, always green)

Goal: remove every direct Tauri dependency from engine *logic* without moving a single file out of `frontend/src-tauri`. After Stage A the app is unchanged at runtime but the engine code no longer names `AppHandle`/`State`/`app.emit` directly.

**A1 — ✅ DONE.** `ari-protocol` crate (workspace member): `Message` (request/response/event/stream), `WireError`, `StreamEvent`, constructors — byte-exact to `engine-extraction.md` §Transport. 13 round-trip tests green; `cargo check --workspace` clean.

**A2 (trait) + A3 (context) — ✅ DONE (scaffold).** `frontend/src-tauri/src/engine/`: `EventSink` trait + `TauriEventSink` (Stage-A impl wrapping `AppHandle::emit`), `Paths` (`from_tauri` + layout helpers), and the `Engine` context (deferred-`Option` DB + the 3 live manager sub-states, non-generic, notification manager excluded). `mod engine;` declared; `cargo check`-green, no new warnings. Not yet *wired* into `run()` or *consumed* by commands — that's A-wire + A-migrate.

**A-wire — install `Engine` as a managed state (additive, nothing breaks).** In `run()`: build `Paths::from_tauri`, wrap `AppHandle` in `TauriEventSink`, `.manage(Arc::new(Engine::new(paths, events)))`, and call `engine.set_db(mgr)` at the 3 sites that manage `AppState` today (`database/setup.rs`, `database/commands.rs` ×2). Keep the old 5 `.manage()` + `AppState` in place *in parallel* so no command breaks before it migrates. This makes `State<'_, Arc<Engine>>` available.

**A-migrate — the fan-out (merges the old A2-emit + A4-state into one per-service pass).** Emit sites and state access live in the *same* command logic, so converting a service does both at once: rewrite its commands to take `State<'_, Arc<Engine>>` (or `&Engine`), reach DB/sub-state through `engine.*()`, and emit through `engine.events().emit(...)`. Service-by-service down the `engine-extraction.md` grouping — `recording`, `transcription`, `summary`, `meetings`, `settings`, `recall`, `providers`, `calendar`, `persons`, `series`, `diarization`, `notch`, `apple`, `onboarding`, `database`, `system`. **This is the parallelizable stage**: each service is a mostly-disjoint file set + its own commit, `cargo check`/`cargo test` green after each; the shared `lib.rs` shim edits are serialized by the orchestrator. Retire each old `.manage()` state (and finally `AppState`) once its last consumer migrates. The `notifications`/`system` pass also introduces the `Notifier` host-capability seam. Sidecar spawning needs no dedicated step — it's already Tauri-free.

Exit A: engine logic reaches everything through `&Engine`/`EventSink`/`Paths`; zero `app.emit`/`tauri::State` inside logic (only in the thin `#[tauri::command]` host shims). App runs identically.

#### Per-service migration recipe (proven on `onboarding`, 2026-07-17)

The reference migration of `complete_onboarding` (green) establishes the pattern every A-migrate agent follows:

1. **Split each stateful command into a pure `*_impl` fn + a thin `#[tauri::command]` shim.** The `_impl` takes `engine: &Engine` (plus plain args); the shim takes `engine: tauri::State<'_, std::sync::Arc<Engine>>` and calls `impl(&engine, …)` — `&State<Arc<Engine>>` **deref-coerces to `&Engine`**, so the shim is a one-liner. Keep the shim's fn name identical → `generate_handler!` in `lib.rs` is untouched.
2. **DB:** replace `state.db_manager.pool()` with `let db = engine.db().await?; let pool = db.pool();`.
3. **Sub-state:** `State<'_, ModelManagerState>` → `engine.summary_models()`; `EmbedModelManagerState` → `engine.embed_models()`; `ParallelProcessorState` → `engine.parallel()`.
4. **Events:** `app.emit("ch", payload)` → `engine.events().emit("ch", payload)`.
5. **Residual Tauri touchpoints stay + get documented, not forced:** an `AppHandle` still needed for the Tauri **store plugin** (`app.store(...)`), native pickers, or main-thread prompts stays as a shim param and is flagged as a deferred seam in a doc comment — the `_impl` can't fully move to `ari-engine` (Stage B) until that seam has a headless home. Commands using *only* the store/emit and no `AppState` need no Stage-A change at all.
6. **Verify** `cargo check -p ari-meeting` green (in the agent's worktree); don't touch `lib.rs` or other services' files.

**New deferred seam discovered:** the **Tauri store plugin** (`tauri_plugin_store`, `app.store("*.json")`) — used by onboarding (and to be grepped for elsewhere). Like `Notifier`, it needs a headless home before Stage B: either a `Paths`-based JSON file the engine owns, or a host capability. Tracked here; resolved before the owning service's `_impl` moves crates.

#### A-migrate progress log

Approach: parallel Sonnet agents in the **main tree** (not worktrees — `isolation: worktree` pins to the session-start commit and can't see in-session foundation commits), disjoint files, compiling disabled, orchestrator runs one **central `cargo check`** per batch. Clean and fast (warm cache); the central check caught one over-generified impl in batch 1.

- **✅ AppState / manager-state migration COMPLETE — 14 services, ~102 commands, `cargo check` (lib+tests) green, 33 recall tests pass:**
  - reference: `onboarding` (1) — `9778aa1`
  - batch 1 (`a3b3abd`): `persons` (18), `meeting_series` (11), `diarization` (10)
  - batch 2 (`7da1e76`): `meeting_time` (1), `summary` (9), `recall/conversations` (5), `calendar` (10)
  - round 3 (`2b2bd54`): `api/api.rs` (21), `summary_engine` (8), `recall/embed_models` (4), `parallel_commands` (1) + cross-module caller reconcile (audio/whisper/parakeet internal callers → `app.state::<Arc<Engine>>()`) + `Engine::event_sink()`
  - round 4 (`cafb0ac`): `recall/commands` (4), `recall/stream` (streaming) — **last AppState consumers**; `EventSink::emit` made lifetime-generic
  - **Zero `tauri::State<'_, AppState>` / manager-state consumers remain.** Providers (ollama/openai/anthropic/groq/openrouter) never used AppState — no DB migration needed.
- **✅ Emit sweep — DONE.** `app.emit`→`engine.events()`/`event_sink()` across whisper/parakeet/ollama/apple (`217a2d9`), the full audio subsystem — worker/level-monitors/saver/manager/recording_commands/import/retranscription (`1e92f81`), and database/calendar-sync (`b818ed9`). `EventSink::emit` made lifetime-generic; `Engine::event_sink()` added for `'static` callbacks. The `lib.rs` recording commands route emits through `recording_commands`, which was swept. **Intentionally left host-side** (per the "needs a window/main-thread → client" rule): `tray.rs` + `notch/bridge.rs` emits, and `engine/events.rs` (which IS `TauriEventSink`).
- **✅ State retirement — DONE.** Manager states + dead `SystemAudioDetectorState` retired (`08d97ed`); **`AppState` fully retired (`2c6fda9`)** — struct + `state` module deleted, Engine is the **single DB owner** (`set_db`), all 9 readers on `engine.db()`, 3 writers install into the engine. Only the Runtime-generic `NotificationManagerState` remains host-managed.
- **⇒ Stage A is functionally COMPLETE:** zero `tauri::State<AppState>`/manager-state consumers; every command + startup/shutdown path reaches DB/sub-state via `&Engine`; no engine-logic path emits through a raw `AppHandle`.
- **✅ Stage-B host-capability seams RESOLVED (`1f57bd1`, 2026-07-17)** — done ahead of the crate extraction rather than during it:
  - **Seam 1 (store plugin):** `engine/json_store.rs` owns `onboarding-status.json` + `recording_preferences.json` at the *same* app-data path the plugin used (byte-identical location — existing files load unchanged); `onboarding.rs` + `audio/recording_preferences.rs` migrated off `tauri_plugin_store`. Dead HTTP-era `get_auth_token`/`store.json` reader deleted. Host-side stores (`tray.rs` `app-preferences.json`, `notch/bridge.rs` `settings.json`) intentionally left on the plugin.
  - **Seam 2 (`Notifier`):** `engine/notifier.rs` — Runtime-free `Notifier` trait + `TauriNotifier` wrapping `NotificationManagerState<Wry>`, deferred-installed on `Engine` after the manager inits (mirrors `set_db`). `notch/scheduler.rs` reaches notifications via `engine.notifier()`. `lib.rs` recording start/stop notifications stay host-side (host lifecycle glue).
  - **Seam 3 (Paths):** the raw `app_data_dir()` holdouts (summary/whisper/parakeet/persons/diarization/meeting_series/database-commands) now route through `engine.paths()`; `diarization` segmentation scratch uses `std::env::temp_dir()` (fully AppHandle-free). **`database/manager.rs` stays AppHandle-based** — it bootstraps the DB *before* the Engine exists, so routing it through `engine.paths()` would be circular; the daemon (Stage D) resolves its path natively.
  - `cargo check` green; 448 lib tests pass incl. recall invariants (2 pre-existing unrelated failures).
- **Build-test points:** recording path validated at runtime after the audio emit sweep (✅ 2026-07-17, twice). The AppState retirement changed DB-init/shutdown wiring — a launch→record→quit sanity pass is worth doing before Stage B.

#### Stage B pre-flight — exact seam map (grepped 2026-07-17)

The three host-capability seams, with every real call site pinned so B1 starts from coordinates, not a re-grep. (Atomic `.store()` calls are noise — the store *plugin* is `tauri_plugin_store::StoreExt` / `app.store("*.json")`.)

**Seam 1 — Tauri store plugin (`app.store`).** Five JSON stores, split by owner:
  - **Engine-side (need a headless home — a `Paths`-based JSON the engine owns):**
    - `onboarding.rs` — `onboarding-status.json` (load/save/reset onboarding status; 5 call sites).
    - `audio/recording_preferences.rs` — `recording_preferences.json` (load/save recording prefs).
  - **Host-side (stay in the host — window/menu/notch concerns):**
    - `tray.rs` — `app-preferences.json` (`menu_bar_enabled`); menu-bar is host UI.
    - `notch/bridge.rs:773` — `settings.json` (`showNotch` read); notch is host UI.
  - **Dead — delete, don't port:** `api/api.rs:440` `get_auth_token` → `store.json`/`authToken` is `#[allow(dead_code)]`, a vestigial HTTP-era leftover. Remove during the carve.

**Seam 2 — `Notifier` (`NotificationManagerState<R>`).** Runtime-generic, stays host-managed (it holds `NotificationManager<tauri::Wry>`). Consumers:
  - `lib.rs` (recording start/stop notifications — host setup block, lines ~131/193/371/440–479) and `notch/scheduler.rs:305/323` (meeting-reminder path). The engine can't hold `<R: Runtime>` — Stage B needs a thin `Notifier` trait (engine-side) whose Tauri impl lives host-side and is injected, same shape as `EventSink`/`TauriEventSink`.

**Seam 3 — `app_config_dir` / `app_data_dir` Paths.** Mostly already centralized: `engine/paths.rs` replaces ~25 scattered calls, and the recall/summary/api hot paths already read `engine.paths().app_data`. Raw `app.path().app_data_dir()` **holdouts** still to route through `Paths` in Stage B: `summary/service.rs:474`, `whisper_engine/commands.rs:16`, `parakeet_engine/commands.rs:18`, `persons/commands.rs:443/473`, `diarization/engine.rs:419` + `diarization/tuning.rs:132`, `database/commands.rs:87/239/250`, `database/manager.rs` (init/migrate paths), `meeting_series/ledger.rs:474`. Host-only (`app_config_dir` in `app_config.rs:37`, `app_log_dir` in `lib.rs:464`, `tray.rs` data-dir) stay host-side.

### Stage B — Extract the `ari-engine` library crate

B1. Create `ari-engine` lib crate; move the decoupled engine modules into it (audio, transcription engines, summary, recall, calendar, persons, series, diarization, database, providers, notch/apple bridges, config). The `#[tauri::command]` shims stay behind in the host.

**B1 progress:**
- **✅ Crate scaffolded (`923e6d9`, 2026-07-17)** — `ari-engine` is an empty workspace-member lib crate; the host (`ari-meeting`) depends on it. Compiling target ready; modules migrate in one at a time, workspace green after each.
- **✅ Provider clients moved (`c5b5b57`, 2026-07-17).** `anthropic`/`openai`/`groq`/`openrouter` → `ari-engine::providers::{anthropic,openai,groq,openrouter}`; thin `#[tauri::command]` shims stay host-side at the same module path, `generate_handler!` untouched. **`ollama` remains deferred** — `pull_ollama_model` takes `State<Arc<Engine>>` for progress emits, so it can't move until `engine/` itself moves.
- **✅ `config.rs` moved (`efb2eeb`, 2026-07-17).** Pure model-catalog constants, zero Tauri deps → `ari-engine::config`, re-exported at `crate::config`.
- **✅ Shared domain-model structs moved (`46dbc9c`, 2026-07-17).** `MeetingDetails`/`MeetingTranscript`/`TranscriptSearchResult`/`TranscriptSegment` (from `api/api.rs`), `NewPerson` (`persons/models.rs`), `CustomOpenAIConfig` (`summary/mod.rs`) → `ari-engine::models`, re-exported at their old paths. Pure serde IPC payload shapes, zero Tauri deps.
- **⇒ Next move — the database layer.** `database/repositories/*.rs` and `database/models.rs` are already Tauri-free (every repository fn takes `&SqlitePool` directly, never `&DatabaseManager`/`AppHandle`) → move to `ari-engine::database`, re-exported at `crate::database::{models,repositories}`. `database/manager.rs`, `setup.rs`, `commands.rs` **stay in the host**: `DatabaseManager::new_from_app_handle`/`is_first_launch`/`import_legacy_database` resolve `app_data_dir` from `AppHandle` to bootstrap the DB *before* the Engine exists — moving them now would be circular with the not-yet-moved `Engine`. Deferred to Stage D, where the daemon resolves its own path natively.
B2. The host keeps its command shims but now calls `ari-engine` fns in-process (`Engine` constructed host-side, `TauriEventSink` injected). **Still one process.** This isolates "does the code compile as an independent crate" from "does cross-process work."
B3. Port the engine test suites into `ari-engine` (esp. `local_recall_tests`, system-audio tests). Green.

Exit B: `ari-engine` builds and tests standalone (`cargo test -p ari-engine`); the Tauri app still runs, now depending on `ari-engine` as a library.

### Stage C — Method router + streaming inside the engine

C1. Add `dispatch(engine: &Engine, req: Request) -> ResponseOrStream` in `ari-engine`: a match on `method` (`<service>.<verb>`) → the migrated fn, mapping `Err(String)` → `{code:"engine_error", message}` per the error rule. This is the single table the service map enumerates.
C2. Streaming: `recall.answerLocallyStream` returns a stream driver that emits `stream{delta…}` then one terminal `done`/`error` tied to the request `id`. Model the other request-scoped progress the same way only if needed (most progress is free `event`, not `stream`).
C3. Resolve the open questions before finalizing the router table:
   - `meetings.saveTranscript` vs `transcription.saveTranscript` collision — confirm both are live & distinct or drop one.
   - `model-config-updated` — engine event or same-process React event? (If React-only, it never crosses the protocol.)
   - `SystemAudioDetectorState` — remove if app-init wiring confirms it's orphaned.
   - Concurrency: decide serial vs concurrent request processing (affects whether the host needs a pending-request map or a simple queue). **Recommend: start serial**, `id` correlation for safety only; revisit if a long command starves the UI.

Exit C: `dispatch()` covers all ~211 live methods; unit test that every registered command has a router arm (compile-time exhaustiveness where possible, test otherwise).

### Stage D — Build the daemon + flip the host to cross-process

D1. `ari-engine` **binary**: read NDJSON lines from stdin → `dispatch` → write `response`/`event`/`stream` to stdout; stderr is logs only. `StdoutEventSink` replaces `TauriEventSink` inside the daemon.
D2. Host-side `EngineClient`: spawn the `ari-engine` child, write requests, read responses/events/streams, correlate by `id`, relay every `event`/`stream` to the host's own `app.emit(...)` (frontend unchanged). Bundle `ari-engine` as an `externalBin` sidecar (same mechanism as llama-helper).
D3. Rewrite each `#[tauri::command]` shim from "call `ari-engine` fn in-process" to "build `Request`, send via `EngineClient`, await correlated `response`/drive `stream`, return what it returns today." The `[client-side]` commands (file pickers, TCC prompts) keep their host-side OS work and only send the *result* to the engine.
D4. Sidecar-of-a-sidecar check: the engine now spawns llama-helper/apple-helper/diarize-helper/ffmpeg as *its* children (via `SidecarHost`), located under `Paths.binaries`. Verify discovery works from the daemon's working dir, not Tauri's resource dir.

Exit D: the Tauri app runs with `ari-engine` as a separate process; the frontend is none the wiser.

### Stage E — Regression gate (the Phase 1.5 exit)

Per `engine-extraction.md` §sequencing step 2. Run twice — once against the pre-carve monolith (tag it first), once against host-fronting-`ari-engine` — and diff:

1. Frontend test suite (`node --test tests/lib/*.test.mjs`, `tsc --noEmit`) — unchanged, must pass.
2. `cargo test` across workspace, incl. `local_recall_tests`.
3. **Manual signed-build pass** (`pnpm run app:local`) through the full chain: record (mic + system) → live transcript events → stop → diarize → summarize → ask-meetings (streaming answer + citations) → calendar-linked meeting → import an audio file → a model download (progress events). These exercise request/response, free events, streaming, sidecar spawning, and the `[client-side]` split all at once.
4. Confirm app-data location unchanged (same SQLite DB, same downloaded models — no re-download, no re-grant beyond the one-time new-code-identity TCC re-grant).

Exit E → Phase 1.5 done. Phase 2 (SwiftUI shell as the second client) begins; no further engine-side work is implied by it.

## Sequencing & risk

- **Stage A is the long pole** (207 `State`+`AppHandle`-carrying commands to migrate) but also the safest — it's in-process, green after every service, and reviewable in ~16 service-sized commits.
- **Stage D is the riskiest** (first time behavior crosses a process boundary; streaming + event relay + sidecar-of-sidecar). Keep the Stage B in-process path available as an A/B fallback until Stage E passes.
- **Do not delete the Tauri host** at the end of Phase 1.5 — it's retired only after Phase 2's SwiftUI shell reaches parity (plan principle 1).
- Each stage is independently shippable; if we pause, we pause on a green in-process build, never mid-flip.

## What this plan intentionally defers

- Per-service error taxonomy (keep the single `engine_error` code — `engine-extraction.md` error rule).
- stdio vs local-socket transport choice (assume stdio; the envelope survives a swap).
- Any Swift work (Phase 2).
- The `SystemAudioDetectorState` removal is opportunistic (Stage C3), not a blocker.
