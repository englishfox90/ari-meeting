# Notch Panel Absorption — in-process Dynamic-Island overlay for the native Ari app

**Status:** planned (swift-architect, 2026-07-22) · **Phase:** 2, S7 tail — "notch panel absorption" (`plans/swift-migration-plan.md:156`, `:162`, `:268`)
**Source being ported:** `ari-notch/` sidecar (SwiftPM executable, NDJSON stdio) · **Rust bridge (`frontend/src-tauri/src/notch/`) and the sidecar stay untouched and frozen.**

**Decisions taken (2026-07-22):** `showNotchOverlay` defaults **OFF**; hover "Open Ari" ships with the stored-`OpenWindowAction` + `NSApp.activate`-only fallback. ~~Upcoming surface stays inert until Phase 3.2~~ — **superseded by Amendment A (same day):** the scheduler brain ports natively in this effort and the upcoming surface goes live.

## 1. Goal & seam

Absorb the `ari-notch` sidecar's *panel* — the simulated Dynamic Island (NSPanel host + island chrome + recording HUD + upcoming-meeting alert) — into the native `Ari` macOS app as an in-process overlay, bound directly to the app's own `@Observable` state instead of the NDJSON wire protocol.

- **Seam:** Phase 2 native shell, S7 tail. The migration plan is explicit that this absorption is "the panel, not the brain" (`plans/swift-migration-plan.md:162`): the Rust `scheduler.rs` upcoming-reminder brain ports with the engine in Phase 3.2 and is **out of scope here**.
- **Target-side check (principle 8):** this *is* a re-implementation of a feature the frozen Rust app hosts — but it is the explicitly scheduled Phase-2 absorption item, landing entirely on the Swift side against `RecordingSession`. It does not extend the Rust app; the Rust bridge and sidecar keep working unmodified for the frozen baseline.
- **What dies in the port:** `ari-notch/Sources/AriNotch/Protocol.swift`, `NotchModel.swift` (the wire-fold model), `main.swift` (stdio loop), and the `NotchActionEmitter` abstraction. The wire-conformance tests (`ProtocolTests.swift`) do **not** carry over. The sidecar itself is *not deleted* in this feature (it remains the frozen app's UI; deletion is a Phase 5 cleanup).
- **What ports:** the panel behavior (`IslandPanelController.swift` — borderless non-activating `TopEdgePanel` at `.mainMenu + 3`, primary-screen pin, `constrainFrameRect` override, `canJoinAllSpaces`/`fullScreenAuxiliary`, `orderFrontRegardless` never `makeKey`, `safeAreaRegions = []`, notch detection via `safeAreaInsets`/auxiliary top areas, re-anchor on `didChangeScreenParametersNotification`), the chrome (`IslandContainerView`/`IslandShape`/`IslandEnvironment`), the pure math (`IslandGeometry`, `IslandPresentation`), the two content views, and the style layer — re-themed onto Marginalia.

## 2. Module & surface (where the code lands, and why)

Split along the established MenuBar precedent (`Ari/UI/MenuBar/MenuBarContentView.swift` in the app target; its logic seams in `AriViewModels`): **pure/testable logic goes to `AriKit/Sources/AriViewModels/Notch/`** (the `Ari` app target has no test target — `swift test` coverage requires SwiftPM), **AppKit host + SwiftUI chrome go to the app target `Ari/UI/Notch/`** (NSPanel is Mac-app-only; the iOS Lite app will never host it).

### `AriKit/Sources/AriViewModels/Notch/` (new folder)

```swift
// IslandGeometry.swift — ported verbatim from ari-notch (CoreGraphics-only, AppKit-free)
public enum IslandGeometry {
    public static func islandFrame(inScreen screenFrame: CGRect, contentSize: CGSize) -> CGRect
    public static func notchWidth(screenWidth: CGFloat, leftAuxWidth: CGFloat, rightAuxWidth: CGFloat) -> CGFloat?
}

public enum IslandPresentation: Equatable, Sendable {
    case hidden, collapsed, expanded   // collapsed stays reserved/unused, as today
    /// Rewritten to derive from the app's real phase (replaces the wire model's two booleans).
    public static func derive(phase: RecordingSession.Phase, hasUpcoming: Bool) -> IslandPresentation
}

// NotchUpcomingProviding.swift — the Phase-3.2 seam. NO live conformer ships in this feature.
public struct NotchUpcomingMeeting: Equatable, Sendable {
    public var eventId: CalendarEventID
    public var title: String
    public var startDate: Date
    public var attendeeCount: Int
    public var alreadyRecording: Bool
}
@MainActor public protocol NotchUpcomingProviding: AnyObject, Observable {
    var current: NotchUpcomingMeeting? { get }
}

// NotchOverlayModel.swift — the testable brain (the successor of the sidecar's NotchModel)
@MainActor @Observable
public final class NotchOverlayModel {
    public init(session: RecordingSession, upcoming: (any NotchUpcomingProviding)? = nil,
                onOpenApp: @escaping @MainActor () -> Void,
                onRecordEvent: @escaping @MainActor (CalendarEventID) -> Void)
    public var presentation: IslandPresentation { get }   // derives from session.phase + upcoming
    public var isRecording: Bool { get }                  // phase == .recording
    public var isStopping: Bool { get }                   // phase == .stopping → honest "Stopping…"
    public var meetingTitle: String? { get }              // session.pendingTitle → persisted title
    public var audioLevel: Float { get }                  // session.liveLevel, verbatim
    public var latestSegmentText: String? { get }         // session.segments.last?.text (real, or nothing)
    public func displayedSeconds(at now: Date) -> UInt64  // from .recording(startedAt:) only; else 0-advance
    public static func formatElapsed(_ seconds: UInt64) -> String     // ported
    public static func formatCountdown(_ seconds: UInt64) -> String   // ported ("Starting now" at 0)
    public static func formatAttendees(_ count: Int) -> String        // ported
    public func stopTapped()                              // Task { await session.stop() } — no local state lies
    public func openAppTapped()
    public func recordTapped()                            // guards alreadyRecording; calls onRecordEvent
    public func dismissUpcoming()                         // local-only, records dismissed eventId
}

// NotchVisibilityStore.swift — under Support/, mirroring MenuBarVisibilityStore.swift verbatim
public struct NotchVisibilityStore: Sendable {
    public static let defaultsKey = "showNotchOverlay"
    public var isVisible: Bool { get nonmutating set }    // UserDefaults.standard; default OFF
}
```

### `Ari/UI/Notch/` (app target)

- `TopEdgePanel.swift` + `NotchPanelController.swift` — the port of `IslandPanelController.swift` (all panel behavior verbatim: style mask, level, collection behavior, `hasShadow = false`, `safeAreaRegions = []`, primary-screen anchoring, `orderFrontRegardless`, screen-parameter observer, size-follow via `onResize`). Constructor takes `NotchOverlayModel` instead of `NotchModel` + emitter.
- `IslandContainerView.swift` (+ `IslandShape`, `IslandEnvironment`) — ported near-verbatim; `presentation` now reads `model.presentation`; forces `.environment(\.colorScheme, .dark)` on its content (the island is black; Marginalia must resolve its **dark** palette regardless of app appearance).
- `NotchRootView.swift` — router: upcoming (when provider has one) else HUD; unchanged logic.
- `NotchRecordingHUDView.swift` — the HUD, **pause/resume dropped** (no pause phase exists on `RecordingSession` — same honesty call `MenuBarContentView.swift:12-13` made). Rows: REC dot + elapsed + title + open-app (hover), `AudioMeterView`, transcript line (last real segment), Stop. The sidecar's local `stopConfirming` `@State` is **replaced by the real `.stopping` phase** — an improvement, not a divergence.
- `NotchUpcomingMeetingView.swift` — ported, driven by `NotchUpcomingMeeting` (presentation-inert until Phase 3.2 supplies a provider; see §4).
- `NotchOverlayStyle.swift` — replaces `NotchStyle.swift`: `NotchGlassCapsuleButtonStyle`, `NotchAccentCapsuleButtonStyle` (Marginalia accent), `NotchRecordingCapsuleButtonStyle` (recordingRed — new, for Stop), `CircleIconButtonStyle`, `AudioMeterView`. **`NotchPalette` and every hex literal die.**
- `NotchOverlayCoordinator.swift` — small `@MainActor` object owned by `AppEnvironment`: observes the `showNotchOverlay` defaults key (`UserDefaults.didChangeNotification`, main queue, `MainActor.assumeIsolated` — the sidecar's own observer pattern, `IslandPanelController.swift:215-221`), constructs/tears down `NotchPanelController` + `NotchOverlayModel` accordingly.

### Wiring into `AppEnvironment` (`Ari/App/AppEnvironment.swift`)

In `bootstrap()`, after `recordingSession` exists (`AppEnvironment.swift:158-170`):

```swift
notchOverlay = NotchOverlayCoordinator(
    session: session,
    onOpenApp: { [weak self] in self?.activateApp() },                 // see §11 risk R4 on openWindow
    onRecordEvent: { [weak self] id in Task { await self?.startRecordingFromReminder(eventId: id) } }
)
```

`activateApp()` is today private view logic in `MenuBarContentView.swift:177-184`; hoist a shared variant onto `AppEnvironment` (NSApp.activate + front existing main window; `openWindow` fallback via an `OpenWindowAction` handed up from the main window's root view — see risk R4). The record closure reuses **the same prime-and-start path reminders and the menu bar use** (`startRecordingFromReminder`, `AppEnvironment.swift:332-359`) so entry points can never diverge.

## 3. Concurrency model

- **Everything is `@MainActor`.** `RecordingSession`, the model, the panel controller, the coordinator, and all SwiftUI. No new executors, no `@unchecked Sendable`, no `nonisolated(unsafe)`.
- **Observation drives the panel** exactly as in the sidecar: `IslandContainerView.body` reads `model.presentation` (establishing Observation tracking on `session.phase` / the upcoming provider) and pushes transitions up through `onPresentationChange` → `applyPresentation` (`orderFrontRegardless` / `orderOut`). No polling, no timers except `TimelineView(.periodic)` for the 1 s clock re-render.
- **Nothing here can block the audio hot path or STT.** The overlay only *reads* `session.liveLevel` / `segments` — both already delivered onto the main actor by `RecordingSession`'s own tasks (`RecordingSession.swift:343-365`). `stopTapped()` wraps `session.stop()` in a `Task`, same as `MenuBarContentView.swift:164`.
- **`deinit` caveat (justify in a comment, as the sidecar does):** the controller/coordinator remove `NotificationCenter` observers in a non-isolated `deinit`; `removeObserver` is documented thread-safe (`IslandPanelController.swift:287-294` precedent).
- Sidecar targeted macOS 14; the app floor is **macOS 26** — no availability shims; newer APIs allowed.

## 4. Presentation state machine — and what drives `UpcomingMeetingView`

```
IslandPresentation.derive(phase:hasUpcoming:)
  .recording, .stopping                        → .expanded   (HUD; .stopping renders honest "Stopping…")
  .idle, .consentPrompt, .starting, .saved,
  .failed                                      → .hidden     — unless hasUpcoming → .expanded (alert)
hasUpcoming = upcomingProvider?.current != nil && current.eventId != locallyDismissedId
```

`.starting`/`.consentPrompt` deliberately stay hidden: the user just acted in the app/menu bar (which already show "Starting…"); the island appearing only when capture is *actually live* is the No-Fake-State-correct read of the sidecar's `isRecording` gate. `.collapsed` stays reserved/unused, as today (`IslandGeometry.swift:28-30`).

**Decision: defer the live driver to Phase 3.2; ship recording-HUD-only now.** Reasoning:

1. The timing brain is exactly the excluded scope. Any native driver must decide *when* an event is "imminent" — that is the Rust `scheduler.rs` logic. `CalendarBriefViewModel`'s 3-hour lookahead (`CalendarBriefViewModel.swift:24-31`) is a *shortcut list* window, wildly wrong for an island that would then sit expanded for hours; deriving a tighter window (lead-minutes before start) is a hand-rolled second scheduler that Phase 3.2 would immediately have to reconcile.
2. F5's calendar-triggered prompt **already exists natively**: `MeetingNotifications.reconcileReminders()` + `MeetingReminderPlanner` schedule OS reminders whose "Start recording" action drives `startRecordingFromReminder` (`MeetingNotifications.swift:94-127`, `AppEnvironment.swift:305-311`). The user is not left without a prompt. (Foreground-only `willPresent` delivery was considered as a driver and rejected: it never fires when Ari is backgrounded — the common case during meetings.)
3. WIP limits: wiring a live upcoming driver opens a second feature (the F5 island prompt) inside this one.

**What still ports now:** `NotchUpcomingMeetingView`, its formatting/clamp/no-double-record logic, and its tests — compiled, unit-tested, previewable — behind the `NotchUpcomingProviding` seam with **no live conformer**. Phase 3.2's scheduler port supplies the conformer (fed by `MeetingReminderPlanner`-consistent timing) and the surface lights up without touching this code. This is a seam, not dead code: the port of the sidecar's UI is complete, only its driver is scheduled where the plan says the brain lives.

## 5. Re-theming — `NotchPalette` → Marginalia

The island chrome stays **pure black** (hardware fusion with the physical notch — `IslandContainerView.swift:139-141`; deliberately not a token). All content resolves the **Marginalia dark palette** (`MarginaliaColor.swift`, `brand/tokens.json` `modes.dark`) via the forced dark `colorScheme` on the hosted root. **No amber token survives** (`#E8A020`, `#F5EFE6`, `#A89F90` all deleted with `NotchStyle.swift`).

| Old `NotchPalette` role | Surface | Marginalia replacement (dark value) |
|---|---|---|
| `amber` `#E8A020` — REC dot | live-recording dot (pulse kept, only while `.recording`) | `.recordingRed` `#FF6B5E` |
| `amber` — Stop button fill | primary capture control | `.recordingRed` (matches `MenuBarRow` `.recording` emphasis, `MenuBarContentView.swift:115`) |
| `amber` — Record button fill (upcoming) | primary non-capture action | `.accent` `#7E9BE8` (matches `MenuBarRow` `.accent`) |
| black label on amber | label on filled capsule | `.canvas` `#211E1B` (the `MenuBarRow` foreground reasoning, `MenuBarContentView.swift:248-253`) |
| `ink` `#F5EFE6` | timer, title, glass-button labels | `.inkBody` `#EDE8E1` |
| `mutedInk` `#A89F90` | eyebrows (REC/UPCOMING), countdown, attendees, meter fill, transcript speaker | `.inkSecondary` `#A89F92` |
| `.ultraThinMaterial` glass | secondary capsules, circle icon button | kept — native material, not a brand color |

Signal-Rule analog preserved: **`recordingRed` appears only on the REC dot + Stop; `accent` only on the single primary Record action**; everything else is ink/glass — the exact discipline the sidecar documented for amber (`NotchStyle.swift:12-16`), re-expressed in Marginalia roles.

## 6. Persistence & the enable/disable preference

- **No database surface.** No new tables, no repository methods; the single-DB-owner rule is untouched (the overlay reads only through `RecordingSession`, which already goes through `AppDatabase` repositories).
- **Preference:** `NotchVisibilityStore` in `AriKit/Sources/AriViewModels/Support/` — a byte-for-byte sibling of `MenuBarVisibilityStore.swift` (device-local UI preference → `UserDefaults`, **not** the `setting` table; same rationale, `MenuBarVisibilityStore.swift:3-11`). Key `showNotchOverlay`, **default OFF** — parity with the frozen Rust bridge, which stays dormant unless `showNotch` is truthy (`frontend/src-tauri/src/notch/bridge.rs:754-776`). The Rust `showNotch` value lives in the Tauri store's `settings.json` and is deliberately **not imported** (separate app, separate device-local preference).
- **Settings UI:** a `MarginaliaToggleRow` in `Ari/UI/Settings/SettingsGeneralSection.swift` beside the menu-bar toggle, backed via `SettingsViewModel` exactly as `MenuBarVisibilityStore` is. Live insert/remove is handled by `NotchOverlayCoordinator`'s defaults observation (no scene re-evaluation needed — the panel is not a SwiftUI `Scene`).

## 7. Acceptance tests (written first)

All unit suites land in `AriKit/Tests/AriViewModelsTests/` (Swift Testing for new logic; the geometry port converts to `@Suite`/`#expect` since the functions move modules).

**Ported from `ari-notch/Tests/AriNotchTests/`:**

1. `IslandGeometryTests` → `NotchGeometryTests` — all 6 frame/notch-width cases verbatim (primary-screen centering, offset secondary screen, negative origin, notch present/absent/zero-aux); the 4 presentation cases re-expressed against `derive(phase:hasUpcoming:)`.
2. `RecordingHUDTests` → `NotchOverlayModelTests` — `formatElapsed` table (`00:00`/`02:05`/`60:00`/`00:09`/`09:59`); "clock never fabricates time when not recording" (`displayedSeconds(at: future) == 0` in every non-`.recording` phase); Stop drives `session.stop()` (built on the existing `RecordingSessionTests` in-memory-DB + mock-capture harness). **Dropped:** pause/resume cases (no pause phase — documented), all fixture/wire-shape cases (protocol dies).
3. `UpcomingMeetingTests` → `NotchUpcomingModelTests` — `formatCountdown` table incl. `"Starting now"` at 0; `formatAttendees`; countdown clamp-at-zero (never negative); `recordTapped()` no-op when `alreadyRecording`; local dismiss emits nothing and leaves provider state untouched. **Dropped:** fixture decode + flat-wire-encode cases.

**New:**

4. `NotchPresentationTests` — exhaustive `Phase` → presentation map: `.recording`/`.stopping` → `.expanded`; `.idle`/`.consentPrompt`/`.starting`/`.saved`/`.failed` → `.hidden`; any phase + upcoming → `.expanded`; locally-dismissed upcoming → `.hidden` when idle.
5. **Consent invariant (ported per plan principle 6):** constructing `NotchOverlayModel` over an `.idle` session, reading `presentation`, and calling every model action except via the sanctioned record closure never invokes `CaptureService.start` (mock capture service asserts zero calls — mirrors the `RecordingSessionTests` consent case); `recordTapped()` calls only the injected `onRecordEvent` (which the app binds to `startRecordingFromReminder`, whose in-flight-consent guard is itself already covered by its phase switch, `AppEnvironment.swift:340-345`).
6. `NotchVisibilityStoreTests` — default `false` on absent key; set/get round-trip (mirrors any `MenuBarVisibilityStore` coverage).
7. `NotchStyleParityTests` — walks to `Ari/UI/Notch/` via `#filePath` (the sidecar tests' own fixture-resolution pattern) and asserts **no hex color literal and no `E8A020`** appears in the notch sources except the documented pure-black chrome — the "old amber must not survive" gate as a test, not an intention.

**Not unit-testable → `/swift-run` human observation checklist** (signed bundle; the sidecar README's own caveat that the live look needs a display, `ari-notch/README.md:19-24`):
- island appears on record start, fuses flush with the physical notch (no gap, no shadow rim), disappears entirely after Stop→saved;
- clicking Stop works **without the frontmost app losing focus** (type in another app while clicking);
- "Stopping…" shows during the real drain; timer matches the recording page's elapsed;
- audio meter moves with real speech, flat at silence;
- correct pill/merge behavior on non-notched external display; primary-display pin under a two-screen arrangement; re-anchor after changing the main display;
- Settings toggle inserts/removes the panel live; default is off on a fresh defaults domain.
- if an upcoming-meeting alert fires mid-recording, the alert replaces the HUD (Stop hidden until Dismiss) — sidecar-parity behavior; confirm it feels acceptable.

## 8. Invariants preserved

- **Consent-before-record:** the island never bypasses `RecordingSession`'s consent edges. Stop is its only capture control this slice; the (future-driven) Record routes through `startRecordingFromReminder` — the same `requestStart()` + `confirmConsentRequested()` explicit-user-action path notifications and the menu bar use, including its guard against clobbering an in-flight `.consentPrompt`. The overlay holds no reference to `CaptureService` at all.
- **No-Fake-State:** elapsed derives from the real `startedAt` in `.recording` and never advances otherwise; level is the real `liveLevel` stream; the transcript line is the last *persisted* segment or nothing (no placeholder); "Stopping…" is the real `.stopping` phase, not a local flag; no pause UI for a pause that doesn't exist; countdown clamps at "Starting now"; attendee count only when > 0.
- **Never steal focus:** `.nonactivatingPanel` + `orderFrontRegardless()`, never `makeKey*` — ported verbatim with its comments.
- **Recall safety shell, single-DB-owner:** untouched (no recall surface, no DB surface).

## 9. Out of scope

- ~~The Rust `scheduler.rs` upcoming-reminder brain (Phase 3.2) — including any live `NotchUpcomingProviding` conformer.~~ **Superseded by Amendment A** — the brain ports natively in this effort.
- Deleting the `ari-notch` sidecar, the `frontend/src-tauri/src/notch/` bridge, or any Rust change whatsoever.
- Pause/resume (blocked on a `RecordingSession` pause phase, if ever).
- A configurable transcript-line toggle (the wire `config.show_transcript_line`); revisit if wanted as a Settings row later.

## 10. Sequencing (each step independently green)

1. **Pure layer + tests** — `AriViewModels/Notch/` (`IslandGeometry`, `IslandPresentation`, `NotchOverlayModel`, `NotchUpcomingProviding`, `NotchVisibilityStore`) with suites 1–6. Checkpoint: `swift test` in `AriKit/`.
2. **Chrome + HUD** — `Ari/UI/Notch/` shape/container/style + `NotchRecordingHUDView` + `NotchRootView`; style-parity test (suite 7). Optional: a Design Gallery (DEBUG) section rendering HUD states for visual iteration. Checkpoint: app builds (`/swift-build` via XcodeBuildMCP).
3. **Panel + wiring** — `TopEdgePanel`/`NotchPanelController`/`NotchOverlayCoordinator`; `AppEnvironment.bootstrap()` wiring + hoisted `activateApp()`; Settings toggle. Checkpoint: `/swift-run` + the §7 observation checklist.
4. **Upcoming port (inert)** — `NotchUpcomingMeetingView` behind the seam + suite 3. Checkpoint: `swift test` + build.
4b. **Scheduler port (Amendment A)** — `NotchUpcomingPlanner` + suite 8 (checkpoint: `swift test`), then `NotchUpcomingScheduler` + suite 14 + coordinator wiring (checkpoint: `/swift-run`, human item in A.6).
5. **Human visual pass** on the signed bundle (notched laptop + external display), then update `plans/swift-migration-plan.md` S7-tail status and `ari-notch/README.md` with an "absorbed natively; sidecar serves the frozen Tauri app only" note.

## 11. Risks

- **R1 — `NSHostingView.safeAreaRegions`/panel-level behavior on macOS 26**: the sidecar was authored and built on the same Swift 6.3.3 / macOS 26 toolchain (`ari-notch/README.md:19-22`), so the ported constants are already 26-proven — but only the live pass proves the flush-top look inside a full app bundle.
- **R2 — Swift 6 strict concurrency around AppKit lifecycle** (`deinit` observer removal, main-queue notification closures): follow the sidecar's `MainActor.assumeIsolated` + thread-safe-removal precedent; justify each in a comment, never `@unchecked Sendable`.
- **R3 — double surfaces**: menu-bar panel and notch HUD can both be enabled; both are honest views of the same session, so no conflict — but the observation checklist should confirm no fighting over activation.
- **R4 — "Open Ari" with zero windows open**: a plain `NSHostingView` has no scene-backed `openWindow`. Store the main window's `OpenWindowAction` on `AppEnvironment` from the root view's `onAppear`; if unset, fall back to `NSApp.activate` only (accepted).
- **WIP note:** single feature, single phase (2, S7 tail). ~~The F5 island prompt is the adjacent feature deliberately *not* opened; it sequences behind the Phase 3.2 scheduler port.~~ **Superseded by Amendment A:** the scheduler port is pulled forward into this effort.

---

## Amendment A (2026-07-22) — Port the upcoming-meeting brain (Rust `notch/scheduler.rs`) natively, in this same effort

**Decision change:** the same-day header decision "upcoming surface stays inert until Phase 3.2" is **revoked by the user**. The scheduler ports now, as the second slice of this feature. This pulls the Phase-3.2 item "`ari-notch` scheduler ports with engine" (`plans/swift-migration-plan.md:162`, `:268`) forward into this effort; the migration plan is updated accordingly (see A.7). Still one feature, one seam — the notch overlay — now including its driver. The Rust `frontend/src-tauri/src/notch/scheduler.rs` and `bridge.rs` remain frozen and untouched.

**Decisions taken with the amendment:** single-lead timing (the Swift settings model — one prompt per event at the stored reminder lead, default 5 min), not Rust's `[15, 5]` two-lead default; the island alert is gated by `showNotchOverlay` only, not the `notificationsMeetingReminders` toggle (Rust parity).

### A.1 Source behavior being ported (ground truth)

From `frontend/src-tauri/src/notch/scheduler.rs`:

- **Pure decision core `due_events(now, events, leads, fired, dismissed) -> Reminders {fire, dismiss}`** (`scheduler.rs:97-150`):
  - **Fire** `(event_id, lead)` when the event has no linked recording (`has_meeting == false`), has not started, `|now − (start − lead)| ≤ FIRE_TOLERANCE` (45 s, `scheduler.rs:49`), and the pair is not already in `fired`.
  - **Dismiss** (once) a previously-fired event when the linger window expires (`now ≥ start + 30 min`, `LINGER_AFTER_START`, `scheduler.rs:62`) **or** it gained a `meeting_id`; a dismissed event never fires the same tick (`scheduler.rs:116-124`).
  - **Dismiss** a fired event that vanished from the queried range (cancelled), exactly once even if multiple leads fired (`scheduler.rs:139-147`).
  - Already-dismissed ids are never re-emitted (`scheduler.rs:118`, test `scheduler.rs:457-468`).
- **Glue** (`scheduler.rs:187-298`): 30 s tick (`TICK_INTERVAL`, `:39`), 8 s initial delay (`:42`), DB range query `[now − linger, now + maxLead + 2 min slack]` (`:53`, `:221-225`), leads from notification settings with fallback `[15, 5]` (`:302-315`), `already_recording` snapshot annotates the pushed prompt (`:257-261`), and each fire *also* shows a system reminder notification (`:281`). `fired`/`dismissed` are **in-memory, per-app-run, task-local** (`scheduler.rs:192-193`) — dismissal is per event id, never persisted.
- **Bridge interplay** (`frontend/src-tauri/src/notch/bridge.rs:662-697`): `push_inbound` caches `event_id → title` so a notch-started recording is *named* after the event (the calendar auto-matcher then links it); `DismissUpcoming` evicts the cache. The Swift port **does not need this cache**: `recordTapped()` → `startRecordingFromReminder(eventId:)` fetches the real event and sets both `pendingTitle` and `pendingCalendarLink` (`Ari/App/AppEnvironment.swift:332-359`) — a first-class link, strictly better than name-matching. Parity-plus; no replacement code needed.

### A.2 The pure decision core — `NotchUpcomingPlanner`

New file `AriKit/Sources/AriViewModels/Notch/NotchUpcomingPlanner.swift` (AriViewModels, beside the existing Notch seam — same testability rationale as plan §2). Framework-free, static, side-effect-free; the clock is injected — the Swift mirror of `due_events`.

```swift
public enum NotchUpcomingPlanner {
    /// Rust FIRE_TOLERANCE (scheduler.rs:49): must exceed half the tick interval.
    public static let fireTolerance: TimeInterval = 45
    /// Rust LINGER_AFTER_START (scheduler.rs:62). Deliberately equal to
    /// CalendarBriefViewModel.lateJoinMinutes (CalendarBriefViewModel.swift:28) — the Rust
    /// comment pinned the same equivalence to the panel's LATE_JOIN_MINUTES.
    public static let lingerAfterStart: TimeInterval = 30 * 60
    /// Rust RANGE_SLACK_MINUTES (scheduler.rs:53) — used by the scheduler's range query.
    public static let rangeSlack: TimeInterval = 2 * 60

    /// One admitted (event, lead) pair — Rust's `(String, i64)` fire tuple, typed.
    public struct Fire: Hashable, Sendable {
        public var eventId: CalendarEventID
        public var leadMinutes: Int
    }

    /// Rust `Reminders` (scheduler.rs:80-84).
    public struct Decision: Equatable, Sendable {
        public var fire: [Fire]
        public var dismiss: [CalendarEventID]
    }

    /// Pure mirror of `due_events` (scheduler.rs:97-150). Operates directly on `CalendarEvent`
    /// (AriKit/Sources/AriKit/Models/CalendarEvent.swift) — `has_meeting` ≡ `meetingId != nil`;
    /// no separate SchedEvent projection is needed.
    public static func dueEvents(
        now: Date,
        events: [CalendarEvent],
        leadsMinutes: [Int],
        fired: Set<Fire>,
        dismissed: Set<CalendarEventID>
    ) -> Decision
}
```

**Edge cases carried over from the Rust tests, plus one deliberate divergence:**

- Fire admits inside `±fireTolerance` only; a late app start never resurrects a long-past lead.
- Per-`(event, lead)` de-dup via `fired`; per-event single dismiss via `dismissed`; a dismissing event never also fires that tick; vanished events dismiss once across multiple fired leads.
- Multi-lead input stays supported in the pure core (exact Rust-test parity) even though the app passes a single lead (A.4).
- **Divergence (documented, deliberate): all-day events are skipped** (`event.isAllDay`). Rust's `due_events`/`row_to_sched` never filters all-day (`scheduler.rs:157-177`) — a latent bug that could fire a midnight prompt; every sibling Swift surface already skips them (`MeetingReminderPlanner.swift:57`, `CalendarBriefViewModel.swift:79`). The Swift test suite encodes the *fixed* behavior; this is the one place the candidate deliberately beats rather than matches the incumbent.

### A.3 `NotchUpcomingScheduler` — the live conformer

New file `AriKit/Sources/AriViewModels/Notch/NotchUpcomingScheduler.swift`:

```swift
@MainActor @Observable
public final class NotchUpcomingScheduler: NotchUpcomingProviding {
    /// The last fired, not-yet-dismissed alert (single slot; a later fire replaces an earlier
    /// one — Rust pushed each fire and the sidecar showed the last, same net behavior).
    public private(set) var activeAlert: ActiveAlert?

    public struct ActiveAlert: Equatable, Sendable {
        public var eventId: CalendarEventID
        public var title: String
        public var startDate: Date
        public var attendeeCount: Int
    }

    /// NotchUpcomingProviding. `alreadyRecording` is COMPUTED LIVE from `session.phase`
    /// (never the stale at-fire-time snapshot Rust sent, scheduler.rs:257-261): true for
    /// .consentPrompt/.starting/.recording/.stopping — exactly the phases where
    /// startRecordingFromReminder would refuse to start (AppEnvironment.swift:340-345), so the
    /// Record button's disabled state is honest. Reading `session.phase` here gives Observation
    /// tracking for free — the button re-enables the instant a recording ends.
    public var current: NotchUpcomingMeeting? { get }

    public init(
        database: AppDatabase,
        session: RecordingSession,
        now: @escaping @Sendable () -> Date = Date.init,
        tickInterval: Duration = .seconds(30),   // Rust TICK_INTERVAL, scheduler.rs:39
        initialDelay: Duration = .seconds(3)     // vs Rust's 8 s DB-warm-up (scheduler.rs:42);
                                                 // we are constructed post-bootstrap, DB is ready
    )
    /// Test hook: one synchronous evaluation against `now()` (the tick body, minus sleeping).
    public func evaluateNow() async
}
```

- **Tick body** (mirrors `scheduler.rs:204-298`, minus the notch-push wire and the system notification — see A.5): read the stored lead (`database.settings`, key `.notificationsReminderLeadMinutes`, fallback `SettingsViewModel.Defaults.reminderLeadMinutes` — `SettingsViewModel.swift:40`); query `database.calendarEvents.events(startingIn: (now − lingerAfterStart)...(now + lead·60 + rangeSlack))` (`CalendarEventRepository.swift:147-153` — the same reach-back rationale as `scheduler.rs:222-225`); run `NotchUpcomingPlanner.dueEvents`; apply: each `fire` → `activeAlert = ActiveAlert(…)` + insert into `fired`; each `dismiss` → insert into `dismissed`, and clear `activeAlert` if it matches.
- **Concurrency:** everything `@MainActor`; the loop is one `Task` stored on the class (the `ReminderRefreshScheduler` pattern, `Ari/App/Notifications/ReminderRefreshScheduler.swift:21-38`), cancelled in `deinit`. `fired: Set<Fire>` / `dismissed: Set<CalendarEventID>` are plain stored properties — no locks, no `@unchecked Sendable`. Work per tick is one indexed GRDB read + pure math; nothing near the audio hot path.
- **Dismissal persistence semantics (exact Rust parity):** `fired`/`dismissed` are **in-memory only, per scheduler lifetime, keyed by event id** (per occurrence row) — never persisted (`scheduler.rs:192-193`). The *user-tap* dismiss stays where it already is: `NotchOverlayModel.dismissUpcoming()` is local-only, hides that eventId, informs nobody — identical to the sidecar. The scheduler's auto-dismiss (linger expiry / gained meeting / cancelled) is what clears `current` for everyone. Consequence to note in code: because the coordinator tears the scheduler down with the toggle, flipping the notch off→on re-fires a prompt still inside its 45 s tolerance window — accepted (Rust ran always; the difference is a ≤45 s edge).
- **Ownership:** `NotchOverlayCoordinator` (plan §2) constructs the scheduler alongside `NotchPanelController`/`NotchOverlayModel` when `showNotchOverlay` turns on, passes it as the model's `upcoming:`, and drops it on disable — the brain only ticks while its one consumer exists. `AppEnvironment` needs no new stored property; the coordinator already receives `session` and gains a `database` parameter in its `bootstrap()` wiring (plan §2 snippet).
- **Persistence:** none. No new tables, no repository methods, single-DB-owner untouched — reads go through the existing `CalendarEventRepository` + `SettingsRepository` only.

### A.4 Interaction with the notifications reminder path (coexistence, as in Rust)

Rust fired **both** surfaces per lead from one loop (`scheduler.rs:263-288`). The Swift architecture is different — OS reminders are *pre-scheduled* with UNUserNotificationCenter by `MeetingNotifications.reconcileReminders()` / `MeetingReminderPlanner` (`MeetingNotifications.swift:94-127`) — so the port must **not** post a second notification from the tick:

- **The scheduler drives the notch prompt only.** The system notification keeps its existing pre-scheduled path. This preserves the Rust *product* behavior (both surfaces) without duplicating notification logic.
- **Timing stays consistent by construction:** both read the same `.notificationsReminderLeadMinutes` key, so the OS banner and the island alert land at the same T-lead moment (±45 s tick tolerance on the island side). **Documented divergence from Rust:** Rust defaulted to two leads `[15, 5]` (`scheduler.rs:302-315`); the shipped Swift settings surface has a single lead (default 5, picker `[1, 5, 10, 15]`, `SettingsViewModel.swift:40`, `:94`). The scheduler follows the Swift single-lead model — one prompt per event — keeping the two native surfaces in lockstep rather than resurrecting a Rust-only default.
- **Gating parity:** in Rust the notch push was *not* gated by the notification toggles (only the system notification was, inside the manager, `scheduler.rs:317-327`). Same here: the island alert is gated by `showNotchOverlay` (its own surface toggle), not by `notificationsMeetingReminders`. Turning OS reminders off silences banners but the enabled island still prompts — matching the frozen app.
- **No double-prompt weirdness:** a banner and the island showing the same meeting simultaneously is the frozen app's own shipped behavior; both route through the same start path (`startRecordingFromReminder`), which no-ops safely if the other already started it (`AppEnvironment.swift:340-345`).

### A.5 What is intentionally *not* ported

- The NDJSON push (`push_inbound`, `NotchInbound::UpcomingMeeting`/`DismissUpcoming`) — replaced by Observation on `current`.
- The `UPCOMING_TITLES` cache (`bridge.rs:662-697`) — obsoleted by `pendingCalendarLink` (A.1).
- The at-fire `already_recording` snapshot — replaced by live derivation (A.3).
- The per-tick system-notification call — the pre-scheduled `MeetingNotifications` path already owns it (A.4).

### A.6 Acceptance tests (written first)

New suite 8, `AriKit/Tests/AriViewModelsTests/NotchUpcomingPlannerTests.swift` (Swift Testing) — the 12 Rust cases ported one-for-one (`scheduler.rs:333-536`), against `dueEvents`:

1. `firesExactlyAtTMinus15` · 2. `firesExactlyAtTMinus5` · 3. `noFireEarlierThanTolerance` · 4. `noDuplicateFireWhenAlreadyInFiredSet` · 5. `noFireForEventThatAlreadyHasMeeting` (`meetingId != nil`) · 6. `noDismissWhileLingeringAfterStart` · 7. `dismissOnceLingerWindowExpires` · 8. `dismissWhenEventGainsMeeting` · 9. `dismissWhenEventVanishesFromRange` · 10. `noRedundantDismissWhenAlreadyDismissed` · 11. `vanishedEventDismissedOnceAcrossMultipleFiredLeads` · 12. `fullLifecycleT15ThenT5ThenDismiss` (multi-lead `[15, 5]`, exact Rust sequence).

Plus new, Swift-specific:

13. `allDayEventsNeverFire` — the documented divergence (A.2), as a test.
14. `NotchUpcomingSchedulerTests` — against the in-memory-DB harness + injected clock: `evaluateNow()` at T-lead publishes `current` with the event's real title/start/attendee count; linger expiry clears it; a gained `meetingId` clears it; `alreadyRecording` is false when `session.phase == .idle` and true under an in-flight phase; the lead is read from the settings key with the documented default on absence.
15. Extend suite 3/4 (existing plan §7): with a stub provider, `dismissUpcoming()` hides the alert while the provider still holds it, and a **different** subsequent event shows again — now exercised against the live-conformer shape.

**Dual-run bar (principle 2):** the invariant set is the 12 ported cases; they are green today against the Rust incumbent (`cargo test`, `scheduler.rs` tests) and the Swift planner must pass the same set, plus 13–15. Human checklist addition (§7 list): with a test calendar event ~6 min out and the notch enabled, the island alert appears at ~T-5 alongside the OS banner, lingers 30 min past start if ignored, Record starts a linked+named recording, and dismiss hides it without killing a later different event's alert.

### A.7 Supersessions in the existing plan text and the migration plan

- Header decisions, §1 "panel not the brain", §4 defer-decision, §9 first bullet, §10 (step 4b added), and §11 WIP note — all updated inline above.
- **`plans/swift-migration-plan.md`:** line 162's parenthetical ("its scheduler/state logic … ports with the engine in Phase 3") and the line 268 row (`Split: 2 / 3.2`) are updated: scheduler pulled forward into the Phase-2 notch absorption (decision 2026-07-22); Phase 3.2 loses this item.

### A.8 Risks added

- **R5 — settings-key drift:** if the reminder-lead key or default changes, island and banner timing silently diverge; mitigated by both reading the one `SettingsViewModel.Defaults.reminderLeadMinutes` constant + key (test 14 pins it).
- **R6 — recurring events:** dismissal/fire state is keyed by the occurrence row's `CalendarEventID`; a recurring series produces distinct occurrence rows, so state never bleeds across occurrences — but verify during the human pass with a daily test event.
