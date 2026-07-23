# Swift-Native Migration Plan

**Status: 2026-07-22.** Full rewrite of this document — the previous version had accreted phase-by-phase narration since 2026-07-16 and had drifted from the code in places (most notably: it undercounted landed capture/notifications work, and overstated "Ask my meetings" as done when only its library layer exists). Every status claim below was re-verified against the current tree on 2026-07-22, not carried over from a prior version of this doc or from memory. Detailed subsystem plans remain in `docs/plans/*.md` and are linked inline; this document is now the status/checklist source, not the full narrative.

A staged migration of Ari from its Rust/Tauri + Next.js stack to a **100% Swift, Apple-only** codebase, laying the foundation for an Apple multi-device product family. The macOS app migrates and finishes first; a mobile ("lite") app is a separate, later project (Phase 6).

---

## ✅ Checklist: what's still missing

**Legend: ✅ Done (Swift-native, live, no Rust dependency) · 🟡 Partial (built but not fully wired, or gated on one remaining step) · ⬜ Not started.**

### Blocking full Rust/Tauri cutover

| | Item | State |
|---|---|---|
| 🟡 | **Wire Recall ("Ask my meetings") into the app UI** | Engine is fully built and tested in `AriKit/Sources/AriKit/Recall/` (safety shell, hybrid FTS5⊕vector search, orchestrator, streaming). **Zero UI consumer** — no Ask screen, no view model in `AriViewModels`, no sidebar entry. This is the single largest gap between "AriKit can do it" and "the app can do it." |
| ⬜ | **Onboarding flow** | No first-run setup, permission-request sequence, or model-download flow exists anywhere in `Ari/` or `AriKit/`. Zero code hits for "onboarding." |
| ⬜ | **Block/rich-text editor** | Meeting notes use a plain `MarginaliaTextEditor` (themed `TextEditor` wrapper, no formatting/blocks). No BlockNote equivalent — drag handles, slash menus, `@ref` badge decorations all absent. Scheduled last in Phase 4 by design; still genuinely not started. |
| 🟡 | **Diarization close-out (D10)** | Core port (D1–D9b) is landed and live. Matcher-threshold calibration and the `docs/plans/arikit-diarization.md` §8 human-verification checklist (one hand-confirmed 3+ speaker recording, TCC-free confirm, sign-off) are **all still unchecked**. Not blocking normal use; blocking a confident "diarization is done" call. |
| ⬜ | **Notch panel absorption** | The Settings toggle for it exists but is hardcoded disabled with the message "the meeting notch runs in the frozen Rust app; the Swift shell doesn't drive it yet." Nothing in `Ari/` or `AriKit/` ports the `ari-notch` sidecar. |
| ⬜ | **Settings full parity audit** | Broad coverage exists (Appearance, Notifications, Recordings, Calendar, Transcription/Summary provider+model, meeting-search/embedder). No diarization threshold/tuning UI. Notch setting is present but inert. Needs a dedicated side-by-side pass against the Rust settings surface before calling it done. |

### Not blocking cutover, but open

| | Item | State |
|---|---|---|
| ⬜ | **MCP server (F8)** | Zero code. Planned for Phase 4 (or earlier, Swift-native) — build once against `AriKit.Store`/`Recall`. |
| 🟡 | **MLX numeric 3-axis quality gate** | Mechanism-GO (real inference, no `<think>` leak, true streaming) but not numerically re-verified — the Node `compare.mjs` scorer that produced the Phase-0 quality numbers hasn't been ported to Swift or re-run against `MLXClient` output. |
| ⬜ | **iCloud/CloudKit sync (Phase 5.5)** | Deliberately deferred until the Mac app is fully done locally and the Apple Developer account is bought. Store is built sync-aware-but-off already (see Decisions). |
| ⬜ | **Mobile app / Ari Lite (Phase 6)** | Deliberately deferred until Phase 5.5 sync is proven. Not started, not scoped to start soon. |

### Everything else is done

Audio capture (mic + system tap), STT, summarization/LLM providers (cloud, MLX, Claude CLI, FoundationModels), persistence (GRDB) with a one-time legacy-data importer, calendar (EventKit, full sync + native UI), meeting list/detail UI, meeting series ledgers, menu bar, notifications, the calendar-triggered record prompt (F5), and the Marginalia design system are all Swift-native and live with no Rust dependency. Detail and evidence in the sections below.

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
| Recall / "Ask my meetings" (F7) | 🟡 Library done, UI not wired | `AriKit/Sources/AriKit/Recall/` — safety shell, FTS5⊕vector hybrid search, embedder, indexer, orchestrator (single-shot + streaming), 1:1-ported Rust safety-shell invariant tests. **No Ask screen, no view model, no sidebar entry anywhere in `Ari/`.** A user of the Swift app today cannot ask questions of their meetings; that still only works in the Rust app's `/chat` route. |
| Onboarding | ⬜ Not started | No code anywhere in `Ari/` or `AriKit/`. |
| Block/rich-text editor | ⬜ Not started | Plain `TextEditor`-based `MarginaliaTextEditor` only; no block editing. |
| Notch panel | ⬜ Not started | Explicitly disabled in Settings pending a port. |
| MCP server (F8) | ⬜ Not started | Zero code. |
| Settings | 🟡 Broad but unaudited | See checklist. |
| Design system | ✅ Done | Marginalia tokens (`AriKit/Sources/AriKit/DesignSystem/`) + `MarginaliaTokenParityTests` keeping Swift↔`brand/tokens.json` in sync; button system (4 roles × 2 sizes); macOS 26 Liquid Glass on chrome. |

**Test suite:** last documented aggregate figure is **777 tests / 119 suites** (2026-07-21, at diarization D1–D9b landing). Series management, calendar UI, and notifications landed after that count was taken (2026-07-22), so the true current figure is higher — no newer aggregate has been recorded. Re-run `swift test --parallel` in `AriKit/` for a fresh count before quoting one.

**Most recent activity (`git log --oneline`, repo root, as of 2026-07-22 20:52 local):** series management (F9), people-record updates, calendar-context-aware template auto-selection, a voiceprint fix, MLX summary quality/speed fixes, menu-bar branding, F3 owner-context restore, transcript markers, a recurring-event fix, a `MenuBarExtra` crash fix, signing/entitlements work, and the notifications/F5 port. All Swift-side; nothing in this window touched `frontend/src-tauri`.

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
├── Recall        hybrid retrieval (FTS5 ⊕ vector RRF), safety shell — built, not yet wired to UI
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
├── SwiftUI UI (native, Recall not yet wired)         ├── Recall/persons/series (shared)
└── —                                                 └── SwiftUI UI, minus speaker labels
```

**Platform deltas for mobile (resolved at Phase 6 kickoff, flagged now):** no system-audio capture on iOS (Core Audio process taps are macOS-only, confirmed against iOS 27/WWDC 2026 — no change); on-device summary viable via Gemma 4 E2B/E4B through MLX-swift; speaker ID excluded (no proven on-device mobile diarization model — revisit if one appears).

---

## Remaining phases

Phases 0 (de-risk spikes), 1 (collapsed into 3), 1.5 (engine carve), 2 (native shell), and the bulk of 3 (store/capture/STT/summary/diarization) are **complete** — their detail now lives only in the per-subsystem plans below, not repeated here. What's left:

### Phase 3 tail — diarization close-out
D10 calibration sweep + `docs/plans/arikit-diarization.md` §8 human-verification checklist. See top checklist.

### Phase 4 — remaining UI nativization
- **Wire Recall into the app** (the actual next priority — the engine is done, the UI isn't).
- **Onboarding flow** — first-run setup, permission sequencing, model-download UX.
- **Block editor** — native rebuild on `TextEditor`/`AttributedString`, or accept a scoped WebView for this one panel (decision still open, was deferred to "decide on evidence").
- **Notch panel absorption.**
- **MCP server (F8)** — build once against `AriKit.Store`/`Recall`.
- **Settings parity audit** — diarization tuning UI, notch setting reactivation, full side-by-side vs. the Rust settings surface.

### Phase 5 — convergence & cleanup
Once the Phase 4 items above land: delete the Rust tree (`frontend/src-tauri`, `llama-helper`, `diarize-helper` — already functionally dead), delete `frontend/` (Next.js/React), delete the root Arivo `DESIGN.md`/`DESIGN.json` (superseded by `brand/`), update `.claude/` docs and the PRD. Not started — correctly gated on Phase 4.

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
| Hybrid recall + safety shell | Swift library | 🟡 Built, not wired to UI |
| `sherpa-onnx` (`diarize-helper`) | FluidAudio (CoreML pyannote) | 🟡 Core done, D10 open |
| EventKit calendar sync | Native (was already objc2-native) | ✅ Done |
| Notifications + F5 record prompt | UserNotifications | ✅ Done |
| `apple-helper` | Absorbed in-process | ✅ Done |
| `ari-notch` UI | — | ⬜ Not started |
| Onboarding | — | ⬜ Not started |
| Block editor | — | ⬜ Not started |
| MCP server (F8) | — | ⬜ Not started |
| Next.js/React/BlockNote UI (11 routes) | SwiftUI | ✅ Done except Ask + block editor |
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
- `docs/plans/arikit-recall.md` — Recall engine (library; UI wiring not yet planned as its own doc — do that next)
- `docs/plans/arikit-stt.md` — STT
- `docs/plans/arikit-diarization.md` — Diarization (§8 has the open D10 checklist)
- `docs/plans/arikit-engine-providers.md`, `docs/plans/arikit-engine-extras.md` — Providers/summary, MLX/persons/series
- `docs/plans/arikit-native-shell.md`, `docs/plans/arikit-native-read-ui.md` — Shell + read UI
- `docs/plans/arikit-calendar.md`, `docs/plans/arikit-calendar-ui.md` — Calendar
- `docs/plans/arikit-component-library.md`, `docs/plans/liquid-glass-adoption.md`, `docs/plans/marginalia-review-fixes.md` — Design system
- `docs/plans/arikit-models.md` — Shared domain models
- `docs/plans/ari-engine-carve.md`, `docs/plans/engine-extraction.md` — Historical: the abandoned daemon-carve effort, kept for reference only

## Revision history

- **v9 (2026-07-22)** — Full rewrite. Restructured around a top-of-doc done/partial/not-started checklist; every claim re-verified against the code (not memory or the prior doc revision), since work happens across multiple machines and this doc is the shared source of truth. Compressed ~360 lines of phase-by-phase historical narration (now in git history) down to current-state + remaining work. Corrected two stale claims from v8: the "S7 tail (notifications/F5) still open" note was outdated (both landed 2026-07-22), and "Ask my meetings is answerable end-to-end in Swift" overstated a library-only implementation with no UI.
- **v1–v8 (2026-07-16 → 2026-07-21)** — See `git log -p -- plans/swift-migration-plan.md` for the full history: initial strangler proposal, Phase-0 spike results (S1 MLX-Qwen GO, S2 SpeechTranscriber GO, S3 FluidAudio conditional-GO), the engine-carve/daemon design and its later abandonment, the GRDB-vs-SQLiteData store decision, and the Phase 2/3 landing narrative through diarization D1–D9b.
