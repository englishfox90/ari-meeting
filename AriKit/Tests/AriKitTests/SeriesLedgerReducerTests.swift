//
//  SeriesLedgerReducerTests.swift — F9 ledger reduce engine, driven against
//  `AppDatabase.makeInMemory()` + a capturing stub `LLMClient` (pattern: `SummaryRunnerTests`'
//  `SpyLLMClient` / `SummaryContextAssemblerTests`' repository seeding).
//
import Foundation
import Testing
@testable import AriKit

@Suite("SeriesLedgerReducer (F9 ledger reduce)")
struct SeriesLedgerReducerTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeMeeting(id: String, title: String, createdAt: Date) -> Meeting {
        Meeting(id: MeetingID(id), title: title, createdAt: createdAt, updatedAt: createdAt)
    }

    /// A capturing `LLMClient` — records every user prompt it's asked to `generate` for, so tests
    /// can assert on exactly what the reduce sent (e.g. qualified `@mref` tokens).
    private actor PromptSpy {
        private(set) var userPrompts: [String] = []
        func record(_ prompt: String) {
            userPrompts.append(prompt)
        }
    }

    private struct CapturingLLMClient: LLMClient {
        let kind: ProviderKind = .mlx
        let spy: PromptSpy
        var cannedResponse: String

        func generate(_ request: LLMRequest) async throws -> String {
            await spy.record(request.user)
            return cannedResponse
        }
    }

    private func makeReducer(
        db: AppDatabase,
        cannedResponse: String = "## Open action items\n_None yet._",
        spy: PromptSpy = PromptSpy()
    ) -> (SeriesLedgerReducer, PromptSpy) {
        let reducer = SeriesLedgerReducer(
            db: db,
            settings: StubSettingsReading(summaryModelConfigValue: SummaryModelConfig(
                providerKey: "mlx",
                model: "test-model"
            )),
            secrets: StubSecretsReading(),
            clientFactory: { _ in CapturingLLMClient(spy: spy, cannedResponse: cannedResponse) }
        )
        return (reducer, spy)
    }

    // MARK: - Full rebuild

    @Test("Full rebuild over 2 members qualifies @ref into per-meeting @mref before reducing")
    func fullRebuildQualifiesRefsPerMember() async throws {
        let db = try AppDatabase.makeInMemory()
        let seriesId = try await db.series.createSeries(title: "Brian 1:1", at: epoch)

        let m1 = makeMeeting(id: "m1", title: "Brian 1:1 (week 1)", createdAt: epoch)
        let m2 = makeMeeting(id: "m2", title: "Brian 1:1 (week 2)", createdAt: epoch.addingTimeInterval(7 * 24 * 3600))
        try await db.meetings.upsert(m1)
        try await db.meetings.upsert(m2)
        try await db.series.addMember(seriesId: seriesId, meetingId: m1.id, at: epoch)
        try await db.series.addMember(seriesId: seriesId, meetingId: m2.id, at: epoch)

        try await db.summaries.upsert(Summary(
            id: SummaryID("s1"),
            meetingId: m1.id,
            bodyMarkdown: "- Ship the beta @ref(04:21)",
            createdAt: epoch,
            updatedAt: epoch
        ))
        try await db.summaries.upsert(Summary(
            id: SummaryID("s2"),
            meetingId: m2.id,
            bodyMarkdown: "- Follow up on beta @ref(01:15)",
            createdAt: epoch,
            updatedAt: epoch
        ))

        let (reducer, spy) = makeReducer(
            db: db,
            cannedResponse: "## Open action items\n- Ship beta @mref(m1@04:21)\n- Follow up @mref(m2@01:15)\n\n## Decisions\n_None yet._\n\n## Recurring themes\n_None yet._\n\n## Per-person threads\n_None yet._"
        )

        let ledger = try await reducer.rebuildLedger(seriesId: seriesId)

        #expect(ledger != nil)
        #expect(ledger?.contains("@mref(m1@04:21)") == true)
        #expect(ledger?.contains("@mref(m2@01:15)") == true)

        let prompts = await spy.userPrompts
        #expect(prompts.count == 2)
        // First fold: no prior ledger, m1's summary qualified.
        #expect(prompts[0].contains("(No prior ledger"))
        #expect(prompts[0].contains("@mref(m1@04:21)"))
        // Second fold: the accumulated ledger from fold 1 is the "existing ledger" this time,
        // and m2's summary is qualified with its own member index.
        #expect(!prompts[1].contains("(No prior ledger"))
        #expect(prompts[1].contains("@mref(m1@04:21)"))
        #expect(prompts[1].contains("@mref(m2@01:15)"))

        let persisted = try await db.series.find(seriesId)
        #expect(persisted?.ledgerMarkdown == ledger)
        #expect(persisted?.ledgerVersion == 1)
    }

    @Test("Full rebuild returns nil and leaves an existing ledger untouched when no member has a summary")
    func fullRebuildReturnsNilWhenNoMemberHasSummary() async throws {
        let db = try AppDatabase.makeInMemory()
        let seriesId = try await db.series.createSeries(title: "Brian 1:1", at: epoch)
        try await db.series.updateLedger(
            seriesId: seriesId,
            ledgerMarkdown: "- Prior ledger content.",
            structuredJson: nil,
            updatedFromMeetingId: nil,
            ledgerVersion: 1,
            at: epoch
        )

        let m1 = makeMeeting(id: "m1", title: "Brian 1:1", createdAt: epoch)
        try await db.meetings.upsert(m1)
        try await db.series.addMember(seriesId: seriesId, meetingId: m1.id, at: epoch)
        // No summary for m1.

        let (reducer, spy) = makeReducer(db: db)
        let ledger = try await reducer.rebuildLedger(seriesId: seriesId)

        #expect(ledger == nil)
        let prompts = await spy.userPrompts
        #expect(prompts.isEmpty)

        let persisted = try await db.series.find(seriesId)
        #expect(persisted?.ledgerMarkdown == "- Prior ledger content.")
        #expect(persisted?.ledgerVersion == 1)
    }

    // MARK: - Incremental fold

    @Test("foldMeeting no-ops when the meeting is in no series")
    func foldMeetingNoOpsWhenNotInSeries() async throws {
        let db = try AppDatabase.makeInMemory()
        let m1 = makeMeeting(id: "m1", title: "Standalone meeting", createdAt: epoch)
        try await db.meetings.upsert(m1)
        try await db.summaries.upsert(Summary(
            id: SummaryID("s1"),
            meetingId: m1.id,
            bodyMarkdown: "- Some point.",
            createdAt: epoch,
            updatedAt: epoch
        ))

        let (reducer, spy) = makeReducer(db: db)
        try await reducer.foldMeeting(meetingId: m1.id)

        let prompts = await spy.userPrompts
        #expect(prompts.isEmpty)
    }

    @Test("foldMeeting no-ops when the meeting has no summary")
    func foldMeetingNoOpsWhenNoSummary() async throws {
        let db = try AppDatabase.makeInMemory()
        let seriesId = try await db.series.createSeries(title: "Brian 1:1", at: epoch)
        let m1 = makeMeeting(id: "m1", title: "Brian 1:1", createdAt: epoch)
        try await db.meetings.upsert(m1)
        try await db.series.addMember(seriesId: seriesId, meetingId: m1.id, at: epoch)
        // No summary for m1.

        let (reducer, spy) = makeReducer(db: db)
        try await reducer.foldMeeting(meetingId: m1.id)

        let prompts = await spy.userPrompts
        #expect(prompts.isEmpty)
        let persisted = try await db.series.find(seriesId)
        #expect(persisted?.ledgerMarkdown == nil)
    }

    @Test("foldMeeting qualifies refs with the meeting's own member index and updates the ledger")
    func foldMeetingQualifiesAndUpdates() async throws {
        let db = try AppDatabase.makeInMemory()
        let seriesId = try await db.series.createSeries(title: "Brian 1:1", at: epoch)

        let m1 = makeMeeting(id: "m1", title: "Brian 1:1 (week 1)", createdAt: epoch)
        let m2 = makeMeeting(id: "m2", title: "Brian 1:1 (week 2)", createdAt: epoch.addingTimeInterval(7 * 24 * 3600))
        try await db.meetings.upsert(m1)
        try await db.meetings.upsert(m2)
        try await db.series.addMember(seriesId: seriesId, meetingId: m1.id, at: epoch)
        try await db.series.addMember(seriesId: seriesId, meetingId: m2.id, at: epoch)

        try await db.summaries.upsert(Summary(
            id: SummaryID("s2"),
            meetingId: m2.id,
            bodyMarkdown: "- Follow up @ref(02:00)",
            createdAt: epoch,
            updatedAt: epoch
        ))

        let (reducer, spy) = makeReducer(
            db: db,
            cannedResponse: "## Open action items\n- Follow up @mref(m2@02:00)\n\n## Decisions\n_None yet._\n\n## Recurring themes\n_None yet._\n\n## Per-person threads\n_None yet._"
        )

        try await reducer.foldMeeting(meetingId: m2.id)

        let prompts = await spy.userPrompts
        #expect(prompts.count == 1)
        #expect(prompts[0].contains("@mref(m2@02:00)"))

        let persisted = try await db.series.find(seriesId)
        #expect(persisted?.ledgerMarkdown?.contains("@mref(m2@02:00)") == true)
        #expect(persisted?.ledgerVersion == 1)
    }

    // MARK: - Consent (calendar-series-intelligence plan §5, test 20)

    @Test("foldMeeting no-ops for a meeting whose only membership is 'suggested' — No-Fake-State")
    func foldMeetingNoOpsForSuggestedOnlyMembership() async throws {
        let db = try AppDatabase.makeInMemory()
        let seriesId = try await db.series.createSeries(title: "Brian 1:1", at: epoch)
        let m1 = makeMeeting(id: "m1", title: "Brian 1:1", createdAt: epoch)
        try await db.meetings.upsert(m1)
        try await db.series.addMember(
            seriesId: seriesId, meetingId: m1.id, linkSource: "suggested", at: epoch
        )
        try await db.summaries.upsert(Summary(
            id: SummaryID("s1"),
            meetingId: m1.id,
            bodyMarkdown: "- Ship the beta.",
            createdAt: epoch,
            updatedAt: epoch
        ))

        let (reducer, spy) = makeReducer(db: db)
        try await reducer.foldMeeting(meetingId: m1.id)

        let prompts = await spy.userPrompts
        #expect(prompts.isEmpty)
        let persisted = try await db.series.find(seriesId)
        #expect(persisted?.ledgerMarkdown == nil)
    }
}
