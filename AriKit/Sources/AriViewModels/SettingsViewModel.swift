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
        public static let showNotch = false
        public static let showInMenuBar = false
        public static let recordingAlerts = true
        public static let saveAudioRecordings = true
        public static let recordingStartNotification = false
        public static let audioBackend = "coreAudio"
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
        /// ← the settings-ui.md §10 decided default (Apple excluded from this screen).
        public static let recallEmbedder = "ollama"
    }

    // MARK: - General

    public private(set) var showNotch: Bool = Defaults.showNotch
    public private(set) var showInMenuBar: Bool = Defaults.showInMenuBar
    public private(set) var recordingAlerts: Bool = Defaults.recordingAlerts

    public let notchAvailability: Availability = .disabled(
        reason: "The meeting notch runs in the frozen Rust app; the Swift shell doesn't drive it yet."
    )
    public let menuBarAvailability: Availability = .disabled(
        reason: "There is no menu-bar item in the Swift app yet."
    )
    public let recordingAlertsAvailability: Availability = .disabled(
        reason: "Notifications haven't been ported to the Swift app yet."
    )

    // MARK: - Recordings

    public private(set) var saveAudioRecordings: Bool = Defaults.saveAudioRecordings
    public private(set) var recordingStartNotification: Bool = Defaults.recordingStartNotification
    public private(set) var micDevice: String?
    public private(set) var systemDevice: String?
    public private(set) var audioBackend: String = Defaults.audioBackend

    public let recordingStartNotificationAvailability: Availability = .disabled(
        reason: "Recording-start notifications haven't been ported to the Swift app yet."
    )
    public let deviceSelectionAvailability: Availability = .disabled(
        reason: "Audio device enumeration hasn't been ported to the Swift capture stack yet."
    )
    public let audioBackendAvailability: Availability = .disabled(
        reason: "Audio backend selection hasn't been ported to the Swift capture stack yet."
    )

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

    public let modelDownloadsAvailability: Availability = .disabled(
        reason: "Per-provider model downloads still run in the frozen Rust engine; not ported yet."
    )
    public let rebuildIndexAvailability: Availability = .disabled(
        reason: "There is no Swift reindex command yet."
    )
    public let nomicDownloadAvailability: Availability = .disabled(
        reason: "The Nomic GGUF embedder download manager hasn't been ported to Swift yet."
    )

    // MARK: - Appearance (plan §2.4 — not backed by `SettingsRepository`)

    public let appearance: AppearanceStore

    // MARK: - Dependencies

    private let database: AppDatabase
    private let secrets: SecretsStoring
    private let speechAssets: SpeechAssetProviding

    public init(
        database: AppDatabase,
        secrets: SecretsStoring,
        appearance: AppearanceStore,
        speechAssets: SpeechAssetProviding = SpeechAssetManager()
    ) {
        self.database = database
        self.secrets = secrets
        self.appearance = appearance
        self.speechAssets = speechAssets
    }

    /// One-shot load: every property gets its honest stored value, or its documented default
    /// when the store has never seen that key. A single failed read never blanks unrelated
    /// properties — each is read independently and tolerant of its own failure.
    public func load() async {
        let settings = database.settings

        showNotch = await (try? settings.bool(forKey: .generalShowNotch)) ?? Defaults.showNotch
        showInMenuBar = await (try? settings.bool(forKey: .generalShowInMenuBar))
            ?? Defaults.showInMenuBar
        recordingAlerts = await (try? settings.bool(forKey: .generalRecordingAlerts))
            ?? Defaults.recordingAlerts

        saveAudioRecordings = await (try? settings.bool(forKey: .recordingsSaveAudio))
            ?? Defaults.saveAudioRecordings
        recordingStartNotification = await (try? settings.bool(forKey: .recordingsStartNotification))
            ?? Defaults.recordingStartNotification
        micDevice = await (try? settings.string(forKey: .recordingsMicDevice)) ?? nil
        systemDevice = await (try? settings.string(forKey: .recordingsSystemDevice)) ?? nil
        audioBackend = await (try? settings.string(forKey: .recordingsAudioBackend))
            ?? Defaults.audioBackend

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
    }

    // MARK: - General setters

    public func setShowNotch(_ value: Bool) async throws {
        try await database.settings.setBool(value, forKey: .generalShowNotch)
        showNotch = value
    }

    public func setShowInMenuBar(_ value: Bool) async throws {
        try await database.settings.setBool(value, forKey: .generalShowInMenuBar)
        showInMenuBar = value
    }

    public func setRecordingAlerts(_ value: Bool) async throws {
        try await database.settings.setBool(value, forKey: .generalRecordingAlerts)
        recordingAlerts = value
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

    public func setSystemDevice(_ value: String?) async throws {
        if let value {
            try await database.settings.setString(value, forKey: .recordingsSystemDevice)
        } else {
            try await database.settings.remove(forKey: .recordingsSystemDevice)
        }
        systemDevice = value
    }

    public func setAudioBackend(_ value: String) async throws {
        try await database.settings.setString(value, forKey: .recordingsAudioBackend)
        audioBackend = value
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
