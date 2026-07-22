//
//  SettingsViewModelTests.swift — docs/plans/settings-ui.md §8 test 3.
//
import Foundation
import Testing
@testable import AriKit
@testable import AriViewModels

@Suite("SettingsViewModel")
@MainActor
struct SettingsViewModelTests {
    private func makeViewModel(
        database: AppDatabase,
        secrets: StubSecretsStoring = StubSecretsStoring(),
        speechAssets: SpeechAssetProviding = StubSpeechAssetProviding(),
        audioDevices: AudioDeviceProviding = StubAudioDeviceProviding()
    ) -> SettingsViewModel {
        SettingsViewModel(
            database: database,
            secrets: secrets,
            appearance: AppearanceStore(),
            speechAssets: speechAssets,
            audioDevices: audioDevices
        )
    }

    @Test("load() applies honest defaults when nothing is stored")
    func loadAppliesDefaults() async throws {
        let database = try AppDatabase.makeInMemory()
        let viewModel = makeViewModel(database: database)
        await viewModel.load()

        #expect(viewModel.showNotch == SettingsViewModel.Defaults.showNotch)
        #expect(viewModel.saveAudioRecordings == SettingsViewModel.Defaults.saveAudioRecordings)
        #expect(viewModel.transcriptionLanguage == SettingsViewModel.Defaults.transcriptionLanguage)
        #expect(viewModel.summaryProvider == SettingsViewModel.Defaults.summaryProvider)
        #expect(viewModel.recallEmbedder == SettingsViewModel.Defaults.recallEmbedder)
    }

    @Test("load() populates a real stored value, never the default, once one is set")
    func loadPopulatesStoredValue() async throws {
        let database = try AppDatabase.makeInMemory()
        try await database.settings.setBool(false, forKey: .recordingsSaveAudio)
        try await database.settings.setString("ollama", forKey: .summaryProvider)

        let viewModel = makeViewModel(database: database)
        await viewModel.load()

        #expect(viewModel.saveAudioRecordings == false)
        #expect(viewModel.summaryProvider == "ollama")
    }

    @Test("toggling a live preference persists — read back via a fresh repository read")
    func togglePersists() async throws {
        let database = try AppDatabase.makeInMemory()
        let viewModel = makeViewModel(database: database)
        await viewModel.load()

        try await viewModel.setSaveAudioRecordings(false)
        #expect(viewModel.saveAudioRecordings == false)

        let stored = try await database.settings.bool(forKey: .recordingsSaveAudio)
        #expect(stored == false)
    }

    @Test("setAPIKey/hasAPIKey/deleteAPIKey round-trip via StubSecretsStoring, key text never exposed")
    func apiKeyPresenceRoundTrips() async throws {
        let database = try AppDatabase.makeInMemory()
        let secrets = StubSecretsStoring()
        let viewModel = makeViewModel(database: database, secrets: secrets)

        var hasKey = await viewModel.hasAPIKey(for: "ollama")
        #expect(hasKey == false)

        try await viewModel.setAPIKey("sk-test-value", for: "ollama")
        hasKey = await viewModel.hasAPIKey(for: "ollama")
        #expect(hasKey == true)

        try await viewModel.deleteAPIKey(for: "ollama")
        hasKey = await viewModel.hasAPIKey(for: "ollama")
        #expect(hasKey == false)
    }

    @Test("every honest-disabled group reports .disabled(reason:) with a non-empty reason")
    func disabledGroupsCarryNonEmptyReasons() throws {
        let database = try AppDatabase.makeInMemory()
        let viewModel = makeViewModel(database: database)

        let groups: [Availability] = [
            viewModel.notchAvailability,
            viewModel.menuBarAvailability,
            viewModel.recordingAlertsAvailability,
            viewModel.recordingStartNotificationAvailability
        ]

        for group in groups {
            guard case let .disabled(reason) = group else {
                Issue.record("expected .disabled, got \(group)")
                continue
            }
            #expect(!reason.isEmpty)
        }
    }

    // MARK: - Audio devices (docs/plans/settings-audio-devices.md §5 Lane 1)

    @Test("deviceSelectionAvailability is live — real CoreAudio HAL enumeration is wired")
    func deviceSelectionIsLive() throws {
        let database = try AppDatabase.makeInMemory()
        let viewModel = makeViewModel(database: database)

        #expect(viewModel.deviceSelectionAvailability == .live)
    }

    @Test("refreshAudioDevices() + load() populate real devices from the injected provider")
    func refreshAudioDevicesPopulatesFromProvider() async throws {
        let database = try AppDatabase.makeInMemory()
        let devices = [
            AudioInputDevice(uid: "built-in-mic", name: "MacBook Pro Microphone"),
            AudioInputDevice(uid: "usb-mic-1", name: "USB Condenser Mic")
        ]
        let viewModel = makeViewModel(
            database: database,
            audioDevices: StubAudioDeviceProviding(devices: devices, outputName: "MacBook Pro Speakers")
        )

        // Before any load/refresh, the state is honestly empty — never fabricated.
        #expect(viewModel.audioInputDevices.isEmpty)
        #expect(viewModel.defaultOutputDeviceName == nil)

        await viewModel.load()
        #expect(viewModel.audioInputDevices == devices)
        #expect(viewModel.defaultOutputDeviceName == "MacBook Pro Speakers")

        // refreshAudioDevices() alone (not just load()) re-reads the same real state.
        let freshViewModel = makeViewModel(
            database: database,
            audioDevices: StubAudioDeviceProviding(devices: devices, outputName: "MacBook Pro Speakers")
        )
        await freshViewModel.refreshAudioDevices()
        #expect(freshViewModel.audioInputDevices == devices)
        #expect(freshViewModel.defaultOutputDeviceName == "MacBook Pro Speakers")
    }

    @Test("an empty/failed provider is honest — no fabricated device entry")
    func emptyProviderIsHonest() async throws {
        let database = try AppDatabase.makeInMemory()
        let viewModel = makeViewModel(
            database: database,
            audioDevices: StubAudioDeviceProviding(devices: [], outputName: nil)
        )

        await viewModel.load()
        #expect(viewModel.audioInputDevices.isEmpty)
        #expect(viewModel.defaultOutputDeviceName == nil)
    }

    @Test("setMicDevice persists the UID; setMicDevice(nil) removes it")
    func setMicDeviceRoundTrips() async throws {
        let database = try AppDatabase.makeInMemory()
        let viewModel = makeViewModel(database: database)
        await viewModel.load()

        try await viewModel.setMicDevice("usb-mic-1")
        #expect(viewModel.micDevice == "usb-mic-1")
        var stored = try await database.settings.string(forKey: .recordingsMicDevice)
        #expect(stored == "usb-mic-1")

        try await viewModel.setMicDevice(nil)
        #expect(viewModel.micDevice == nil)
        stored = try await database.settings.string(forKey: .recordingsMicDevice)
        #expect(stored == nil)
    }

    @Test("a stored-but-absent device UID is surfaced honestly, never silently cleared")
    func storedButAbsentDeviceIsHonest() async throws {
        let database = try AppDatabase.makeInMemory()
        try await database.settings.setString("unplugged-mic-uid", forKey: .recordingsMicDevice)

        let viewModel = makeViewModel(
            database: database,
            audioDevices: StubAudioDeviceProviding(
                devices: [AudioInputDevice(uid: "built-in-mic", name: "MacBook Pro Microphone")]
            )
        )
        await viewModel.load()

        #expect(viewModel.micDevice == "unplugged-mic-uid")
        #expect(viewModel.micDeviceIsPresent == false)
    }

    @Test("AudioInputDevice is Identifiable by uid, Equatable, and Sendable")
    func audioInputDeviceConformances() async {
        let device = AudioInputDevice(uid: "usb-mic-1", name: "USB Condenser Mic")
        #expect(device.id == "usb-mic-1")
        #expect(device == AudioInputDevice(uid: "usb-mic-1", name: "USB Condenser Mic"))

        // Crosses an actor boundary — proves `Sendable` compiles, not just declares.
        let echoed = await Task.detached { device }.value
        #expect(echoed == device)
    }

    @Test("SettingKey no longer has a recordingsSystemDevice case (decision B)")
    func recordingsSystemDeviceKeyIsRetired() {
        let keys = SettingKey.allCases.map(\.rawValue)
        #expect(!keys.contains("recordingsSystemDevice"))
    }

    @Test("a persisted mic-device UID is what the recording-start seam reads (end-to-end plumbing)")
    func persistedMicDeviceUIDFeedsTheCaptureSeam() async throws {
        let database = try AppDatabase.makeInMemory()
        try await database.settings.setString("usb-mic-1", forKey: .recordingsMicDevice)

        // Mirrors `AppEnvironment`'s `preferredMicDeviceUID` closure verbatim
        // (`Ari/App/AppEnvironment.swift`: `{ await db.settings.string(forKey: .recordingsMicDevice) }`)
        // — proving the DB-side half of the seam without requiring the app target under `swift test`.
        let preferredMicDeviceUID: @Sendable () async -> String? = {
            await (try? database.settings.string(forKey: .recordingsMicDevice)) ?? nil
        }

        let read = await preferredMicDeviceUID()
        #expect(read == "usb-mic-1")
    }

    @Test("rebuildIndexAvailability is live — the Indexer is wired for real")
    func rebuildIndexIsLive() throws {
        let database = try AppDatabase.makeInMemory()
        let viewModel = makeViewModel(database: database)

        #expect(viewModel.rebuildIndexAvailability == .live)
    }

    @Test("rebuildIndex() completes and refreshes indexSummary on an empty library")
    func rebuildIndexCompletesOnEmptyLibrary() async throws {
        let database = try AppDatabase.makeInMemory()
        let viewModel = makeViewModel(database: database)
        await viewModel.load()

        #expect(viewModel.isRebuildingIndex == false)
        await viewModel.rebuildIndex()

        #expect(viewModel.isRebuildingIndex == false)
        #expect(viewModel.indexSummary?.indexedMeetings == 0)
    }

    @Test("transcription: engine available reports honest not-installed state")
    func transcriptionEngineAvailable() async throws {
        let database = try AppDatabase.makeInMemory()
        let viewModel = makeViewModel(
            database: database,
            speechAssets: StubSpeechAssetProviding(engineAvailable: true, installed: false)
        )
        await viewModel.load()

        #expect(viewModel.transcriptionEngineAvailable)
        #expect(viewModel.transcriptionModelInstalled == false)
        #expect(viewModel.transcriptionModelInstall == .idle)
    }

    @Test("transcription: engine unavailable yields nil install state (No-Fake-State)")
    func transcriptionEngineUnavailable() async throws {
        let database = try AppDatabase.makeInMemory()
        let viewModel = makeViewModel(
            database: database,
            speechAssets: StubSpeechAssetProviding(engineAvailable: false)
        )
        await viewModel.load()

        #expect(viewModel.transcriptionEngineAvailable == false)
        #expect(viewModel.transcriptionModelInstalled == nil)
    }

    @Test("transcription: installTranscriptionModel reaches installed + idle on success")
    func transcriptionInstallSucceeds() async throws {
        let database = try AppDatabase.makeInMemory()
        let viewModel = makeViewModel(
            database: database,
            speechAssets: StubSpeechAssetProviding(engineAvailable: true, installed: false)
        )
        await viewModel.load()
        #expect(viewModel.transcriptionModelInstalled == false)

        await viewModel.installTranscriptionModel()
        #expect(viewModel.transcriptionModelInstalled == true)
        #expect(viewModel.transcriptionModelInstall == .idle)
    }

    @Test("indexSummary reads the real RecallIndexRepository summary")
    func indexSummaryIsReal() async throws {
        let database = try AppDatabase.makeInMemory()
        let viewModel = makeViewModel(database: database)
        await viewModel.load()

        // Honestly empty store today.
        #expect(viewModel.indexSummary?.indexedMeetings == 0)
        #expect(viewModel.indexSummary?.chunkCount == 0)
    }
}
