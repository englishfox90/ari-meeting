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
        speechAssets: SpeechAssetProviding = StubSpeechAssetProviding()
    ) -> SettingsViewModel {
        SettingsViewModel(
            database: database,
            secrets: secrets,
            appearance: AppearanceStore(),
            speechAssets: speechAssets
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
            viewModel.recordingStartNotificationAvailability,
            viewModel.deviceSelectionAvailability,
            viewModel.audioBackendAvailability,
            viewModel.rebuildIndexAvailability,
            viewModel.nomicDownloadAvailability
        ]

        for group in groups {
            guard case let .disabled(reason) = group else {
                Issue.record("expected .disabled, got \(group)")
                continue
            }
            #expect(!reason.isEmpty)
        }
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
