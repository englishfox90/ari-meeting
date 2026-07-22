//
//  SummaryRunnerTests.swift — docs/plans/swift-meeting-generation-flow.md, Track 1 §0.
//
//  Driven against `AppDatabase.makeInMemory()` + injected `StubSettingsReading`/
//  `StubSecretsReading` + a stub/spy `LLMClient` — headless, no network/Keychain/MLX (mirrors
//  `SummaryServiceTests`' own setup shape).
//
import Foundation
import Testing
@testable import AriKit
@testable import AriViewModels

@Suite("SummaryRunner")
struct SummaryRunnerTests {
    private let meetingId: MeetingID = "meeting-1"

    private func makeMeeting(title: String = "Weekly sync") -> Meeting {
        Meeting(
            id: meetingId,
            title: title,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    /// A spying `LLMClient` — counts every `generate` call so tests can assert whether the
    /// classifier (`TemplateSelector.suggestTemplate`) actually ran, independent of the separate
    /// client used for the summary generation itself.
    private struct SpyLLMClient: LLMClient {
        let kind: ProviderKind = .mlx
        let spy: CallSpy
        var cannedResponse: String = "standard_meeting"

        func generate(_: LLMRequest) async throws -> String {
            await spy.record()
            return cannedResponse
        }
    }

    private actor CallSpy {
        private(set) var callCount = 0
        func record() { callCount += 1 }
    }

    private func makeRunner(
        db: AppDatabase,
        settings: any SettingsReading,
        secrets: any SecretsReading = StubSecretsReading(),
        classifierClientFactory: @escaping @Sendable (ProviderConfig) throws -> any LLMClient = { _ in
            StubLLMClient()
        },
        generationClientFactory: @escaping @Sendable (ProviderConfig) throws -> any LLMClient = { _ in
            StubLLMClient()
        }
    ) -> SummaryRunner {
        SummaryRunner(
            database: db,
            settings: settings,
            secrets: secrets,
            summaryService: SummaryService(
                db: db,
                settings: settings,
                secrets: secrets,
                cancellation: TaskCancellationCoordinator(),
                clientFactory: generationClientFactory
            ),
            customTemplateDirectory: nil,
            clientFactory: classifierClientFactory
        )
    }

    // MARK: - transcriptText

    @Test("transcriptText: speaker-labeled when a speaker resolves")
    func transcriptTextLabeledWhenSpeakerResolves() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting()
        try await db.meetings.upsert(meeting)

        let person = Person(
            id: "person-1", displayName: "Ada Lovelace", isOwner: false,
            createdAt: meeting.createdAt, updatedAt: meeting.createdAt
        )
        try await db.persons.upsert(person)

        let speaker = Speaker(
            id: "speaker-1", personId: person.id, centroid: Data([0x01]),
            embeddingModel: "test", dim: 1, samples: 1, enrollmentState: .confirmed,
            totalSpeechSecs: 10, createdAt: meeting.createdAt, updatedAt: meeting.createdAt
        )
        try await db.speakers.upsert(speaker)

        let transcript = Transcript(
            id: "transcript-1", meetingId: meetingId, transcript: "Hello team.",
            timestamp: "00:00:01", audioStartTime: 1.0, speakerId: speaker.id
        )
        try await db.transcripts.upsert(transcript)

        let runner = makeRunner(db: db, settings: StubSettingsReading())

        let text = try await runner.transcriptText(for: meetingId)
        #expect(text == "Ada Lovelace: Hello team.")
    }

    @Test("transcriptText: plain concatenation when no speaker resolves")
    func transcriptTextPlainWhenNoSpeakerResolves() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(makeMeeting())

        let transcript = Transcript(
            id: "transcript-1", meetingId: meetingId, transcript: "Hello team.",
            timestamp: "00:00:01"
        )
        try await db.transcripts.upsert(transcript)

        let runner = makeRunner(db: db, settings: StubSettingsReading())

        let text = try await runner.transcriptText(for: meetingId)
        #expect(text == "Hello team.")
    }

    // MARK: - generate: honest failures

    @Test("generate throws notConfigured when the meeting has no transcript text")
    func generateThrowsNotConfiguredWhenTranscriptEmpty() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(makeMeeting())
        let settings = StubSettingsReading(
            summaryModelConfigValue: SummaryModelConfig(providerKey: "ollama", model: "llama3")
        )
        let runner = makeRunner(db: db, settings: settings)

        await #expect(throws: LLMError.self) {
            _ = try await runner.generate(meetingId: meetingId, templateId: "standard_meeting", speakerCount: nil)
        }
    }

    @Test("generate throws notConfigured when no summary model is configured")
    func generateThrowsNotConfiguredWhenNoModelConfigured() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(makeMeeting())
        try await db.transcripts.upsert(Transcript(
            id: "transcript-1", meetingId: meetingId, transcript: "Let's talk roadmap.",
            timestamp: "00:00:01"
        ))
        // No summaryModelConfigValue set — honestly unconfigured.
        let runner = makeRunner(db: db, settings: StubSettingsReading())

        await #expect(throws: LLMError.self) {
            _ = try await runner.generate(meetingId: meetingId, templateId: "standard_meeting", speakerCount: nil)
        }
    }

    // MARK: - suggestTemplateID

    @Test("suggestTemplateID returns the honest default when no summary model is configured")
    func suggestTemplateIDReturnsDefaultWhenUnconfigured() async throws {
        let db = try AppDatabase.makeInMemory()
        let runner = makeRunner(db: db, settings: StubSettingsReading())

        let id = await runner.suggestTemplateID(text: "Let's talk roadmap.", speakerCount: nil)
        #expect(id == TemplateSelector.defaultTemplateID)
        #expect(id == "standard_meeting")
    }

    // MARK: - generate: template resolution

    @Test("an explicit templateId skips the classifier; nil consults it")
    func explicitTemplateIdSkipsClassifierNilConsultsIt() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(makeMeeting())
        try await db.transcripts.upsert(Transcript(
            id: "transcript-1", meetingId: meetingId, transcript: "Let's talk roadmap.",
            timestamp: "00:00:01"
        ))
        let settings = StubSettingsReading(
            summaryModelConfigValue: SummaryModelConfig(providerKey: "ollama", model: "llama3")
        )
        let classifierSpy = CallSpy()

        let explicitRunner = makeRunner(
            db: db,
            settings: settings,
            classifierClientFactory: { _ in SpyLLMClient(spy: classifierSpy, cannedResponse: "daily_standup") },
            generationClientFactory: { _ in StubLLMClient(cannedResponse: "# Notes\n\nDetails.") }
        )
        _ = try await explicitRunner.generate(meetingId: meetingId, templateId: "standard_meeting", speakerCount: nil)
        #expect(await classifierSpy.callCount == 0)

        let autoRunner = makeRunner(
            db: db,
            settings: settings,
            classifierClientFactory: { _ in SpyLLMClient(spy: classifierSpy, cannedResponse: "daily_standup") },
            generationClientFactory: { _ in StubLLMClient(cannedResponse: "# Notes\n\nDetails.") }
        )
        let summary = try await autoRunner.generate(meetingId: meetingId, templateId: nil, speakerCount: 3)
        #expect(await classifierSpy.callCount == 1)
        #expect(summary.templateId == "daily_standup")
    }

    // MARK: - cancel

    @Test("cancel forwards to the underlying SummaryService and is honest when nothing is running")
    func cancelForwardsToSummaryService() async throws {
        let db = try AppDatabase.makeInMemory()
        let runner = makeRunner(db: db, settings: StubSettingsReading())

        let didCancel = await runner.cancel(meetingId)
        #expect(!didCancel)
    }
}
