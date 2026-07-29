# Swift-Native Migration Plan

**Status: 2026-07-29.** Every status claim below was re-verified against the current tree on 2026-07-29 via four code audits (onboarding, settings parity, rich editor, diarization + legacy-remnant sweep) — the 2026-07-24..29 commit window (~40 commits: onboarding flow, rich summary editor, person-db/fact reconciliation, Ask scope fixes) had left the previous revision stale on three headline items. Detailed subsystem plans remain in `docs/plans/*.md` and are linked inline; this document is the status/checklist source, not the full narrative.

A staged migration of Ari from its Rust/Tauri + Next.js stack to a **100% Swift, Apple-only** codebase, laying the foundation for an Apple multi-device product family. The macOS app migrates and finishes first; a mobile ("lite") app is a separate, later project (Phase 6).

---

## ✅ Checklist: what's still missing

**Legend: ✅ Done (Swift-native, live, no Rust dependency) · 🟡 Partial (built but not fully wired, or gated on one remaining step) · ⬜ Not started.**

### Blocking full Rust/Tauri cutover

| | Item | State |
|---|---|---|
| ✅ | **Wire Recall ("Ask my meetings") into the app UI** | Done 2026-07-22 (`848e8d9`/merge `2864381`, `docs/plans/ari-ask-ui.md`): native Ask chat UI on the already-built RecallEngine — the dedicated `.ask` page plus an app-wide chat-bubble FAB + overlay, context-aware scope (meeting > series > global, auto-derived from navigation, user-overridable), streamed answers, inline `[S1]` citation chips with source popovers, per-scope persisted conversation history. `AskViewModel`/`AskScopeResolver` in `AriViewModels`; RecallEngine wired in `AppEnvironment` with the zero-config on-device MLX default. |
| ✅ | **Onboarding flow** | Done (commit `974a520`, verified 2026-07-29): `Ari/UI/Onboarding/OnboardingView.swift` + `OnboardingViewModel` + `OnboardingInstallableComponent` conformances (FluidAudio, MLX model, embedder), wired at launch via `AppEnvironment`/`RootSplitView`, completion persisted via `SettingsRepository` (`.onboardingCompleted`), 34 tests across 8 suites. Deliberately scoped to model-install/education (`docs/plans/onboarding-install-flow.md`, whose "not yet built" header is stale) — mic/screen/calendar permission requests stay point-of-use by documented decision; SpeechAnalyzer asset install lives in Settings. |
| ✅ | **Rich summary editor** | Done (2026-07-24..29, verified 2026-07-29): transform library + markdown↔`AttributedString` round-trip in `AriKit/DesignSystem/` (`SummaryRichText`, `SummaryEditDocument`, formatting definition), `SummaryRichEditor` + Liquid-Glass window-toolbar controls in `MeetingDetailView`, native ⌘B/⌘I. 142 green tests incl. round-trip fixed-point and list-merge. `docs/plans/rich-summary-editor.md` Step-6 checklist text is stale — the closing commits (`4702074`, `bf7cff4`, `68a925d`, toolbar series) landed after its last edit. The full BlockNote-style *block* editor (drag handles, slash menus, interactive `@ref` badges) remains explicitly deferred (`arikit-native-shell.md` §"deferred") and is **not** cutover-blocking. |
| 🟡 | **Diarization close-out (D10)** | Core port (D1–D9b) is landed and in daily use with good results. But D10 is real un-started work, not paperwork (verified 2026-07-29): `MatchConfig` thresholds (0.70/0.55/0.08) are still the uncalibrated CAM++ carryover values ("RETUNE ON REAL RECORDINGS"), the sweep tooling (`arikit-diarize-rttm`) was never built, and the §8 human checklist in `docs/plans/arikit-diarization.md` is fully unchecked. Daily use is soft evidence the defaults are acceptable; not blocking cutover. |
| ✅ | **Notch panel absorption** | Done 2026-07-22 (`docs/plans/notch-panel-absorption.md`): panel + chrome + HUD ported in-process (`Ari/UI/Notch/`, pure layer in `AriViewModels/Notch/`), bound directly to `RecordingSession` (no NDJSON), re-themed to Marginalia. **The scheduler brain was pulled forward** (Amendment A — was slated to port with the engine) as `NotchUpcomingPlanner`/`NotchUpcomingScheduler`, so the upcoming-meeting island prompt is live too. Toggle: `showNotchOverlay` (UserDefaults, default off). Human visual pass on a notched display still pending. |
| ✅ | **Settings full parity audit** | Audit performed 2026-07-29 (side-by-side vs `frontend/src/app/settings/`). Verdict: parity at-or-better everywhere that matters. Intentional narrowings, not gaps: Apple Speech is the sole transcription engine (no Whisper/Parakeet/cloud pickers), summary providers reduced to on-device Qwen-MLX + Claude CLI, embedder fixed to Apple on-device, system-audio device picker replaced by an honest read-only row (single global tap). Swift-only additions: consent-before-record toggle, meeting reminders + lead time, custom vocabulary. Diarization thresholds are code constants in both apps (no UI in either — no gap). The legacy inert `generalShowNotch` DB row was already deleted at notch absorption. **Follow-up (small, tracked below): delete the dead settings plumbing the audit surfaced.** |

### Not blocking cutover, but open

| | Item | State |
|---|---|---|
| ⬜ | **MCP server (F8)** | Zero code. The last unbuilt product feature. Planned for Phase 4 (or earlier, Swift-native) — build once against `AriKit.Store`/`Recall`. |
| ⬜ | **Dead settings plumbing cleanup** | Surfaced by the 2026-07-29 parity audit — the only dead code found in the Swift tree: `SettingKey.transcriptionProvider`/`.transcriptionModel` (never read/written), `SettingsViewModel.recordingStartNotification` (full VM read/write path, no view binds it), `summaryCustomOpenAIConfig` (reader with no writer and no UI — unreachable), `summaryOllamaEndpoint` (setter no view calls). Delete or wire; ~an hour. |
| ⬜ | **Recall sources: speaker labels** | `AriKit/Sources/AriKit/Recall/People/PeopleContext.swift:23` still leaves `RecallSource.speakers` empty ("TODO(Phase 3.5)") even though diarization labels now exist (`SpeakerRepository.forMeeting`). Now-actionable feature gap: Ask answers don't surface identified speakers. |
| ⬜ | **Stale subsidiary plan docs** | Headers/checklists that understate landed reality: `docs/plans/onboarding-install-flow.md` ("not yet built"), `docs/plans/rich-summary-editor.md` (Step 6 "NOT YET RUN", "no formatting toolbar in v1"), `docs/plans/native-formatting-menu.md` (superseded by `native-text-formatting.md` + findings). Update or mark superseded. |
| 🟡 | **MLX numeric 3-axis quality gate** | Mechanism-GO (real inference, no `<think>` leak, true streaming) but not numerically re-verified — the Node `compare.mjs` scorer that produced the Phase-0 quality numbers hasn't been ported to Swift or re-run against `MLXClient` output. |
| ⬜ | **iCloud/CloudKit sync (Phase 5.5)** | Deliberately deferred until the Mac app is fully done locally and the Apple Developer account is bought. Store is built sync-aware-but-off already (see Decisions). |
| ⬜ | **Mobile app / Ari Lite (Phase 6)** | Deliberately deferred until Phase 5.5 sync is proven. Not started, not scoped to start soon. |

### Everything else is done

Audio capture (mic + system tap), STT, summarization/LLM providers (cloud, MLX, Claude CLI, FoundationModels), persistence (GRDB) with a one-time legacy-data importer, calendar (EventKit, full sync + native UI), meeting list/detail UI (incl. the rich summary editor), meeting series ledgers, onboarding, settings, menu bar, notifications, the calendar-triggered record prompt (F5), and the Marginalia design system are all Swift-native and live with no Rust dependency. A 2026-07-29 legacy-remnant sweep found **no dead transitional code** in `Ari/`/`AriKit/`: the legacy-DB importer is deliberate and self-contained, and `apple-helper`/`ari-notch` are referenced only by the frozen Rust app (both absorbed in-process on the Swift side). Detail and evidence in the sections below.

**Cutover consequence:** with onboarding, the editor, and the settings audit closed, the Phase-4 gate on Phase 5 is satisfied in substance — nothing left open (MCP, D10 calibration, cleanup items) depends on the Rust/React trees existing. Phase 5 deletion is unblocked. One mechanical pre-step: `tools/prompt-harness` loads `frontend/src-tauri/templates/*.json` at runtime (and can spawn `llama-helper` as a baseline backend) — vendor the template JSONs into `tools/` before deleting the Rust tree so the MLX numeric gate stays runnable.

---

## Where things actually stand (verified 2026-07-22)

**The Rust/Tauri app has zero runtime dependency from the Swift app.** No IPC bridge, no sidecar process, no shared runtime exists between them. The only remaining tie is a one-shot, read-only import of the old app's SQLite DB on first Swift-app run (`AriKit/Sources/AriKit/Store/Import/LegacyDatabaseReader.swift`), explicitly designed to coexist safely with a still-running Tauri app during the transition. The earlier plan for a headless `ari-engine` daemon the Swift shell would drive over NDJSON (Stages C/D of the Phase-1.5 carve) was abandoned in favor of native-first — it never shipped and isn't needed.

| Feature | State | Evidence |
|---|---|---|
| Audio capture (mic + system tap) | ✅ Done | `AriKit/Sources/AriCapture/{MicrophoneCapture,SystemAudioTap,CaptureCoordinator}.swift`; wired live via `Ari/Capture/LiveCaptureService.swift`. |
| STT | ✅ Done | `Engine/STT/` on SpeechAnalyzer/SpeechTranscriber. Gate passed: mean core WER 0.2345 vs Parakeet baseline 0.2814, 100% word-timestamp coverage. WhisperKit deferred (protocol kept backend-ready). |
| Diarization | 🟡 Core done, close-out open | FluidAudio (CoreML pyannote, offline), calendar-attendee-count-hint driven. D1–D9b landed 2026-07-21 with full UI (`IdentifySpeakersSheet.swift`). D10 calibration + human checklist unchecked — see checklist above. |
| Summarization / LLM providers | ✅ Done | `Engine/Providers/` — OpenAI-compatible, Anthropic, Claude-CLI (`Process` spawn), FoundationModels, `AriKitEngineMLX` (Qwen3.5-4B-MLX default). Active quality fixes as recently as 2026-07-22 (`0d0642b`), confirming this path is live and maintained, not just landed once. |
| Persistence | ✅ Done | `AriKit/Sources/AriKit/Store/` — full GRDB schema + repositories. Legacy importer runs once on first launch, then the Swift app owns its own DB file. |
| Calendar | ✅ Done | `EventKitCalendarSource` + `CalendarSyncEngine`, 15-min sync, native Marginalia week-grid UI, event-detail sheet, manual link/unlink, start-meeting-from-event. Landed 2026-07-22. |
| Calendar-triggered record prompt (F5) | ✅ Done | `AriKit/Sources/AriViewModels/Notifications/MeetingReminderPlanner.swift` — pure reconciliation core, explicitly the Swift port of the Rust F5 logic. Wired via `MeetingNotifications.swift`/`ReminderRefreshScheduler`. Landed 2026-07-22 — **later than this doc's previous "still open" claim about the S7 tail.** |
| Notifications | ✅ Done | `Ari/App/Notifications/SystemNotificationScheduler.swift` — real `UNUserNotificationCenter` implementation with actions, wired into `AppEnvironment.swift`. Landed 2026-07-22. |
| Meeting list/detail UI | ✅ Done | Native `NavigationSplitView`, `AVPlayer` listen-back, referenced-moments bar, source-record panel, `MarginaliaMarkdownView` with `[MM:SS]` citation chips. |
| Meeting series (F9) | ✅ Done | Landed 2026-07-22 (`acbc300`) — native ledger, cross-meeting `@mref` citation chips, searchable/sorted list. |
| Menu bar | ✅ Done | `Ari/UI/MenuBar/MenuBarContentView.swift`, branded 2026-07-22. |
| Recall / "Ask my meetings" (F7) | ✅ Done | Engine: `AriKit/Sources/AriKit/Recall/` (safety shell, FTS5⊕vector hybrid, orchestrator, 1:1-ported invariant tests). UI landed 2026-07-22 (`848e8d9`): `.ask` page + global FAB overlay, scope resolution (meeting/series/global), streaming, citation chips, per-scope history. |
| Onboarding | ✅ Done | `Ari/UI/Onboarding/` + `AriViewModels/OnboardingViewModel` + installable-component protocol; launch-wired, tested. Scope = model install/education by design (permissions stay point-of-use). |
| Rich summary editor | ✅ Done | `SummaryRichEditor` + `AriKit/DesignSystem` transform library; markdown round-trip + list-merge tested (142 tests). Block-editing ambition (drag/slash/interactive `@ref`) explicitly deferred, not cutover-blocking. |
| Notch panel | ✅ Done | Absorbed in-process 2026-07-22 (`dcdec9a`..`91487e0`, `docs/plans/notch-panel-absorption.md`): `Ari/UI/Notch/` panel host + chrome + HUD, pure layer in `AriViewModels/Notch/`, scheduler brain pulled forward (`NotchUpcomingPlanner`/`NotchUpcomingScheduler`), Marginalia re-theme, `showNotchOverlay` toggle (default off). Live-pass fixes: shared `PeakLevelMeter` level gain, notch-width overhang, flush-top/no-bounce/pixel-snap animation hardening. Human visual re-check of the top seam still pending. |
| MCP server (F8) | ⬜ Not started | Zero code. |
| Settings | ✅ Audited 2026-07-29 | Parity at-or-better; intentional provider narrowings; dead plumbing cleanup tracked in checklist. |
| Design system | ✅ Done | Marginalia tokens (`AriKit/Sources/AriKit/DesignSystem/`) + `MarginaliaTokenParityTests` keeping Swift↔`brand/tokens.json` in sync; button system (4 roles × 2 sizes); macOS 26 Liquid Glass on chrome. |

**Test suite:** last documented aggregate figure is **777 tests / 119 suites** (2026-07-21). Series/calendar/notifications (07-22), onboarding (34 tests), the rich editor (142 in its 6 suites), and vocabulary all landed after that count — the true figure is meaningfully higher. Re-run `swift test --parallel` in `AriKit/` for a fresh count before quoting one.

**Most recent activity (2026-07-23 → 07-29, ~40 commits, all Swift-side):** first-run onboarding flow, the rich summary editor (transform library → editor view → window-toolbar Liquid-Glass controls → native ⌘B/⌘I → list-merge fix), custom vocabulary Settings UI + STT-safety gap close, person-db work (owner dedup on calendar import, fact reconciliation pipeline + one-time consolidation pass, person merge, ledger status badges), Ask FAB scope fix, summary-context bleed fix, template trims. Nothing touched `frontend/src-tauri`.

---

## Verdict & guiding principles

**Migrate as a strangler, not a big-bang rewrite — this call was made and executed; the plan below is now mop-up, not a decision to revisit.** Rationale (unchanged since inception): Apple-only intent + eventual iCloud/mobile, which a Rust/C++ engine can't share with a native iOS app anyway. Most of the Rust engine dissolved into native frameworks (MLX, SpeechAnalyzer, Core Audio process taps, AVFoundation, GRDB) rather than needing re-wrapping; diarization was the one real model-port effort, and it's landed.

Principles still governing remaining work:

1. **Strangler, never big-bang.** The Rust/Tauri app stays shippable and frozen (reactive maintenance only) until each piece it covers has a Swift replacement that's actually wired into the UI — not just built.
2. **Quality gates before a component is trusted as "the" implementation.** Applies to what's left: the D10 diarization close, and the MLX numeric gate.
3. **Exactly one process owns the database at a time.** Settled — GRDB owns it; the only cross-boundary read is the one-shot legacy import.
4. **Mac first, then sync, then mobile.** Phase 5.5 (iCloud) and Phase 6 (mobile) don't start until the Mac app is fully done locally.
5. **Sync text, keep audio local** (when 5.5 lands). Already the shape of the schema.
6. **Preserve the invariants as ported tests.** Recall safety shell (loopback-only, bounded context, never-invents-citations), consent-before-record, No-Fake-State — all carried over as Swift Testing suites, not just intentions. This is why the Recall *engine* being safety-correct isn't the same as it being *shipped* — the checklist above tracks the gap.
7. **Latest-OS-only (macOS/iOS 26) is an accepted constraint**, not revisited.
8. **WIP limits.** At most one migration phase active, one feature in flight, landing on the Swift side. Rust gets bugfixes only.

---

## Target architecture (end state)

```
AriKit  (shared Swift package)
├── Models        meetings, transcripts, summaries, persons, series, profile facts
├── Store         GRDB (local source of truth)  +  CloudKit sync (Phase 5.5, off today)
├── Recall        hybrid retrieval (FTS5 ⊕ vector RRF), safety shell — wired to the Ask UI
├── Context       SummaryContext assembly (owner + attendees + call type)
└── Engine        capture-agnostic STT / summary / persons / series / recall
                  (shared by both targets; diarization is macOS-only)

Ari (macOS app — DONE except the checklist above)   Ari Lite (iOS/iPadOS — Phase 6, not started)
├── Capture   Core Audio process tap + AVAudioEngine ├── Capture   AVAudioEngine mic only
├── Encode    AVFoundation (AAC)                     │             (no system-audio tap on iOS)
├── STT       SpeechAnalyzer                         ├── STT       SpeechAnalyzer (shared)
├── Diarize   FluidAudio (CoreML, offline)            ├── Diarize   ✗ none (no proven mobile model)
├── Summary   MLX / cloud / Claude CLI / FM floor     ├── Summary   MLX Gemma-E2B/E4B / cloud
├── Calendar  EventKit                                ├── Calendar  EventKit
├── SwiftUI UI (native, incl. Ask + notch island)     ├── Recall/persons/series (shared)
└── —                                                 └── SwiftUI UI, minus speaker labels
```

**Platform deltas for mobile (resolved at Phase 6 kickoff, flagged now):** no system-audio capture on iOS (Core Audio process taps are macOS-only, confirmed against iOS 27/WWDC 2026 — no change); on-device summary viable via Gemma 4 E2B/E4B through MLX-swift; speaker ID excluded (no proven on-device mobile diarization model — revisit if one appears).

---

## Remaining phases

Phases 0 (de-risk spikes), 1 (collapsed into 3), 1.5 (engine carve), 2 (native shell), and the bulk of 3 (store/capture/STT/summary/diarization) are **complete** — their detail now lives only in the per-subsystem plans below, not repeated here. What's left:

### Phase 3 tail — diarization close-out (optional rigor)
D10 calibration sweep + `docs/plans/arikit-diarization.md` §8 human-verification checklist. Genuinely un-started (thresholds are uncalibrated carryovers), but daily use is going well — decide whether to invest or accept the defaults. Not cutover-blocking. See top checklist.

### Phase 4 — remaining UI nativization
- ~~**Wire Recall into the app**~~ ✅ Done 2026-07-22 — the Ask page + FAB overlay (`docs/plans/ari-ask-ui.md`).
- ~~**Onboarding flow**~~ ✅ Done ~2026-07-24 (`974a520`, `docs/plans/onboarding-install-flow.md`) — model-install/education scope; permissions stay point-of-use by design.
- ~~**Rich summary editor**~~ ✅ Done 2026-07-24..29 (`docs/plans/rich-summary-editor.md`) — the block-editor question is resolved for cutover purposes: native `AttributedString` editor shipped; full block editing (drag/slash/interactive `@ref`) stays deferred-on-evidence.
- ~~**Notch panel absorption.**~~ ✅ Done 2026-07-22, including the scheduler brain pulled forward (`docs/plans/notch-panel-absorption.md`).
- ~~**Settings parity audit**~~ ✅ Done 2026-07-29 — see top checklist; dead-plumbing cleanup is the only residue.
- **MCP server (F8)** — build once against `AriKit.Store`/`Recall`. The last unbuilt feature; does not depend on the legacy trees.
- **Small residue:** dead settings plumbing cleanup · Recall `RecallSource.speakers` wiring · stale subsidiary plan-doc headers (all in the top checklist).

### Phase 5 — convergence & cleanup — **UNBLOCKED 2026-07-29**
The Phase-4 gate is satisfied in substance (everything still open is Swift-side-only and does not need the legacy trees). Sweep: delete the Rust tree (`frontend/src-tauri`, `llama-helper`, `diarize-helper`), delete `frontend/` (Next.js/React), delete the now-orphaned `apple-helper`/`ari-notch` sidecars (only the frozen Rust app spawns them), delete the root Arivo `DESIGN.md`/`DESIGN.json` (superseded by `brand/`), update `.claude/` docs and the PRD. **Pre-step:** vendor `frontend/src-tauri/templates/*.json` into `tools/prompt-harness/` (it loads them at runtime; the llama-helper baseline backend dies with the deletion — acceptable, MLX-vs-recorded-baseline comparison remains).

### Phase 5.5 — turn on iCloud sync
Deferred by design until the Mac app is fully done locally. Requires the paid Apple Developer account (only external prerequisite). Store is already built sync-aware-but-off (stable UUID PKs, nullable synced columns, soft-delete tombstones, per-record conflict granularity) so this is meant to be a switch-on, not a schema migration, when it starts. Not started.

### Phase 6 — Ari Lite (mobile)
Starts only after Phase 5.5 is proven. Full engine reuse via `AriKit`, minus speaker ID. Not started, not imminent.

---

## Subsystem migration map

| Subsystem | Swift replacement | State |
|---|---|---|
| `cidre`/`cpal` audio | Core Audio process tap + AVAudioEngine | ✅ Done |
| `ffmpeg` sidecar | AVFoundation/AVAudioFile | ✅ Done |
| `silero` VAD | `SpeechDetector`/CoreML | ✅ Done |
| whisper.cpp/Parakeet | SpeechAnalyzer/SpeechTranscriber | ✅ Done (gate passed) |
| `llama-helper` (llama.cpp) | MLX (`mlx-swift-lm`) + FoundationModels floor | ✅ Done (mechanism-GO; numeric gate 🟡) |
| Cloud LLM providers | URLSession | ✅ Done |
| Claude CLI provider | `Process` subprocess | ✅ Done |
| Persons extraction/reconciliation | Swift, LLM-backed | ✅ Done |
| Series detection + ledgers | Swift | ✅ Done (F9, 2026-07-22) |
| `sqlx` + repositories | GRDB | ✅ Done |
| Hybrid recall + safety shell | Swift library + Ask UI | ✅ Done (UI wired 2026-07-22) |
| `sherpa-onnx` (`diarize-helper`) | FluidAudio (CoreML pyannote) | 🟡 Core done, D10 open |
| EventKit calendar sync | Native (was already objc2-native) | ✅ Done |
| Notifications + F5 record prompt | UserNotifications | ✅ Done |
| `apple-helper` | Absorbed in-process | ✅ Done |
| `ari-notch` UI + scheduler | Absorbed in-process (`Ari/UI/Notch/` + `AriViewModels/Notch/`) | ✅ Done (2026-07-22, incl. scheduler pulled forward) |
| Onboarding | Native SwiftUI first-run flow | ✅ Done (~2026-07-24) |
| BlockNote summary editing | Native `AttributedString` rich editor | ✅ Done (2026-07-24..29; full block editing deferred-on-evidence) |
| MCP server (F8) | — | ⬜ Not started |
| Next.js/React/BlockNote UI (11 routes) | SwiftUI | ✅ Done |
| CloudKit sync layer | — | ⬜ Not started (Phase 5.5) |
| Ari Lite iOS app | — | ⬜ Not started (Phase 6) |

---

## Decisions (condensed log)

- **Store: plain GRDB, not SQLiteData, not SwiftData.** SwiftData hides raw SQL/FTS5, which would amputate the Recall differentiator — rejected outright. SQLiteData (built on GRDB) added a heavyweight `@Table` paradigm with no benefit until CloudKit at Phase 5.5 — deferred, not rejected; revisit then. Full reasoning: `docs/plans/arikit-store.md §0.1(3)`.
- **No headless `ari-engine` daemon.** The Phase-0 spikes greenlit Swift-native STT/summary/diarization outright, so the planned Swift-shell-drives-Rust-daemon bridge was never built. Each AriKit layer owns its own data/logic standalone.
- **Distribution: Developer ID + hardened runtime, no App Sandbox.** Sandboxing would break process-tap capture and sidecar model directories. No Apple Developer account needed until Phase 5.5 (CloudKit entitlement only).
- **Diarization driven by calendar attendee count.** FluidAudio's default auto-speaker-count collapses multi-speaker mixed audio to one speaker; feeding it the calendar-derived expected count recovers near-parity with the old sherpa pipeline. This is load-bearing, not optional.
- **On-device summary default: MLX Qwen3.5-4B-4bit.** Matched the old GGUF baseline on every quality axis in the 9-meeting bake-off, faster, smaller. Gemma-4-E4B kept as a mobile-tier candidate, not the desktop default.
- **Mobile scope = full feature set minus speaker ID**, not read-only. Starts only after Phase 5.5.
- **Feature freeze on Rust was set 2026-07-16** and holds: Rust gets bugfixes only, all net-new work is Swift-first.

Fuller historical reasoning for each of these (spike numbers, bake-off tables, the SQLiteData API investigation, etc.) lived in prior revisions of this document; if you need it, `git log -p -- plans/swift-migration-plan.md` has the full trail. It's intentionally not reproduced here to keep this document a status source, not an archive.

## Per-subsystem detail plans

- `docs/plans/arikit-store.md` — Store/GRDB
- `docs/plans/arikit-recall.md` — Recall engine (library); `docs/plans/ari-ask-ui.md` — the Ask UI wiring (shipped 2026-07-22)
- `docs/plans/arikit-stt.md` — STT
- `docs/plans/arikit-diarization.md` — Diarization (§8 has the open D10 checklist)
- `docs/plans/arikit-engine-providers.md`, `docs/plans/arikit-engine-extras.md` — Providers/summary, MLX/persons/series
- `docs/plans/arikit-native-shell.md`, `docs/plans/arikit-native-read-ui.md` — Shell + read UI
- `docs/plans/arikit-calendar.md`, `docs/plans/arikit-calendar-ui.md` — Calendar
- `docs/plans/arikit-component-library.md`, `docs/plans/liquid-glass-adoption.md`, `docs/plans/marginalia-review-fixes.md` — Design system
- `docs/plans/arikit-models.md` — Shared domain models
- `docs/plans/ari-engine-carve.md`, `docs/plans/engine-extraction.md` — Historical: the abandoned daemon-carve effort, kept for reference only

## Revision history

- **v10 (2026-07-29)** — Re-verified via four parallel code audits after the 2026-07-23..29 commit window. Onboarding ⬜→✅ (model-install scope, launch-wired, 34 tests), block/rich editor ⬜→✅ (rich summary editor shipped; block editing deferred-on-evidence), settings parity audit ⬜→✅ (performed; at-or-better, four dead-plumbing items to delete), D10 kept 🟡 with sharper wording (real un-started calibration work, not paperwork). Added new open items: dead settings plumbing, `RecallSource.speakers` wiring, stale subsidiary plan-doc headers. Declared **Phase 5 unblocked** with the prompt-harness template-vendoring pre-step. Legacy-remnant sweep found zero dead transitional code in the Swift trees.
- **v9 (2026-07-22)** — Full rewrite. Restructured around a top-of-doc done/partial/not-started checklist; every claim re-verified against the code (not memory or the prior doc revision), since work happens across multiple machines and this doc is the shared source of truth. Compressed ~360 lines of phase-by-phase historical narration (now in git history) down to current-state + remaining work. Corrected two stale claims from v8: the "S7 tail (notifications/F5) still open" note was outdated (both landed 2026-07-22), and "Ask my meetings is answerable end-to-end in Swift" overstated a library-only implementation with no UI.
- **v1–v8 (2026-07-16 → 2026-07-21)** — See `git log -p -- plans/swift-migration-plan.md` for the full history: initial strangler proposal, Phase-0 spike results (S1 MLX-Qwen GO, S2 SpeechTranscriber GO, S3 FluidAudio conditional-GO), the engine-carve/daemon design and its later abandonment, the GRDB-vs-SQLiteData store decision, and the Phase 2/3 landing narrative through diarization D1–D9b.
