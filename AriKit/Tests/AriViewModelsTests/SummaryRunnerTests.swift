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
        func record() {
            callCount += 1
        }
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
        },
        ledgerReducer: SeriesLedgerReducer? = nil
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
            clientFactory: classifierClientFactory,
            ledgerReducer: ledgerReducer
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
        // The summary path emits the load-bearing `[MM:SS]` prefix (← buildSummaryTranscriptText):
        // the timestamp is derived from audioStartTime (1.0s → 00:01) so `SummaryCitations` can
        // verify/back-fill `@ref(MM:SS)` reference badges against it.
        #expect(text == "[00:01] Ada Lovelace: Hello team.")
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
        // No resolved speaker → `[MM:SS] text` (still timestamp-prefixed, no name). With no
        // audioStartTime, the `timestamp` string ("00:00:01") is used verbatim as the marker.
        #expect(text == "[00:00:01] Hello team.")
    }

    // MARK: - generate: honest failures

    @Test("generate throws nothingToSummarize when the meeting has no transcript text")
    func generateThrowsNothingToSummarizeWhenTranscriptEmpty() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(makeMeeting())
        let settings = StubSettingsReading(
            summaryModelConfigValue: SummaryModelConfig(providerKey: "ollama", model: "llama3")
        )
        let runner = makeRunner(db: db, settings: settings)

        do {
            _ = try await runner.generate(meetingId: meetingId, templateId: "standard_meeting", speakerCount: nil)
            Issue.record("expected LLMError.nothingToSummarize")
        } catch LLMError.nothingToSummarize {
            // The benign, non-error path: the UI presents this as a calm note, never as a fault.
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

        let id = await runner.suggestTemplateID(meetingId: meetingId, text: "Let's talk roadmap.", speakerCount: nil)
        #expect(id == TemplateSelector.defaultTemplateID)
        #expect(id == "standard_meeting")
    }

    // MARK: - calendarContextString (Slice A, Gap 1)

    @Test("calendarContextString returns nil when no event is linked to the meeting")
    func calendarContextStringNilWhenNoEventLinked() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(makeMeeting())
        let runner = makeRunner(db: db, settings: StubSettingsReading())

        let context = await runner.calendarContextString(for: meetingId)
        #expect(context == nil)
    }

    @Test("calendarContextString returns a bounded title-only string when the event has no notes")
    func calendarContextStringTitleOnly() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(makeMeeting())
        let event = CalendarEvent(
            id: "event-1", calendarId: "cal-1", title: "1:1 with Ada",
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_003_600),
            isAllDay: false, attendees: [], meetingId: meetingId
        )
        try await db.calendarEvents.upsert(event)
        let runner = makeRunner(db: db, settings: StubSettingsReading())

        let context = await runner.calendarContextString(for: meetingId)
        #expect(context == "1:1 with Ada")
    }

    @Test("calendarContextString truncates a long description at the cap")
    func calendarContextStringTruncatesDescription() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(makeMeeting())
        let longNotes = String(repeating: "x", count: 400)
        let event = CalendarEvent(
            id: "event-1", calendarId: "cal-1", title: "Quarterly planning",
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_003_600),
            isAllDay: false, notes: longNotes, attendees: [], meetingId: meetingId
        )
        try await db.calendarEvents.upsert(event)
        let runner = makeRunner(db: db, settings: StubSettingsReading())

        let context = await runner.calendarContextString(for: meetingId)
        #expect(context != nil)
        #expect(try #require(context?.hasPrefix("Quarterly planning — ")))
        // 200-char cap + the ellipsis suffix, not the full 400-char notes string.
        #expect(try #require(context?.contains("…")))
        #expect(try !(#require(context?.contains(longNotes))))
    }

    @Test("suggestTemplateID forwards a non-nil calendar context into the classifier prompt")
    func suggestTemplateIDForwardsCalendarContext() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(makeMeeting())
        try await db.transcripts.upsert(Transcript(
            id: "transcript-1", meetingId: meetingId, transcript: "Let's talk roadmap.",
            timestamp: "00:00:01"
        ))
        let event = CalendarEvent(
            id: "event-1", calendarId: "cal-1", title: "1:1 with Ada",
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_003_600),
            isAllDay: false, attendees: [], meetingId: meetingId
        )
        try await db.calendarEvents.upsert(event)
        let settings = StubSettingsReading(
            summaryModelConfigValue: SummaryModelConfig(providerKey: "ollama", model: "llama3")
        )

        let promptSpy = PromptSpy()
        let runner = makeRunner(
            db: db,
            settings: settings,
            classifierClientFactory: { _ in PromptCapturingLLMClient(spy: promptSpy) }
        )

        _ = await runner.suggestTemplateID(meetingId: meetingId, text: "Let's talk roadmap.", speakerCount: 2)

        let capturedPrompt = await promptSpy.lastUserPrompt
        #expect(capturedPrompt != nil)
        #expect(try #require(capturedPrompt?.contains("Calendar event context:")))
        #expect(try #require(capturedPrompt?.contains("1:1 with Ada")))
    }

    /// Captures the `user` half of the last `LLMRequest` it was asked to `generate` (← mirrors the
    /// Rust `prompt_includes_speaker_count_and_calendar_context_when_present` test's assertion on
    /// the classifier's user prompt).
    private actor PromptSpy {
        private(set) var lastUserPrompt: String?
        func record(_ prompt: String) {
            lastUserPrompt = prompt
        }
    }

    private struct PromptCapturingLLMClient: LLMClient {
        let kind: ProviderKind = .mlx
        let spy: PromptSpy

        func generate(_ request: LLMRequest) async throws -> String {
            await spy.record(request.user)
            return "standard_meeting"
        }
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

    // MARK: - generate: F9 auto-fold (docs/plans/glittery-humming-truffle.md Part 5)

    @Test("generate auto-folds the fresh summary into the meeting's series ledger, fire-and-forget")
    func generateAutoFoldsIntoSeriesLedger() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(makeMeeting())
        try await db.transcripts.upsert(Transcript(
            id: "transcript-1", meetingId: meetingId, transcript: "Let's talk roadmap.",
            timestamp: "00:00:01"
        ))
        let seriesId = try await db.series.createSeries(title: "Weekly sync series")
        try await db.series.addMember(seriesId: seriesId, meetingId: meetingId)

        let settings = StubSettingsReading(
            summaryModelConfigValue: SummaryModelConfig(providerKey: "ollama", model: "llama3")
        )
        let cannedLedger = "## Open action items\n_None yet._\n\n## Decisions\n_None yet._\n\n## Recurring themes\n_None yet._\n\n## Per-person threads\n_None yet._"
        let reducer = SeriesLedgerReducer(
            db: db,
            settings: settings,
            secrets: StubSecretsReading(),
            clientFactory: { _ in StubLLMClient(cannedResponse: cannedLedger) }
        )
        let runner = makeRunner(
            db: db,
            settings: settings,
            generationClientFactory: { _ in StubLLMClient(cannedResponse: "# Notes\n\nDetails.") },
            ledgerReducer: reducer
        )

        _ = try await runner.generate(meetingId: meetingId, templateId: "standard_meeting", speakerCount: nil)

        // The fold is a detached fire-and-forget task — poll briefly for it to land rather than
        // assuming a fixed delay is enough (and never blocking `generate` itself, per the plan).
        var foldedLedger: String?
        for _ in 0 ..< 50 {
            if let ledger = try await db.series.find(seriesId)?.ledgerMarkdown {
                foldedLedger = ledger
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(foldedLedger == cannedLedger)
    }

    @Test("generate never blocks or fails the summary when auto-fold has nothing to do")
    func generateSucceedsWithNoLedgerReducerInjected() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(makeMeeting())
        try await db.transcripts.upsert(Transcript(
            id: "transcript-1", meetingId: meetingId, transcript: "Let's talk roadmap.",
            timestamp: "00:00:01"
        ))
        let settings = StubSettingsReading(
            summaryModelConfigValue: SummaryModelConfig(providerKey: "ollama", model: "llama3")
        )
        // No ledgerReducer injected — auto-fold is disabled, `generate` must still succeed.
        let runner = makeRunner(
            db: db,
            settings: settings,
            generationClientFactory: { _ in StubLLMClient(cannedResponse: "# Notes\n\nDetails.") }
        )

        let summary = try await runner.generate(meetingId: meetingId, templateId: "standard_meeting", speakerCount: nil)
        #expect(summary.bodyMarkdown.contains("Details."))
    }

    // MARK: - cancel

    @Test("cancel forwards to the underlying SummaryService and is honest when nothing is running")
    func cancelForwardsToSummaryService() async throws {
        let db = try AppDatabase.makeInMemory()
        let runner = makeRunner(db: db, settings: StubSettingsReading())

        let didCancel = await runner.cancel(meetingId)
        #expect(!didCancel)
    }

    // MARK: - mergeCustomPrompt

    @Test("mergeCustomPrompt combines the assembled context block with user instructions honestly")
    func mergeCustomPromptCombinations() {
        #expect(SummaryRunner.mergeCustomPrompt(contextBlock: "", userInstructions: "") == "")
        #expect(SummaryRunner.mergeCustomPrompt(contextBlock: "CTX", userInstructions: "") == "CTX")
        #expect(SummaryRunner.mergeCustomPrompt(contextBlock: "", userInstructions: "USER") == "USER")
        // Whitespace-only inputs collapse to empty (No-Fake-State — never a bare heading).
        #expect(SummaryRunner.mergeCustomPrompt(contextBlock: "   \n", userInstructions: "  ") == "")

        let both = SummaryRunner.mergeCustomPrompt(contextBlock: "CTX", userInstructions: "USER")
        #expect(both.hasPrefix("CTX"))
        #expect(both.contains("### Additional instructions"))
        #expect(both.contains("USER"))
    }
}
