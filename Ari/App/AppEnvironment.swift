//
//  AppEnvironment.swift — the @Observable root (plan §2.1). Owns the single `AppDatabase`
//  (single-DB-owner, principle 3) and hands its repositories down the view tree. View models
//  read from here; no view constructs its own database connection.
//
//  S0 scope: resolve the app-data dir, open (creating + migrating) the Store DB, and surface an
//  HONEST launch status (No-Fake-State — a failed open shows the real error, never a fake ready).
//  S8-lite (here): on the FIRST launch (new DB empty), import the existing library read-only from
//  the frozen Tauri app's data dir (`com.meetily.ai`). The repository-backed screens (S6) then
//  render real meetings. The legacy dir is only ever read — never written, never deleted.
//
import AppKit
import AriCapture
import AriKit
import AriKitDiarizationFluidAudio
import AriKitEngineMLX
import AriViewModels
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppEnvironment {
    enum Status: Equatable {
        case launching
        case importing
        case ready
        case failed(String)
    }

    private(set) var status: Status = .launching

    /// The single owner of the SQLite file. `nil` until `bootstrap()` succeeds.
    private(set) var database: AppDatabase?

    /// S0 sanity readout: the real row count from the opened DB (honest; empty on a fresh dir).
    private(set) var meetingCount: Int?

    /// The reconciliation report from the first-run legacy import, if one ran this launch. Honest
    /// counts (No-Fake-State) — `nil` when nothing was imported (already-populated DB, or no
    /// legacy library present).
    private(set) var importReport: ImportReport?

    /// The single app-wide recording session (docs/plans/ari-recording-page.md §4.1). Constructed
    /// once `database` exists (`status == .ready`) so it survives navigation — the recording
    /// page only ever renders it, never owns capture state itself.
    private(set) var recordingSession: RecordingSession?

    /// The single app-wide audio-import session (docs/plans/audio-import.md) — import an existing
    /// recording as a meeting, with a user-chosen meeting date/time. Mount-independent like
    /// `recordingSession` so it survives the import sheet being dismissed. `nil` until `bootstrap()`.
    private(set) var importSession: MeetingImportSession?

    /// The one Keychain-backed secrets store (docs/plans/settings-ui.md §2.3) — backs
    /// `SecretsReading`/`RecallSecretsReading`/`SecretsStoring` all at once. Stateless, so it
    /// needs no `bootstrap()` gating; available from construction.
    let secrets: SecretsStoring = KeychainSecretStore()
    /// The single offline diarization orchestrator (docs/plans/arikit-diarization.md §5 D9b) —
    /// the FluidAudio provider is injected here, at the composition root, so core `AriKit` and
    /// `AriViewModels` never import FluidAudio directly. Constructed once `database` exists.
    private(set) var diarizationService: DiarizationService?

    /// The count-hint source for the "Identify speakers" sheet (plan §2.6) — the Phase-3.5
    /// calendar/participant-derived conformer; live EventKit (S7) slots in later behind the
    /// same protocol without touching this wiring.
    private(set) var speakerCountHintProvider: (any SpeakerCountHintProviding)?

    /// The summary generation service (docs/plans/swift-meeting-generation-flow.md, Track 1 "App
    /// wiring") — `SummaryRunner`'s persistence delegate. `nil` until `bootstrap()` succeeds,
    /// exactly like `diarizationService`.
    private(set) var summaryService: SummaryService?
    /// The shared "generate a summary" core (same plan) — composes `summaryService` with the
    /// app's settings/secrets seams. `MeetingSummaryViewModel` (Track 1) and the later
    /// `MeetingProcessingCoordinator` (Track 2) both build from this ONE instance.
    private(set) var summaryRunner: SummaryRunner?
    /// The F9 series-ledger reducer (docs/plans/glittery-humming-truffle.md) — shared by
    /// `summaryRunner`'s auto-fold hook and `SeriesDetailViewModel`'s manual "Rebuild ledger"
    /// control, so both go through the ONE reducer built from this app's `db`/settings/secrets/
    /// `clientFactory`. `nil` until `bootstrap()` succeeds, exactly like `summaryRunner`.
    private(set) var seriesLedgerReducer: SeriesLedgerReducer?

    /// The post-recording pipeline (docs/plans/swift-meeting-generation-flow.md, Track 2) —
    /// speaker identification → template selection → summary, mount-independent like
    /// `recordingSession` so it survives navigation away from the recording page. `nil` until
    /// `bootstrap()` succeeds, exactly like `diarizationService`/`summaryRunner`.
    private(set) var processingCoordinator: MeetingProcessingCoordinator?

    /// The S7 EventKit source (the one EventKit toucher, `Ari/Calendar/EventKitCalendarSource.swift`)
    /// — injected into `CalendarSettingsViewModel` by the Settings screen. `nil` until `bootstrap()`
    /// succeeds, exactly like `database`/`recordingSession`.
    private(set) var calendarSource: EventKitCalendarSource?
    /// The 15-min background sync loop (docs/plans/arikit-calendar.md §3) — owned here so its
    /// `Task` lives (and is cancelled) with the app, not with any one view.
    private var calendarSyncScheduler: CalendarSyncScheduler?

    /// The local-notification coordinator (calendar reminders + summary-ready) — the Swift port of
    /// the frozen Rust notification subsystem. Injected into the Settings screen for the
    /// authorization surface + reconcile-on-change. `nil` until `bootstrap()` succeeds.
    private(set) var meetingNotifications: MeetingNotifications?
    /// The `UNUserNotificationCenterDelegate` routing tapped notifications back into the app. Held
    /// strongly (the notification center references its delegate weakly).
    private let notificationActionHandler = NotificationActionHandler()
    /// The 15-min reconcile loop keeping scheduled reminders in sync with the calendar — owned here
    /// like `calendarSyncScheduler` so its `Task` lives with the app.
    private var reminderScheduler: ReminderRefreshScheduler?

    /// A one-shot navigation intent raised from OUTSIDE the view tree (a tapped notification), which
    /// `RootSplitView` observes and applies to its `selectedSection`/`path`, then clears via
    /// `consumePendingNavigation()`. `nil` when there's nothing pending.
    private(set) var pendingNavigation: PendingNavigation?

    /// The in-process notch overlay's lifecycle owner (docs/plans/notch-panel-absorption.md §2) —
    /// observes the `showNotchOverlay` preference and inserts/removes the `NotchPanelController`
    /// live. `nil` until `bootstrap()` succeeds, exactly like `recordingSession`.
    private(set) var notchOverlay: NotchOverlayCoordinator?

    /// The main window's `OpenWindowAction`, captured from the root view's `onAppear` (plan §11
    /// R4) — the "Open Ari" fallback `activateApp()` uses when no window is currently open. `nil`
    /// until the root view has appeared at least once.
    private var openWindowAction: OpenWindowAction?

    enum PendingNavigation: Equatable {
        case section(SidebarSection)
        case meeting(MeetingID)
    }

    /// Bundle identifier decided 2026-07-20 (arikit-native-shell.md §9): the fresh Swift app.
    static let bundleIdentifier = "com.arivo.ari"

    /// The frozen Tauri app's bundle id — the read-only import source (arikit-native-shell.md §6.2).
    static let legacyBundleIdentifier = "com.meetily.ai"

    /// Opens the Store DB once, at launch. Idempotent-guarded so a re-entrant `.task` is a no-op.
    func bootstrap() async {
        guard database == nil else { return }
        do {
            let url = try Self.databaseURL()
            let db = try AppDatabase.makeShared(at: url)
            database = db

            // First-run import: gated on a persisted completion MARKER, not on row count. A
            // row-count guard (`count == 0`) can't tell "never imported" from "import was
            // interrupted" — an interrupted import would leave a partial library that a count
            // guard then freezes as if complete (a No-Fake-State violation at the data layer).
            // The importer is idempotent, so a marker-absent re-run safely finishes a partial
            // import; the marker is written only AFTER a clean run (no `sourceError`).
            if !Self.legacyImportCompleted(),
               let legacy = Self.legacyDatabaseURL(),
               FileManager.default.fileExists(atPath: legacy.path) {
                status = .importing
                let report = await LegacyDatabaseImporter.run(sourceURL: legacy, into: db)
                importReport = report
                if report.sourceError == nil {
                    Self.markLegacyImportCompleted()
                }
            }

            meetingCount = try await db.meetings.all().count

            // Seed the owner profile from the macOS account name if none exists yet (runs AFTER
            // the legacy import, so an imported owner is respected). This backs the Home greeting
            // and the People owner card with a real, editable record instead of a display-only
            // `NSFullUserName()` fallback. Idempotent + best-effort: a failure just leaves the
            // owner unset (the greeting then honestly shows no name), never blocks launch.
            _ = try? await db.persons.ensureOwner(defaultDisplayName: NSFullUserName())

            // The real recording vertical (R5 capture + R6 live SpeechTranscriber).
            let recordingsRoot = try Self.recordingsRootURL()
            recordingSession = RecordingSession(
                database: db,
                recordingsRoot: recordingsRoot,
                makeCaptureService: { folder in
                    LiveCaptureService(
                        meetingFolder: folder,
                        preferredMicDeviceUID: {
                            await (try? db.settings.string(forKey: .recordingsMicDevice)) ?? nil
                        }
                    )
                },
                transcription: SpeechLiveTranscriptionService()
            )

            // The in-process notch overlay (docs/plans/notch-panel-absorption.md §2, Amendment A)
            // — built now that `recordingSession` exists, since the model reads it directly via
            // Observation. `onRecordEvent` reuses the SAME prime-and-start path a meeting reminder
            // uses (`startRecordingFromReminder`), so the island's Record affordance and the
            // reminder notification action can never diverge. The coordinator constructs its own
            // `NotchUpcomingScheduler` (the ported `notch/scheduler.rs` brain) when the overlay
            // turns on, so the upcoming-meeting alert is live.
            if let session = recordingSession {
                notchOverlay = NotchOverlayCoordinator(
                    session: session,
                    database: db,
                    onOpenApp: { [weak self] in self?.activateApp() },
                    onRecordEvent: { [weak self] eventId in
                        Task { await self?.startRecordingFromReminder(eventId: eventId) }
                    }
                )
            }

            // Import an existing audio file as a meeting (docs/plans/audio-import.md). Shares the
            // recordings root with live capture, but uses the file-transcription provider directly
            // (`SpeechTranscriberProvider`'s whole-file `transcribe(fileURL:)`), not the live
            // windows-stream service. The post-import pipeline kickoff is wired in `RootSplitView`,
            // exactly like the recording `.saved` handler.
            importSession = MeetingImportSession(
                database: db,
                recordingsRoot: recordingsRoot,
                transcription: SpeechTranscriberProvider()
            )

            // Local `let`s (not just the stored properties below) so the Track 2 coordinator
            // wiring further down can capture them directly — they're Sendable value
            // types/actors, unlike `self`/`AppEnvironment`, which the coordinator's `@Sendable`
            // closures must never capture.
            let diarizationService = DiarizationService(
                database: db,
                provider: FluidAudioDiarizationProvider(),
                audioLoader: DiarizationAudioLoader()
            )
            self.diarizationService = diarizationService
            let hintProvider = StoredCalendarHintProvider(database: db)
            speakerCountHintProvider = hintProvider

            // docs/plans/swift-meeting-generation-flow.md, Track 1 "App wiring": the summary
            // generation core, shared by the saved-meeting manual actions (Track 1) and the later
            // post-recording pipeline (Track 2). `StoreBackedSettingsReading` reads the
            // `.summaryProvider`/`.summaryModel`/etc. keys this same `db` owns. `secrets` (above)
            // is statically typed `SecretsStoring` (the Settings screen's read/write seam) — not
            // `any SecretsReading` — so a fresh `KeychainSecretStore()` is constructed here
            // instead, same as `SettingsView.init` does for its own narrower seam: it's a
            // stateless value type (no Keychain session held), so constructing another instance
            // is equivalent to reusing the one above, without an unrelated-existential cast.
            let settingsReader = StoreBackedSettingsReading(database: db)
            let summarySecrets = KeychainSecretStore()
            // The on-device MLX provider (`.mlx`, the default summary backend) is injected here —
            // core AriKit's `ProviderFactory` has no MLX dependency, so every summary/persons call
            // site that might resolve `.mlx` must thread `AriKitEngineMLX.mlxClientProvider` through
            // `ProviderFactory.make`. Without it a `.mlx` config throws "MLX client not registered".
            let mlxClientProvider = AriKitEngineMLX.mlxClientProvider
            let clientFactory: @Sendable (ProviderConfig) throws -> any LLMClient = {
                try ProviderFactory.make(config: $0, mlxClientProvider: mlxClientProvider)
            }
            let summaryService = SummaryService(
                db: db,
                settings: settingsReader,
                secrets: summarySecrets,
                cancellation: TaskCancellationCoordinator(),
                clientFactory: clientFactory
            )
            self.summaryService = summaryService
            let ledgerReducer = SeriesLedgerReducer(
                db: db,
                settings: settingsReader,
                secrets: summarySecrets,
                clientFactory: clientFactory
            )
            seriesLedgerReducer = ledgerReducer
            let runner = SummaryRunner(
                database: db,
                settings: settingsReader,
                secrets: summarySecrets,
                summaryService: summaryService,
                customTemplateDirectory: nil,
                clientFactory: clientFactory,
                ledgerReducer: ledgerReducer
            )
            summaryRunner = runner

            // Local notifications (calendar reminders + summary-ready) — the Swift port of the
            // frozen Rust notification subsystem. Constructed BEFORE the coordinator so its
            // summary-ready hook captures `notifications` (a Sendable @MainActor value), never
            // `self`/`AppEnvironment`.
            let notifications = MeetingNotifications(
                scheduler: SystemNotificationScheduler(),
                database: db
            )
            meetingNotifications = notifications

            // docs/plans/swift-meeting-generation-flow.md, Track 2 "App wiring": the
            // post-recording pipeline. Every closure below captures only Sendable values (`db`,
            // `hintProvider`, `diarizationService`, `runner`, `notifications`) — never
            // `self`/`AppEnvironment` — so the coordinator's `@Sendable` operation closures
            // type-check under Swift 6 strict concurrency.
            let coordinator = MeetingProcessingCoordinator(
                resolveAudioURL: { mid in
                    guard let meeting = try? await db.meetings.find(mid) else { return nil }
                    guard case let .available(url) = AudioAvailabilityResolver.resolve(
                        audioReference: meeting.audioReference,
                        fileExists: { FileManager.default.fileExists(atPath: $0.path) }
                    ) else { return nil }
                    return url
                },
                resolveHint: { mid in
                    try? await hintProvider.hint(for: mid).map(\.hint)
                },
                runDiarization: { mid, url, hint, progress in
                    _ = try await diarizationService.run(
                        meetingId: mid, audioURL: url, hint: hint, progress: progress
                    )
                },
                isAutoSummaryEnabled: {
                    // `try?` over a `Bool?`-returning call flattens (SE-0230), so this is already
                    // `Bool?`; default an unset/failed read to ON (the product default).
                    await (try? db.settings.bool(forKey: .summaryAutomatic)) ?? true
                },
                generateSummary: { mid, count in
                    _ = try await runner.generate(meetingId: mid, templateId: nil, speakerCount: count)
                },
                speakerCount: { mid in
                    await (try? db.speakers.forMeeting(mid).count).flatMap { $0 > 0 ? $0 : nil }
                },
                cancelSummary: { mid in
                    _ = await runner.cancel(mid)
                },
                notifySummaryGenerated: { mid, elapsed in
                    await notifications.summaryGenerated(meetingId: mid, elapsed: elapsed)
                }
            )
            processingCoordinator = coordinator

            // S7: construct the EventKit source + sync engine now that `db` exists, inject the
            // source into Settings' calendar VM (via `calendarSource`), and start the background
            // sync loop (plan §5).
            let source = EventKitCalendarSource()
            calendarSource = source
            let syncEngine = CalendarSyncEngine(source: source, database: db)
            calendarSyncScheduler = CalendarSyncScheduler(source: source, engine: syncEngine, database: db)

            // Route tapped notifications back into the app, install the delegate, and start the
            // reminder reconcile loop. The `onOpenMeeting` closure runs on the @MainActor handler,
            // so it sets `pendingNavigation` directly; `onStartRecording` hops through a `Task`
            // because `startRecordingFromReminder` is async.
            notificationActionHandler.onStartRecording = { [weak self] eventId in
                Task { await self?.startRecordingFromReminder(eventId: eventId) }
            }
            notificationActionHandler.onOpenMeeting = { [weak self] meetingId in
                self?.pendingNavigation = .meeting(meetingId)
            }
            notificationActionHandler.install()
            reminderScheduler = ReminderRefreshScheduler(notifications: notifications)

            status = .ready
        } catch {
            status = .failed(String(describing: error))
        }
    }

    // MARK: - Notification-driven intents

    /// The meeting-reminder action's handler: prime a recording for `eventId` and — per the
    /// 2026-07-22 product decision — start capturing immediately, navigating the shell to the
    /// recording page. If the session/event can't be resolved or a recording is already active, it
    /// still surfaces the recording page (a safe no-op start) rather than doing nothing.
    ///
    /// Mirrors `CalendarPageView.startMeeting(from:)`: reset first (so a terminal `.saved`/`.failed`
    /// session lands on the idle recording screen), set the title only when blank, attach the
    /// calendar link, THEN drive the consent edges. `requestStart()` + `confirmConsentRequested()`
    /// is the "start immediately" path — the synchronous consent edge flips to `.starting` before
    /// returning, so capture begins without a manual consent tap.
    func startRecordingFromReminder(eventId: CalendarEventID) async {
        pendingNavigation = .section(.newMeeting)
        guard let database, let session = recordingSession else { return }

        // Only prime + auto-start from a clean or terminal phase. If a recording — OR a manual
        // consent prompt — is already in flight, just surface the recording page and let the user
        // drive it, rather than silently resolving an in-flight consent decision (`.consentPrompt`
        // reports `isActive == false`, so a bare `!isActive` guard would clobber it).
        switch session.phase {
        case .idle, .saved, .failed:
            break
        case .consentPrompt, .starting, .recording, .stopping:
            return
        }

        let event = try? await database.calendarEvents.find(eventId)
        session.reset()
        if session.pendingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            session.pendingTitle = event?.title ?? ""
        }
        if let event {
            session.pendingCalendarLink = RecordingSession.PendingCalendarLink(
                eventId: event.id, eventTitle: event.title
            )
        }
        session.requestStart()
        session.confirmConsentRequested()
    }

    /// The menu-bar item's generic "Start recording" (no calendar event): prime an untitled
    /// recording and start immediately, surfacing the recording page. Mirrors
    /// `startRecordingFromReminder` minus the event priming — a menu click is the explicit
    /// initiation (never a silent auto-record), and the sole capture edge (`requestStart()` +
    /// `confirmConsentRequested()`) is still what starts it. Event-named starts from the menu bar
    /// go through `startRecordingFromReminder(eventId:)` instead. (docs/plans/menu-bar-item.md)
    func startRecordingFromMenuBar() {
        pendingNavigation = .section(.newMeeting)
        guard let session = recordingSession else { return }
        switch session.phase {
        case .idle, .saved, .failed:
            break
        case .consentPrompt, .starting, .recording, .stopping:
            return
        }
        session.reset()
        session.requestStart()
        session.confirmConsentRequested()
    }

    /// Raise a navigation intent to a workbench section from outside the view tree (the menu-bar
    /// item's "Settings"/"Open Ari"). `RootSplitView` observes `pendingNavigation` and applies it,
    /// then clears it via `consumePendingNavigation()`.
    func navigate(to section: SidebarSection) {
        pendingNavigation = .section(section)
    }

    /// Clear a consumed navigation intent so it fires exactly once (`RootSplitView` calls this after
    /// applying it).
    func consumePendingNavigation() {
        pendingNavigation = nil
    }

    /// Captures the main window's `OpenWindowAction`, called once from `RootSplitView`'s
    /// `onAppear` (docs/plans/notch-panel-absorption.md §11 R4) — a plain `NSHostingView` (the
    /// notch panel) has no scene-backed `openWindow` of its own, so `activateApp()` borrows the
    /// one captured here.
    func registerOpenWindowAction(_ action: OpenWindowAction) {
        openWindowAction = action
    }

    /// Bring the app forward — hoisted from `MenuBarContentView`'s former private `activateApp()`
    /// (docs/plans/notch-panel-absorption.md §2, §11 R4) so the notch overlay's "Open Ari"
    /// affordance and the menu bar's "Open Ari" row share ONE implementation and can never
    /// diverge. Fronts an existing main-capable window if one exists; else opens a fresh one via
    /// the stored `OpenWindowAction` (menu-bar-only state, zero windows open). If neither is
    /// available (pathological — before the root view has ever appeared), falls back to
    /// `NSApp.activate` only (accepted, R4).
    func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else if let openWindowAction {
            openWindowAction(id: AriApp.mainWindowID)
        }
    }

    /// `~/Library/Application Support/com.arivo.ari/ari.sqlite`, creating the directory if needed.
    /// The app resolves the path; the Store never touches FileManager (arikit-store.md §2.2).
    private static func databaseURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support.appendingPathComponent(bundleIdentifier, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ari.sqlite", isDirectory: false)
    }

    /// `~/Library/Application Support/com.arivo.ari/recordings`, creating the directory if
    /// needed (plan §5: "the app resolves the path; the Store never touches FileManager"). Each
    /// recording gets its own `<meetingID>/` subfolder, created by `RecordingSession` per-recording.
    private static func recordingsRootURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Sentinel marking that a legacy import ran to completion. Its presence — not the meeting
    /// row count — is the guard, so an interrupted import re-runs (the importer is idempotent)
    /// instead of freezing a partial library as if it were whole.
    private static func legacyImportMarkerURL() -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else {
            return nil
        }
        return support
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent(".legacy-import-complete", isDirectory: false)
    }

    private static func legacyImportCompleted() -> Bool {
        guard let marker = legacyImportMarkerURL() else { return false }
        return FileManager.default.fileExists(atPath: marker.path)
    }

    private static func markLegacyImportCompleted() {
        guard let marker = legacyImportMarkerURL() else { return }
        try? Data().write(to: marker)
    }

    /// The frozen Tauri app's SQLite file: `…/com.meetily.ai/meeting_minutes.sqlite`. Returns
    /// `nil` if Application Support can't be resolved; never creates the directory (read-only
    /// source). Existence is checked by the caller before opening.
    private static func legacyDatabaseURL() -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else {
            return nil
        }
        return support
            .appendingPathComponent(legacyBundleIdentifier, isDirectory: true)
            .appendingPathComponent("meeting_minutes.sqlite", isDirectory: false)
    }
}
