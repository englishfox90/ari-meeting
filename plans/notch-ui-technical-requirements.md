# Technical Requirements — macOS Notch UI ("Ari Notch")

**Status:** Draft for build. Companion to `meeting-intelligence-prd.md`.
**Author:** engineering, 2026-07-14.
**Scope:** macOS Apple Silicon only. Additive-only (see `.claude/rules/additive-only.md`).

---

## 1. Goal

Add a native macOS notch / "Dynamic Island"-style surface to Ari, driven by the existing
Rust core, delivering two use cases:

- **UC1 — Upcoming meeting alert.** As a calendar meeting approaches (e.g. T-5 min), a notch
  panel expands showing the meeting title, start countdown, and a one-tap **Record** button
  that starts a recording already associated with that meeting.
- **UC2 — Recording progress.** While recording, the notch shows live state: elapsed time,
  a live audio-level indicator, latest transcript line (optional), and **Pause/Stop** controls.

Both surfaces render over the physical camera notch on notched MacBooks and fall back to a
floating capsule on non-notched / external displays.

### Non-goals (this iteration)
- No notch UI on Windows/Linux (project is macOS-only by charter).
- No full transcript browsing in the notch (deep-link to the main window instead).
- No new recording/calendar *capabilities* — the notch is a **surface** over existing engine
  state. The one genuinely new backend piece is the **reminder scheduler** (§6, WS-D), which
  completes the already-stubbed F5 feature.

---

## 2. Architecture decision

### Chosen approach: native Swift sidecar using DynamicNotchKit

A small standalone **Swift/SwiftUI binary** (`ari-notch`) renders the notch panel and is run
by the Rust core as a **Tauri sidecar** — the exact pattern already used for `llama-helper`
and `ffmpeg` (`frontend/src-tauri/tauri.conf.json:103` `externalBin`). Rust pushes state to
the sidecar's stdin; the sidecar pushes user actions (Record/Pause/Stop/Open) back on stdout.
Communication is **newline-delimited JSON**, mirroring `summary/summary_engine/sidecar.rs`.

**Notch rendering library:** [`DynamicNotchKit`](https://github.com/MrKai77/DynamicNotchKit)
(SwiftUI, notch + non-notch capsule fallback, permissive license — **verify license text is
MIT-compatible before vendoring**, see §9). We do **not** use `jackson-storm/DynamicNotch` —
it is GPL-3.0 and a standalone app, incompatible with this MIT codebase. Inspiration only.

### Why sidecar over a Tauri transparent window
- A true notch panel is an always-on-top, non-activating **NSPanel** that floats above
  fullscreen apps and hugs the safe-area inset. Tauri webview windows are not NSPanels and
  reaching that behavior needs raw `objc` hacks for a worse result.
- The sidecar pattern is already load-bearing here; adding one more `externalBin` is
  well-trodden and **fully additive** (no upstream files edited beyond registration points).
- DynamicNotchKit gives native spring physics, safe-area geometry, and capsule fallback for
  free — we'd otherwise reimplement all of it in CSS.
- The Swift toolchain is already a hard build prerequisite (full Xcode, `cidre`), so no new
  tooling burden beyond a SwiftPM target.

### Rejected: Tauri second window
Kept as a fallback only if a blocking issue emerges bundling/signing a second binary. Would
require: transparent+borderless+alwaysOnTop window, `objc`-level NSPanel conversion, manual
notch geometry, and CSS-reimplemented animation. Higher risk, lower fidelity. Not pursued.

---

## 3. Component overview

```
┌─────────────────────────── Rust core (app_lib) ───────────────────────────┐
│                                                                            │
│  audio/*  ──emits──▶  recording-started/-stopped/-paused/-resumed,         │
│                       transcript-update, audio-levels                      │
│  calendar/* ─────────▶ CalendarEvent store (SQLite)                        │
│                                                                            │
│              ┌──────────────── notch/ (NEW module) ────────────────┐       │
│              │  NotchBridge: owns the sidecar child process        │       │
│              │   • forwards recording events → sidecar stdin       │       │
│              │   • reminder scheduler (WS-D) → sidecar stdin        │       │
│              │   • reads sidecar stdout → dispatches to existing    │       │
│              │     commands (start/stop/pause recording, focus win) │       │
│              └───────────────────────┬─────────────────────────────┘       │
└──────────────────────────────────────┼─────────────────────────────────────┘
                     stdin (state push) │ ▲ stdout (user actions)
                                        ▼ │
                        ┌──────────── ari-notch (NEW Swift binary) ──────────┐
                        │  DynamicNotchKit panel                              │
                        │   • UpcomingMeetingView (UC1)                       │
                        │   • RecordingHUDView (UC2)                          │
                        │  reads stdin JSON → SwiftUI state → renders         │
                        │  buttons → writes action JSON to stdout             │
                        └─────────────────────────────────────────────────────┘
```

**New artifacts (all additive):**
- `ari-notch/` — new top-level SwiftPM package producing the `ari-notch` binary.
- `frontend/src-tauri/src/notch/` — new Rust module (`mod.rs`, `bridge.rs`, `protocol.rs`,
  `scheduler.rs`).
- New Tauri commands: `notch_enable`, `notch_disable`, `notch_status` (+ a settings key).
- New `externalBin` entry `binaries/ari-notch` in `tauri.conf.json`.
- Build wiring in `scripts/` + `frontend/src-tauri/CLAUDE.md`-adjacent docs.

**Upstream files touched — registration points only:** `lib.rs` (module decl + 3 commands in
`generate_handler!` + sidecar spawn in `run()`/`setup()`), `tauri.conf.json` (`externalBin`),
`scripts/run-local.sh` + `scripts/tauri-auto.js` (stage the new binary like `llama-helper`).

---

## 4. IPC protocol contract (Rust ↔ ari-notch)

Newline-delimited JSON (NDJSON), UTF-8, one message per line, exactly like
`summary_engine/sidecar.rs`. **Bidirectional and streaming** (unlike llama-helper's
request/response): Rust streams state *down*; the sidecar streams actions *up*. Every message
has a `"type"` discriminator. Unknown types are ignored (forward-compatible).

### 4.1 Rust → sidecar (state push, on stdin)

```jsonc
// Show/refresh the upcoming-meeting alert (UC1)
{ "type": "upcoming_meeting",
  "event_id": "EVT-123",
  "title": "Weekly 1:1 — Dana",
  "starts_in_seconds": 300,          // countdown source of truth; sidecar ticks locally
  "start_iso": "2026-07-14T21:00:00Z",
  "attendee_count": 2,
  "already_recording": false }

// Dismiss the upcoming alert (meeting started, user acted, or cancelled)
{ "type": "dismiss_upcoming", "event_id": "EVT-123" }

// Recording lifecycle (UC2) — mirror of the Rust events in §6
{ "type": "recording_state",
  "is_recording": true,
  "is_paused": false,
  "meeting_name": "Weekly 1:1 — Dana",
  "elapsed_seconds": 132,            // authoritative; sidecar ticks between updates
  "linked_event_id": "EVT-123" }

// Live audio meter (throttled to ≤10 Hz by the bridge — see §7 perf)
{ "type": "audio_level", "level": 0.42 }   // 0.0–1.0, normalized

// Optional: latest transcript line for ambient display
{ "type": "transcript_line", "text": "…so the next step is…", "speaker": null }

// Config / teardown
{ "type": "config", "show_transcript_line": true, "theme": "dark" }
{ "type": "shutdown" }
```

### 4.2 Sidecar → Rust (user actions, on stdout)

```jsonc
// UC1 Record button — start recording pre-linked to this event
{ "type": "action", "action": "record_event", "event_id": "EVT-123" }

// UC2 controls
{ "type": "action", "action": "pause" }
{ "type": "action", "action": "resume" }
{ "type": "action", "action": "stop" }

// Deep-link into the app (focus main window, optional route)
{ "type": "action", "action": "open_app", "route": "/meeting-details?id=…" }

// Lifecycle / health
{ "type": "ready" }                        // sidecar finished init, ready for state
{ "type": "log", "level": "info", "message": "…" }   // forwarded to Rust log
```

### 4.3 Contract rules (enforced in tests)
- **Countdown & elapsed clocks tick locally in the sidecar** between authoritative updates;
  Rust re-syncs the true value on every state push. Never rely on Rust to tick every second.
- **No-Fake-State (design-system rule).** The sidecar renders only values it has been given.
  No invented durations, levels, or counts. Before first `recording_state`, show nothing.
- The bridge is the **only** writer to sidecar stdin and the **only** reader of its stdout.
- All actions map to **existing** Rust commands (§6) — the sidecar never touches the DB or
  audio engine directly.

---

## 5. Workstreams (agent-assignable)

Designed for parallel execution. Dependency graph:

```
WS-A (protocol crate + types)  ─┐
                                ├─▶ WS-B (Rust bridge)  ─┐
WS-E (Swift scaffold+build) ───┘                        ├─▶ WS-F (integration + E2E)
WS-C (Swift UC2 HUD view) ──────────────────────────────┤
WS-D (reminder scheduler) ──────────────────────────────┤
WS-G (Swift UC1 alert view) ────────────────────────────┘
```

WS-A is the keystone (defines the shared schema); everything else can start once its types
land. WS-C/WS-G (Swift views) and WS-B/WS-D (Rust) are fully parallel after WS-A + WS-E.

---

### WS-A — Protocol & shared types  `[blocks: B, C, D, G]`
**Deliverable:** `frontend/src-tauri/src/notch/protocol.rs` — serde structs/enums for every
message in §4, `#[serde(tag = "type")]` tagged enums `NotchInbound` (Rust→sidecar) and
`NotchOutbound` (sidecar→Rust), with `snake_case`/exact field names matching §4. Plus a
mirror Swift `Codable` file `ari-notch/Sources/AriNotch/Protocol.swift`.
**Acceptance:**
- Round-trip test: serialize each Rust variant, assert JSON matches a fixture string.
- The Swift `Codable` decodes the same fixtures (checked in WS-E's test target).
- Fixtures live in `frontend/src-tauri/src/notch/fixtures/*.json` and are shared by both
  sides (single source of truth for the wire format).

### WS-B — Rust bridge (`NotchBridge`)  `[needs: A, E-stub]`
**Deliverable:** `frontend/src-tauri/src/notch/bridge.rs` + `mod.rs`.
- `NotchBridge` owns the `ari-notch` child (spawn/respawn/shutdown), modeled on
  `SidecarManager` (`summary_engine/sidecar.rs`) — reuse its spawn/stdin-write/stdout-read
  shape, binary-path resolution (`resolve_helper_binary` analogue, env override
  `ARI_NOTCH_BIN`), and `stderr(Stdio::inherit())`.
- Subscribes to recording events and forwards them as `recording_state` / `audio_level` /
  `transcript_line` messages. **Throttle `audio_level` to ≤10 Hz** and elapsed re-sync to
  ~1 Hz (do not forward every `audio-levels` event — see §7).
- Reads sidecar stdout; dispatches `action` messages to existing commands (§6). `record_event`
  → `start_recording_with_devices_and_meeting` **then** `calendar_link_meeting`, replicating
  the readiness checks from `useRecordingStart.ts` (Parakeet model present + mic permission)
  or surfacing the same error path.
- Commands: `notch_enable`, `notch_disable`, `notch_status` (registered in `lib.rs`), gated by
  a `store` key `showNotch` (default: on for notched Macs; see WS-E for notch detection — the
  sidecar reports capability via `ready`).
**Acceptance:**
- With a stub sidecar that echoes stdin to a log, `cargo test` proves: recording start emits a
  `recording_state{is_recording:true}` within 500 ms; a stubbed stdout `action:stop` invokes
  the stop path.
- `audio_level` forwarding is rate-limited (unit test on the throttle).
- No panics if the sidecar dies mid-recording; bridge respawns and re-sends current state.

### WS-C — Swift Recording HUD view (UC2)  `[needs: A, E]`
**Deliverable:** `ari-notch/Sources/AriNotch/RecordingHUDView.swift`.
- SwiftUI view bound to an `@Observable` model fed by decoded `recording_state` /
  `audio_level` / `transcript_line`. Shows: elapsed (mm:ss, ticked locally), REC indicator
  (amber, per design-system Signal Rule — amber ≤8%), a live level bar, optional transcript
  line, and Pause/Resume + Stop buttons emitting `action` messages.
- Paused state visually distinct; Stop shows a brief confirming state.
**Acceptance:**
- Feed a scripted NDJSON stream (fixture) → view renders each state; snapshot or
  state-assertion test in the Swift test target.
- Buttons emit exactly the §4.2 JSON on stdout.

### WS-D — Reminder scheduler (completes F5)  `[needs: A]`
**Deliverable:** `frontend/src-tauri/src/notch/scheduler.rs`.
- Background tokio task (spawned in `setup()` alongside `calendar::sync::spawn_background_sync`,
  `lib.rs:530`). Periodically reads upcoming events via the calendar repository /
  `calendar_get_events_range`, and at each configured lead time (`meeting_reminder_minutes`,
  default `[15,5]` in `notifications/settings.rs`) fires an `upcoming_meeting` message to the
  bridge — **and** optionally the existing `show_meeting_reminder`
  (`notifications/manager.rs:160`, currently uncalled).
- De-dupes: one alert per (event, lead-time); respects DND/consent gates already in
  `notifications/`.
- Sends `dismiss_upcoming` when the event starts, is recorded, or is cancelled.
**Acceptance:**
- Unit test with an injected clock + fake event set: asserts exactly one `upcoming_meeting`
  fires at T-15 and T-5, none earlier, and `dismiss_upcoming` at start.
- Wiring test: the previously-orphaned `show_meeting_reminder` now has a live caller.

### WS-E — Swift package scaffold + build integration  `[blocks: C, G; needs: nothing]`
**Deliverable:** `ari-notch/` SwiftPM package (executable target `ari-notch`), DynamicNotchKit
dependency, a `main.swift` that: reads NDJSON from stdin on a background thread, decodes into
the model, drives a `DynamicNotch` panel, writes actions to stdout, detects notch vs capsule
(`safeAreaInsets.top` / DynamicNotchKit capability) and reports it in `ready`.
- Build script: `swift build -c release --arch arm64` → copy to
  `frontend/src-tauri/binaries/ari-notch-aarch64-apple-darwin`.
- Extend `scripts/run-local.sh` and `scripts/tauri-auto.js` to stage `ari-notch` exactly as
  they stage `llama-helper` (first-run build + copy with target-triple suffix).
- Add `binaries/ari-notch` to `externalBin` in `tauri.conf.json` (and QA confs).
**Acceptance:**
- `swift build -c release` produces a binary that, run standalone and fed a fixture NDJSON
  stream on stdin, shows the notch and prints a `ready` line.
- `pnpm run app:local` bundles the binary; it launches without a missing-sidecar error.
- Documents the macOS-version floor DynamicNotchKit requires (≥14.x) — confirm against our
  minimum target and record in `build-and-run.md`.

### WS-F — Integration & end-to-end  `[needs: B, C, D, G]`
**Deliverable:** the two flows working in the signed `.app`.
**Acceptance (manual, via `pnpm run app:local` — TCC-real build):**
- UC2: start a recording from the app → notch HUD appears with ticking elapsed + live level;
  Stop from the notch ends the recording; state reconciles with the main window.
- UC1: with a calendar event ~5 min out (use a seeded/near-term test event), the notch alert
  appears; tapping Record starts a recording linked to that event (verify `meeting_id` set on
  the `CalendarEvent` row); alert dismisses.
- Kill `ari-notch` mid-recording → bridge respawns → HUD returns with correct state.

### WS-G — Swift Upcoming-meeting alert view (UC1)  `[needs: A, E]`
**Deliverable:** `ari-notch/Sources/AriNotch/UpcomingMeetingView.swift`.
- Bound to decoded `upcoming_meeting`; shows title, local countdown, attendee count, a primary
  **Record** button (amber accent) emitting `action:record_event`, and a dismiss affordance.
- Auto-collapses on `dismiss_upcoming`.
**Acceptance:** fixture-driven render test; Record button emits the correct `event_id`.

---

## 6. Backend seam reference (verified `file:line`)

**Recording events (Rust→FE, reuse via bridge) — `audio/`:**
- `recording-started` — `recording_commands.rs:294`/`:478`
- `recording-stopped`, `recording-paused` `:942`, `recording-resumed` `:976`
- `recording-shutdown-progress` `:511,561,589,627`, `recording-error` `:232,416`
- `transcript-update` — `transcription/worker.rs:222`
- `audio-levels` — `audio/simple_level_monitor.rs:70`, `level_monitor.rs:107`

**Recording state (pull):** `get_recording_state` command — `recording_commands.rs:1007`
returns `{is_recording,is_paused,is_active,recording_duration,active_duration,…}`. Elapsed is
**not** event-pushed; bridge polls this ~1 Hz or reads `RecordingState` durations
(`recording_state.rs:351-379`).

**Start recording:** `start_recording_with_devices_and_meeting`
(`recording_commands.rs:318`, registered `lib.rs:75`) — args camelCase
`{micDeviceName, systemDeviceName, meetingName}`. There is **no** event-link arg; link after
via `calendar_link_meeting(eventId, meetingId)` (registered `lib.rs:791-807`). Mirror readiness
checks in `useRecordingStart.ts:141` (`startBackendRecording`).

**Controls:** `stop_recording`, `pause_recording`, `resume_recording` (see `tray.rs` handlers
`:135-191` for the existing programmatic-invoke pattern; the bridge should call the commands
directly, not the tray's sessionStorage poke).

**Calendar:** events via `calendar_get_events_range(startIso,endIso)` / `calendar_get_events`;
model `CalendarEvent{start_time,end_time,title,attendees,meeting_id,link_source}`
(`calendar/models.rs:24`); background sync emits `calendar-sync-updated`
(`calendar/sync.rs:188`, spawned `lib.rs:530`).

**Reminder plumbing (currently unwired — WS-D wires it):** `MeetingReminder(minutes)`
(`notifications/types.rs:23`), `Notification::meeting_reminder` (`:168`),
`show_meeting_reminder` (`notifications/manager.rs:160`, **no caller today**),
`meeting_reminder_minutes:[15,5]` (`notifications/settings.rs:91`).

**Sidecar precedent to copy:** `summary/summary_engine/sidecar.rs` — spawn at `:287-310`
(`tokio::process::Command`, `nice`, piped stdin/stdout, inherited stderr), NDJSON write
`:364-368/:424-425`, read `:401`, parse `:435`; binary-path resolution `:108-120`; managed
via a `SidecarManager` struct. `externalBin` config `tauri.conf.json:103-105`.

---

## 7. Performance & concurrency requirements

- **Never block the audio pipeline.** The bridge subscribes to events on its own task; it
  must not do IPC writes on any audio-thread callback. Follow the PCM-tap discipline
  (`.claude/context/open-questions.md` Q2): clone/forward, never block.
- **Throttle high-frequency streams.** `audio-levels` can fire many times/sec; the bridge
  coalesces to ≤10 Hz for the notch. Elapsed re-sync ≤1 Hz. Transcript lines: latest-wins,
  no backlog.
- **Sidecar is best-effort.** If `ari-notch` is absent/crashed, the app functions normally;
  the bridge logs and retries with backoff. Notch failure never affects recording integrity.
- **Idle behavior.** No recording + no imminent meeting → the sidecar shows nothing and stays
  cheap (or the bridge stops it, respawn on next need — decide in WS-B; default: keep alive,
  it's tiny).
- **Hot-path logging** uses `perf_debug!`/`perf_trace!` where applicable; not raw `log::debug!`.

---

## 8. Design-system requirements (`.claude/rules/design-system.md`)

- **Signal Rule:** Arivo Amber (`#E8A020`) is the recording/active signal only, ≤8% of the
  surface. REC dot and primary Record button use amber; labels/countdowns use muted ink.
- **No-Fake-State (absolute):** notch shows only real, backend-provided values (§4.3).
- Warm-neutral palette, flat, Space Grotesk. The notch is small — prioritize legibility and a
  single clear signal over ornament. Dark-mode aware (notch background is near-black anyway).
- Any design tokens duplicated into Swift must be recorded so they don't silently drift from
  `DESIGN.json` (the visual-system test only covers the web UI — note the gap explicitly).

---

## 9. Risks & open decisions

| # | Item | Owner decision needed |
|---|------|----------------------|
| R1 | **DynamicNotchKit license** — confirm exact license (README implies permissive; verify LICENSE file is MIT/BSD/Apache before vendoring into an MIT app). If copyleft, fall back to a minimal in-house NSPanel. | **Verify before WS-E merges.** |
| R2 | **macOS version floor.** DynamicNotchKit targets recent macOS (≈14.x+). Confirm it meets/*raises* our minimum deployment target; record in `build-and-run.md`. | Confirm in WS-E. |
| R3 | **Second binary signing/TCC.** `ari-notch` is a separate process; ensure it's covered by the `Ari Dev Signing` identity in the bundle and needs no privacy entitlements of its own (it draws UI only, no mic/calendar access — all sensitive data arrives pre-fetched over stdin). | Validate in WS-F. |
| R4 | **Sidecar vs Tauri-window fallback.** If bundling/launching the Swift binary proves flaky, fall back to the transparent-window path (§2). | Only if R-blocker hits. |
| R5 | **UC1 quick-record device selection.** `start_recording_with_devices_and_meeting` takes optional device names; the notch has no device picker. Use last-used/default devices; confirm that path is sound. | Decide in WS-B. |
| R6 | **Notch capability detection** on external/non-notched displays → capsule mode; confirm DynamicNotchKit handles multi-display / clamshell gracefully. | Test in WS-E/F. |

**Deferred:** transcript scrolling in-notch; per-speaker labels (waits on F1); notch settings UI
beyond a single on/off toggle.

---

## 10. Suggested phasing

1. **Phase 1 (foundation):** WS-A + WS-E — protocol + Swift scaffold that builds, bundles, and
   shows a static notch fed a fixture. De-risks the whole approach (R1–R3).
2. **Phase 2 (UC2 first — pure event consumer):** WS-B + WS-C — recording HUD end-to-end. This
   needs *no* new backend capability, only wiring, so it's the fastest visible win.
3. **Phase 3 (UC1):** WS-D + WS-G — reminder scheduler (completes F5) + alert view + quick
   record.
4. **Phase 4:** WS-F integration hardening, respawn/edge cases, docs.

Rationale: UC2 consumes events that already exist and proves the sidecar path before we invest
in the net-new scheduler for UC1.
