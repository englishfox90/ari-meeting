//
//  SettingsViewModel.swift — the native Settings screen's ONE view model
//  (docs/plans/settings-ui.md §5). Delivered whole in the FOUNDATION slice so the 5 section
//  slices only compose views against this already-final surface (parallel-safe).
//
//  Every published pref carries an honest DEFAULT CONSTANT (`Defaults`), applied ONLY when
//  `SettingsRepository` returns `nil` for that key — never a fabricated stored value. Every
//  honest-disabled control GROUP exposes an `Availability` describing WHY, read by the view as
//  real state (No-Fake-State), not hardcoded view copy.
//
import AriKit
import Foundation
import Observation

/// Whether a control (or control group) is wired to something real yet.
public enum Availability: Sendable, Equatable {
    case live
    case disabled(reason: String)
}

/// Live state of an on-device speech-model install. Progress is the framework's OWN
/// `Progress.fractionCompleted` verbatim — never interpolated (No-Fake-State).
public enum TranscriptionModelInstall: Sendable, Equatable {
    case idle
    case installing(Double)
    case failed(String)
}

@MainActor
@Observable
public final class SettingsViewModel {
    /// Honest default constants — applied only when the store has no row for that key yet.
    public enum Defaults {
        public static let recordingAlerts = true
        /// Calendar meeting reminders (F5) default ON — the ported feature is enabled out of the
        /// box, though nothing actually fires until the OS grants notification authorization.
        public static let meetingReminders = true
        /// Minutes before a meeting's start the reminder fires. 5 is the common calendar default.
        public static let reminderLeadMinutes = 5
        /// Summary-ready notifications default ON, gated by the "long generation" threshold so short
        /// summaries (user still watching) stay silent.
        public static let summaryReadyNotification = true
        public static let saveAudioRecordings = true
        public static let recordingStartNotification = false
        /// The consent-before-record prompt defaults OFF (see `SettingKey.recordingsRequireConsent`):
        /// tapping Record starts capture directly, since Record is itself the explicit action.
        public static let recordingRequireConsent = false
        /// On-device SpeechTranscriber language. `"auto"` = follow the system language
        /// (`STTLocale.resolveRequestedLocale`). Provider/model selection is gone — Apple's
        /// SpeechTranscriber is the Swift app's sole transcription engine.
        public static let transcriptionLanguage = "auto"
        public static let summaryAutomatic = true
        public static let summaryLanguage = "en"
        /// ← `ProviderKind.mlx` — the on-device successor to Rust's `BuiltInAI`, matching the
        /// "completely offline processing" pillar (AboutView).
        public static let summaryProvider = "mlx"
        public static let summaryModel = ""
        public static let summaryOllamaEndpoint = "http://localhost:11434"
        /// Apple's on-device NLEmbedding — the zero-download default, and the only embedder now
        /// offered on this screen (Ollama was removed from the Summary settings entirely).
        public static let recallEmbedder = "apple"
    }

    // MARK: - General

    public private(set) var recordingAlerts: Bool = Defaults.recordingAlerts

    /// Whether the consent-before-record prompt is shown before capture starts. Defaults OFF; the
    /// live `RecordingSession` mirrors this via `onRecordingRequireConsentChanged` on every write.
    public private(set) var recordingRequireConsent: Bool = Defaults.recordingRequireConsent

    /// Menu-bar visibility is a device-local UI preference read at app-scene scope (it gates the
    /// `MenuBarExtra`), so — like theme (`appearance`) — it lives in `UserDefaults`, NOT the
    /// `setting` table. The Settings toggle binds through this store; `AriApp` reads the same key
    /// via `@AppStorage` (docs/plans/menu-bar-item.md).
    public let menuBar: MenuBarVisibilityStore

    /// The in-process notch overlay's visibility (docs/plans/notch-panel-absorption.md §6) — a
    /// device-local `UserDefaults` preference (not the `setting` table). This is the LIVE toggle
    /// for the native Swift overlay, gating `NotchOverlayCoordinator` the same way `menuBar` gates
    /// the `MenuBarExtra` scene.
    public let notchOverlay: NotchVisibilityStore

    /// LIVE — the in-process Swift notch overlay (docs/plans/notch-panel-absorption.md) is wired.
    /// Visibility is the `notchOverlay` store above; there is no honest-disabled reason to
    /// surface for it.
    public let notchOverlayAvailability: Availability = .live
    /// LIVE — the Swift `MenuBarExtra` is wired (docs/plans/menu-bar-item.md). Visibility is the
    /// `menuBar` store above; there is no honest-disabled reason to surface anymore.
    public let menuBarAvailability: Availability = .live
    /// Recording alerts are LIVE once a notification scheduler is injected: `MeetingNotifications`
    /// posts a "recording started" alert (gated by the `recordingAlerts` toggle) when the app-layer
    /// phase observer sees a session go `.recording`. `.disabled` only in previews/tests that wire
    /// no scheduler — same honest pattern as `notificationsAvailability`.
    public let recordingAlertsAvailability: Availability

    // MARK: - Notifications (calendar reminders + summary-ready — LIVE once a scheduler is injected)

    public private(set) var meetingReminders: Bool = Defaults.meetingReminders
    public private(set) var reminderLeadMinutes: Int = Defaults.reminderLeadMinutes
    public private(set) var summaryReadyNotification: Bool = Defaults.summaryReadyNotification

    /// The lead-time choices offered by the picker (minutes-before-start).
    public static let reminderLeadOptions: [Int] = [1, 5, 10, 15]

    /// The real OS authorization, `nil` until first read (or when no scheduler is wired). Drives the
    /// honest "notifications are turned off in System Settings" banner — never a fabricated state.
    public private(set) var notificationAuthorization: NotificationAuthorization?

    /// `.live` once a scheduler is injected (the app), `.disabled` otherwise (previews/tests that
    /// don't wire one) — same honest pattern the calendar settings use.
    public let notificationsAvailability: Availability

    // MARK: - Recordings

    public private(set) var saveAudioRecordings: Bool = Defaults.saveAudioRecordings
    public private(set) var recordingStartNotification: Bool = Defaults.recordingStartNotification
    /// The persisted microphone device UID (`kAudioDevicePropertyDeviceUID`), or `nil` = system
    /// default. May be a stable UID that isn't currently attached — see `micDeviceIsPresent`.
    public private(set) var micDevice: String?

    /// Real enumerated input devices (docs/plans/settings-audio-devices.md §2.4), refreshed by
    /// `refreshAudioDevices()`. Honestly empty until a refresh runs / on failure — never a
    /// fabricated device entry.
    public private(set) var audioInputDevices: [AudioInputDevice] = []
    /// The current default OUTPUT device's real display name (what `SystemAudioTap` always
    /// follows), or `nil` when honestly unresolved.
    public private(set) var defaultOutputDeviceName: String?

    public let recordingStartNotificationAvailability: Availability = .disabled(
        reason: "Recording-start notifications haven't been ported to the Swift app yet."
    )
    /// LIVE (docs/plans/settings-audio-devices.md) — real CoreAudio HAL enumeration binds into
    /// the Swift capture stack; system audio is an honest read-only row (single global tap).
    public let deviceSelectionAvailability: Availability = .live

    /// Whether the persisted `micDevice` UID currently corresponds to an attached device.
    /// `nil` (system default) is always "present". A stored-but-absent UID (unplugged, or a
    /// stale legacy device *name* from before this feature) reads `false` — surfaced honestly by
    /// the view, never silently cleared (No-Fake-State; also handles R4 for free).
    public var micDeviceIsPresent: Bool {
        micDevice == nil || audioInputDevices.contains { $0.uid == micDevice }
    }

    // MARK: - Transcription (on-device Apple SpeechTranscriber — LIVE, plan §6)

    /// Whether the on-device SpeechTranscriber engine can run on this Mac at all
    /// (`SpeechAssetManager.isEngineAvailable`). Drives the honest Available/Unavailable state.
    public private(set) var transcriptionEngineAvailable: Bool = false
    /// The transcription language — the `"auto"` sentinel (system language) today. There is no
    /// user-facing language picker; the recording path reads this key, so it stays as the seam a
    /// future language control would write.
    public private(set) var transcriptionLanguage: String = Defaults.transcriptionLanguage
    /// Whether the model assets for the current language are installed. `nil` while unknown/checking
    /// — honestly absent, never a fabricated `false`.
    public private(set) var transcriptionModelInstalled: Bool?
    /// Live install progress/failure, driven by real `SpeechAssetManager` progress.
    public private(set) var transcriptionModelInstall: TranscriptionModelInstall = .idle

    // MARK: - Summary

    public private(set) var summaryAutomatic: Bool = Defaults.summaryAutomatic
    public private(set) var summaryLanguage: String = Defaults.summaryLanguage
    public private(set) var summaryProvider: String = Defaults.summaryProvider
    public private(set) var summaryModel: String = Defaults.summaryModel
    public private(set) var summaryOllamaEndpoint: String = Defaults.summaryOllamaEndpoint
    public private(set) var recallEmbedder: String = Defaults.recallEmbedder
    /// Real counts from `RecallIndexRepository.indexSummary()`, or `nil` on a read failure —
    /// honestly absent, never a fabricated zero-state (No-Fake-State).
    public private(set) var indexSummary: RecallIndexSummary?

    public let rebuildIndexAvailability: Availability = .live
    /// Live while a full backfill is running, driving the button's "Rebuilding…" label + disabled
    /// state. Guarded re-entrant-safe by `rebuildIndex()` itself.
    public private(set) var isRebuildingIndex: Bool = false

    // MARK: - Appearance (plan §2.4 — not backed by `SettingsRepository`)

    public let appearance: AppearanceStore

    // MARK: - Dependencies

    private let database: AppDatabase
    private let secrets: SecretsStoring
    private let speechAssets: SpeechAssetProviding
    private let audioDevices: AudioDeviceProviding
    /// The notification authorization surface (the app injects `MeetingNotifications`), or `nil`
    /// when no notification stack is wired — in which case the Notifications group is honestly
    /// disabled. Kept as the narrow `NotificationAuthorizing` protocol so the VM never reaches for
    /// the whole coordinator.
    private let notifications: (any NotificationAuthorizing)?
    /// Called after a change that affects scheduled reminders (toggle or lead-time), so the app can
    /// reconcile the OS's pending reminders immediately rather than waiting for the periodic loop.
    private let onNotificationSettingsChanged: (@Sendable () async -> Void)?
    /// Called after the consent-before-record toggle changes, so the app can mirror the new value
    /// onto the live `RecordingSession.requireConsent` immediately (no restart needed).
    private let onRecordingRequireConsentChanged: (@Sendable (Bool) -> Void)?
    /// Single shared single-flight guard for `rebuildIndex()` — a fresh `ReindexCoordinator` per
    /// call would defeat its whole purpose (overlap protection across taps/launches).
    private let reindexCoordinator = ReindexCoordinator()

    public init(
        database: AppDatabase,
        secrets: SecretsStoring,
        appearance: AppearanceStore,
        menuBar: MenuBarVisibilityStore = MenuBarVisibilityStore(),
        notchOverlay: NotchVisibilityStore = NotchVisibilityStore(),
        speechAssets: SpeechAssetProviding = SpeechAssetManager(),
        audioDevices: AudioDeviceProviding = CoreAudioDeviceEnumerator(),
        notifications: (any NotificationAuthorizing)? = nil,
        onNotificationSettingsChanged: (@Sendable () async -> Void)? = nil,
        onRecordingRequireConsentChanged: (@Sendable (Bool) -> Void)? = nil
    ) {
        self.database = database
        self.secrets = secrets
        self.appearance = appearance
        self.menuBar = menuBar
        self.notchOverlay = notchOverlay
        self.speechAssets = speechAssets
        self.audioDevices = audioDevices
        self.notifications = notifications
        self.onNotificationSettingsChanged = onNotificationSettingsChanged
        self.onRecordingRequireConsentChanged = onRecordingRequireConsentChanged
        notificationsAvailability = notifications == nil
            ? .disabled(reason: "Notifications aren't available in this build yet.")
            : .live
        recordingAlertsAvailability = notifications == nil
            ? .disabled(reason: "Recording alerts aren't available in this build yet.")
            : .live
    }

    /// One-shot load: every property gets its honest stored value, or its documented default
    /// when the store has never seen that key. A single failed read never blanks unrelated
    /// properties — each is read independently and tolerant of its own failure.
    public func load() async {
        let settings = database.settings

        // `menuBar` visibility is UserDefaults-backed (like `appearance`), not read here.
        recordingAlerts = await (try? settings.bool(forKey: .generalRecordingAlerts))
            ?? Defaults.recordingAlerts

        meetingReminders = await (try? settings.bool(forKey: .notificationsMeetingReminders))
            ?? Defaults.meetingReminders
        summaryReadyNotification = await (try? settings.bool(forKey: .notificationsSummaryReady))
            ?? Defaults.summaryReadyNotification
        let storedLead = await (try? settings.string(forKey: .notificationsReminderLeadMinutes)) ?? nil
        reminderLeadMinutes = storedLead.flatMap(Int.init) ?? Defaults.reminderLeadMinutes
        notificationAuthorization = await notifications?.authorizationStatus()

        saveAudioRecordings = await (try? settings.bool(forKey: .recordingsSaveAudio))
            ?? Defaults.saveAudioRecordings
        recordingStartNotification = await (try? settings.bool(forKey: .recordingsStartNotification))
            ?? Defaults.recordingStartNotification
        recordingRequireConsent = await (try? settings.bool(forKey: .recordingsRequireConsent))
            ?? Defaults.recordingRequireConsent
        micDevice = await (try? settings.string(forKey: .recordingsMicDevice)) ?? nil

        transcriptionEngineAvailable = speechAssets.isEngineAvailable()
        transcriptionLanguage = await (try? settings.string(forKey: .transcriptionLanguage))
            ?? Defaults.transcriptionLanguage
        transcriptionModelInstalled = transcriptionEngineAvailable
            ? await speechAssets.areAssetsInstalled(forLocale: transcriptionLanguage)
            : nil

        summaryAutomatic = await (try? settings.bool(forKey: .summaryAutomatic))
            ?? Defaults.summaryAutomatic
        summaryLanguage = await (try? settings.string(forKey: .summaryLanguage))
            ?? Defaults.summaryLanguage
        summaryProvider = await (try? settings.string(forKey: .summaryProvider))
            ?? Defaults.summaryProvider
        summaryModel = await (try? settings.string(forKey: .summaryModel)) ?? Defaults.summaryModel
        summaryOllamaEndpoint = await (try? settings.string(forKey: .summaryOllamaEndpoint))
            ?? Defaults.summaryOllamaEndpoint
        recallEmbedder = await (try? settings.string(forKey: .recallEmbedder))
            ?? Defaults.recallEmbedder

        indexSummary = try? await database.recallIndex.indexSummary()

        await refreshAudioDevices()
    }

    /// Re-reads real enumerated input devices + the current default-output name. Called at the
    /// end of `load()` and from the "Refresh Devices" button.
    public func refreshAudioDevices() async {
        audioInputDevices = await audioDevices.inputDevices()
        defaultOutputDeviceName = await audioDevices.defaultOutputDeviceName()
    }

    // MARK: - General setters

    public func setRecordingAlerts(_ value: Bool) async throws {
        try await database.settings.setBool(value, forKey: .generalRecordingAlerts)
        recordingAlerts = value
    }

    /// Persist the consent-before-record toggle, then mirror it onto the live `RecordingSession`
    /// so the change takes effect without a restart (No-Fake-State: the toggle reflects real
    /// behavior immediately).
    public func setRecordingRequireConsent(_ value: Bool) async throws {
        try await database.settings.setBool(value, forKey: .recordingsRequireConsent)
        recordingRequireConsent = value
        onRecordingRequireConsentChanged?(value)
    }

    // MARK: - Notification setters

    /// Persist the reminders toggle, request OS authorization if we're turning it on and haven't
    /// asked yet, then reconcile the scheduled reminders.
    public func setMeetingReminders(_ value: Bool) async throws {
        try await database.settings.setBool(value, forKey: .notificationsMeetingReminders)
        meetingReminders = value
        await requestAuthorizationIfEnabling(value)
        await onNotificationSettingsChanged?()
    }

    /// Persist the lead time and reconcile (fire times shift for every future reminder).
    public func setReminderLeadMinutes(_ value: Int) async throws {
        try await database.settings.setString(String(value), forKey: .notificationsReminderLeadMinutes)
        reminderLeadMinutes = value
        await onNotificationSettingsChanged?()
    }

    /// Persist the summary-ready toggle. No reconcile needed (these are delivered immediately, never
    /// pre-scheduled), but enabling still prompts for authorization if undetermined.
    public func setSummaryReadyNotification(_ value: Bool) async throws {
        try await database.settings.setBool(value, forKey: .notificationsSummaryReady)
        summaryReadyNotification = value
        await requestAuthorizationIfEnabling(value)
    }

    /// Explicit "Allow Notifications" action from the honest `.notDetermined` banner: prompt the OS,
    /// refresh the surfaced authorization, and reconcile so any now-permitted reminders schedule.
    public func requestNotificationAuthorization() async {
        guard let notifications else { return }
        notificationAuthorization = await notifications.requestAuthorization()
        await onNotificationSettingsChanged?()
    }

    /// Prompt for notification authorization the first time the user turns a notification on. A
    /// no-op when turning off, when no scheduler is wired, or once a decision (grant/deny) is made —
    /// the honest denied state then surfaces via the Settings banner instead of re-prompting.
    private func requestAuthorizationIfEnabling(_ value: Bool) async {
        guard value, let notifications else { return }
        if notificationAuthorization == nil || notificationAuthorization == .notDetermined {
            notificationAuthorization = await notifications.requestAuthorization()
        }
    }

    // MARK: - Recordings setters

    public func setSaveAudioRecordings(_ value: Bool) async throws {
        try await database.settings.setBool(value, forKey: .recordingsSaveAudio)
        saveAudioRecordings = value
    }

    public func setRecordingStartNotification(_ value: Bool) async throws {
        try await database.settings.setBool(value, forKey: .recordingsStartNotification)
        recordingStartNotification = value
    }

    public func setMicDevice(_ value: String?) async throws {
        if let value {
            try await database.settings.setString(value, forKey: .recordingsMicDevice)
        } else {
            try await database.settings.remove(forKey: .recordingsMicDevice)
        }
        micDevice = value
    }

    // MARK: - Transcription (on-device Apple SpeechTranscriber)

    /// Download + install the on-device speech model for the current language, surfacing the
    /// framework's REAL progress. On failure, reports the honest reason and re-checks the actual
    /// installed state rather than assuming success or failure.
    public func installTranscriptionModel() async {
        guard transcriptionEngineAvailable else { return }
        // Re-entrancy guard: a second tap before the first render flips `isInstalling` would
        // otherwise enqueue a duplicate concurrent install.
        if case .installing = transcriptionModelInstall {
            return
        }
        let language = transcriptionLanguage
        transcriptionModelInstall = .installing(0)

        // Funnel the @Sendable progress callbacks through an ordered stream consumed on this actor,
        // so state updates never race the terminal result.
        let (stream, continuation) = AsyncStream<Double>.makeStream()
        let installTask = Task { [speechAssets] () -> Result<Void, Error> in
            defer { continuation.finish() }
            do {
                try await speechAssets.install(forLocale: language) { fraction in
                    continuation.yield(fraction)
                }
                return .success(())
            } catch {
                return .failure(error)
            }
        }

        for await fraction in stream {
            transcriptionModelInstall = .installing(fraction)
        }

        // Re-check the CURRENT selection (not the captured `language`): the language picker can
        // interleave during the `for await` suspension, so trusting a bare `true`/the old locale
        // would fabricate an "Installed" badge for whatever language is now selected.
        switch await installTask.value {
        case .success:
            transcriptionModelInstall = .idle
        case let .failure(error):
            transcriptionModelInstall = .failed(Self.describeInstallError(error))
        }
        transcriptionModelInstalled = await speechAssets.areAssetsInstalled(forLocale: transcriptionLanguage)
    }

    private static func describeInstallError(_ error: Error) -> String {
        guard let error = error as? TranscriptionError else {
            return error.localizedDescription
        }
        switch error {
        case let .providerUnavailable(message), let .engineFailed(message):
            return message
        case let .unsupportedLanguage(identifier):
            return "That language isn't supported on this device (\(identifier))."
        case let .assetsNotInstalled(locale):
            return "The speech model for \(locale) isn't installed."
        default:
            return "The speech model couldn't be installed."
        }
    }

    // MARK: - Summary setters

    public func setSummaryAutomatic(_ value: Bool) async throws {
        try await database.settings.setBool(value, forKey: .summaryAutomatic)
        summaryAutomatic = value
    }

    public func setSummaryLanguage(_ value: String) async throws {
        try await database.settings.setString(value, forKey: .summaryLanguage)
        summaryLanguage = value
    }

    public func setSummaryProvider(_ value: String) async throws {
        try await database.settings.setString(value, forKey: .summaryProvider)
        summaryProvider = value
    }

    public func setSummaryModel(_ value: String) async throws {
        try await database.settings.setString(value, forKey: .summaryModel)
        summaryModel = value
    }

    public func setSummaryOllamaEndpoint(_ value: String) async throws {
        try await database.settings.setString(value, forKey: .summaryOllamaEndpoint)
        summaryOllamaEndpoint = value
    }

    public func setRecallEmbedder(_ value: String) async throws {
        try await database.settings.setString(value, forKey: .recallEmbedder)
        recallEmbedder = value
    }

    /// Force a full recall-index rebuild via the already-ported `Indexer`. Re-entrancy-guarded
    /// here (a second tap while one is in flight is a no-op) AND single-flight-guarded inside the
    /// `Indexer` itself via the shared `ReindexCoordinator`. `force: true` because a change of
    /// embedder model tag (e.g. moving to `AppleContextualEmbedder`) means every meeting must be
    /// re-embedded, not just changed ones. Refreshes `indexSummary` from the real repository
    /// afterward — never a fabricated count.
    public func rebuildIndex() async {
        guard !isRebuildingIndex else { return }
        isRebuildingIndex = true
        defer { isRebuildingIndex = false }
        let indexer = Indexer(
            recallIndex: database.recallIndex,
            transcripts: database.transcripts,
            meetings: database.meetings,
            summaries: database.summaries,
            embedder: AppleContextualEmbedder(),
            coordinator: reindexCoordinator
        )
        _ = try? await indexer.reindexAll(force: true)
        indexSummary = try? await database.recallIndex.indexSummary()
    }

    // MARK: - API keys (presence only — never expose key text)

    /// Whether a key is currently stored for `providerKey`. Presence only — never returns or
    /// logs the key text.
    public func hasAPIKey(for providerKey: String) async -> Bool {
        await secrets.apiKey(for: providerKey) != nil
    }

    public func setAPIKey(_ key: String, for providerKey: String) async throws {
        try await secrets.setAPIKey(key, for: providerKey)
    }

    public func deleteAPIKey(for providerKey: String) async throws {
        try await secrets.deleteAPIKey(for: providerKey)
    }
}
