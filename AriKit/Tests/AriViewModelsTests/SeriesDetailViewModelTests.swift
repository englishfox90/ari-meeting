//
//  SeriesDetailViewModelTests.swift — ledger present/absent honest; member meetings resolve
//  (docs/plans/arikit-native-read-ui.md §7 Lane 1, S6f); rename/delete/merge/rebuildLedger
//  (docs/plans/glittery-humming-truffle.md Part 3).
//
import Foundation
import Testing
@testable import AriKit
@testable import AriViewModels

@Suite("SeriesDetailViewModel")
@MainActor
struct SeriesDetailViewModelTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    /// A `SeriesLedgerReducer` whose `clientFactory` always returns `cannedResponse` — good enough
    /// for tests that only need `rebuildLedger`/`merge` to run without a real provider configured.
    private func makeReducer(
        db: AppDatabase,
        cannedResponse: String = "## Open action items\n_None yet._"
    ) -> SeriesLedgerReducer {
        SeriesLedgerReducer(
            db: db,
            settings: StubSettingsReading(summaryModelConfigValue: SummaryModelConfig(
                providerKey: "mlx",
                model: "test-model"
            )),
            secrets: StubSecretsReading(),
            clientFactory: { _ in StubLedgerLLMClient(cannedResponse: cannedResponse) }
        )
    }

    private struct StubLedgerLLMClient: LLMClient {
        let kind: ProviderKind = .mlx
        var cannedResponse: String
        func generate(_ request: LLMRequest) async throws -> String {
            cannedResponse
        }
    }

    /// An `LLMClient` that sleeps before responding — used to prove a caller (M2's `merge`)
    /// genuinely does NOT await this client inline.
    private struct SlowStubLLMClient: LLMClient {
        let kind: ProviderKind = .mlx
        var cannedResponse: String
        var delayNanoseconds: UInt64
        func generate(_ request: LLMRequest) async throws -> String {
            try await Task.sleep(nanoseconds: delayNanoseconds)
            return cannedResponse
        }
    }

    @Test("honest nil ledger when none has been written")
    func honestNilLedger() async throws {
        let database = try AppDatabase.makeInMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let seriesId: SeriesID = "series-1"
        let series = Series(id: seriesId, title: "Weekly 1:1", createdAt: now, updatedAt: now)
        try await database.series.upsert(series)

        let viewModel = SeriesDetailViewModel(database: database, ledgerReducer: makeReducer(db: database))
        await viewModel.load(seriesId)

        #expect(viewModel.series.value?.ledgerMarkdown == nil)
        #expect(viewModel.series.value?.ledgerVersion == nil)
        #expect(viewModel.memberMeetings.isEmpty)
    }

    @Test("resolves ledger and member meetings when present")
    func resolvesLedgerAndMembers() async throws {
        let database = try AppDatabase.makeInMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let seriesId: SeriesID = "series-2"
        var series = Series(id: seriesId, title: "Weekly 1:1", createdAt: now, updatedAt: now)
        series.ledgerMarkdown = "## Open items\n- Follow up"
        series.ledgerVersion = 1
        try await database.series.upsert(series)

        let meetingId: MeetingID = "meeting-1"
        let meeting = Meeting(id: meetingId, title: "1:1 — week 1", createdAt: now, updatedAt: now)
        try await database.meetings.upsert(meeting)
        try await database.series.addMember(seriesId: seriesId, meetingId: meetingId)

        let viewModel = SeriesDetailViewModel(database: database, ledgerReducer: makeReducer(db: database))
        await viewModel.load(seriesId)

        #expect(viewModel.series.value?.ledgerMarkdown == "## Open items\n- Follow up")
        #expect(viewModel.series.value?.ledgerVersion == 1)
        #expect(viewModel.memberMeetings.map(\.id) == [meetingId])
    }

    @Test("honest failed when the series does not exist")
    func honestFailedOnMissingSeries() async throws {
        let database = try AppDatabase.makeInMemory()
        let viewModel = SeriesDetailViewModel(database: database, ledgerReducer: makeReducer(db: database))
        await viewModel.load("does-not-exist")

        guard case .failed = viewModel.series else {
            Issue.record("expected .failed, got \(viewModel.series)")
            return
        }
    }

    // MARK: - Rename

    @Test("rename refuses a blank title")
    func renameRefusesBlankTitle() async throws {
        let database = try AppDatabase.makeInMemory()
        let seriesId = try await database.series.createSeries(title: "Original", at: epoch)
        let viewModel = SeriesDetailViewModel(database: database, ledgerReducer: makeReducer(db: database))
        await viewModel.load(seriesId)

        await viewModel.rename(to: "   ")

        #expect(viewModel.errorMessage != nil)
        let persisted = try await database.series.find(seriesId)
        #expect(persisted?.title == "Original")
    }

    @Test("rename updates the title and reloads")
    func renameUpdatesTitle() async throws {
        let database = try AppDatabase.makeInMemory()
        let seriesId = try await database.series.createSeries(title: "Original", at: epoch)
        let viewModel = SeriesDetailViewModel(database: database, ledgerReducer: makeReducer(db: database))
        await viewModel.load(seriesId)

        await viewModel.rename(to: "Renamed")

        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.series.value?.title == "Renamed")
    }

    // MARK: - Delete

    @Test("delete tombstones the series and returns true")
    func deleteTombstones() async throws {
        let database = try AppDatabase.makeInMemory()
        let seriesId = try await database.series.createSeries(title: "Gone soon", at: epoch)
        let viewModel = SeriesDetailViewModel(database: database, ledgerReducer: makeReducer(db: database))
        await viewModel.load(seriesId)

        let succeeded = await viewModel.delete()

        #expect(succeeded)
        let all = try await database.series.allSummaries()
        #expect(!all.contains { $0.id == seriesId })
    }

    // MARK: - Merge

    @Test("merge moves membership into the target and returns the target id")
    func mergeMovesIntoTarget() async throws {
        let database = try AppDatabase.makeInMemory()
        let sourceId = try await database.series.createSeries(title: "Duplicate", at: epoch)
        let targetId = try await database.series.createSeries(title: "Canonical", at: epoch)

        let meeting = Meeting(id: "m1", title: "1:1", createdAt: epoch, updatedAt: epoch)
        try await database.meetings.upsert(meeting)
        try await database.series.addMember(seriesId: sourceId, meetingId: meeting.id, at: epoch)

        let viewModel = SeriesDetailViewModel(database: database, ledgerReducer: makeReducer(db: database))
        await viewModel.load(sourceId)

        let result = await viewModel.merge(into: targetId)

        #expect(result == targetId)
        let targetMembers = try await database.series.meetingIds(inSeries: targetId)
        #expect(targetMembers == [meeting.id])
        let all = try await database.series.allSummaries()
        #expect(!all.contains { $0.id == sourceId })
    }

    // M2: the target ledger rebuild must be fire-and-forget — `merge` should not await the
    // reducer's LLM call(s). We can't measure "instant" directly (the stub client is already
    // fast), but we CAN assert that `merge` returns before the reducer has necessarily run, by
    // giving the reducer a response that only becomes available after a short delay and
    // confirming `merge` still returns promptly, then polling for the ledger to land afterward.
    @Test("merge is fire-and-forget on the target ledger rebuild — it doesn't block on the LLM")
    func mergeDoesNotBlockOnLedgerRebuild() async throws {
        let database = try AppDatabase.makeInMemory()
        let sourceId = try await database.series.createSeries(title: "Duplicate", at: epoch)
        let targetId = try await database.series.createSeries(title: "Canonical", at: epoch)

        let meeting = Meeting(id: "m1", title: "1:1", createdAt: epoch, updatedAt: epoch)
        try await database.meetings.upsert(meeting)
        try await database.series.addMember(seriesId: targetId, meetingId: meeting.id, at: epoch)
        try await database.summaries.upsert(Summary(
            id: SummaryID("s1"), meetingId: meeting.id, bodyMarkdown: "- Ship the beta",
            createdAt: epoch, updatedAt: epoch
        ))

        let cannedLedger = "## Open action items\n- Ship the beta\n\n## Decisions\n_None yet._\n\n## Recurring themes\n_None yet._\n\n## Per-person threads\n_None yet._"
        let reducer = SeriesLedgerReducer(
            db: database,
            settings: StubSettingsReading(summaryModelConfigValue: SummaryModelConfig(
                providerKey: "mlx", model: "test-model"
            )),
            secrets: StubSecretsReading(),
            clientFactory: { _ in
                SlowStubLLMClient(cannedResponse: cannedLedger, delayNanoseconds: 300_000_000)
            }
        )
        let viewModel = SeriesDetailViewModel(database: database, ledgerReducer: reducer)
        await viewModel.load(sourceId)

        let clock = ContinuousClock()
        let started = clock.now
        let result = await viewModel.merge(into: targetId)
        let elapsed = started.duration(to: clock.now)

        #expect(result == targetId)
        // `merge` itself does only fast DB writes — it must return well before the reducer's
        // artificial 300ms LLM delay would have elapsed if it had been awaited inline.
        #expect(elapsed < .milliseconds(150))
        // The ledger isn't there yet (the fold hasn't landed) — proof the rebuild really was
        // deferred, not just fast.
        let immediatelyAfter = try await database.series.find(targetId)
        #expect(immediatelyAfter?.ledgerMarkdown == nil)

        // Poll briefly for the detached fold to land.
        var foldedLedger: String?
        for _ in 0 ..< 50 {
            if let ledger = try await database.series.find(targetId)?.ledgerMarkdown {
                foldedLedger = ledger
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(foldedLedger == cannedLedger)
    }

    // MARK: - M1: per-action error isolation

    @Test("rename clears a stale error left over from a different failed action")
    func renameClearsStaleError() async throws {
        let database = try AppDatabase.makeInMemory()
        let seriesId = try await database.series.createSeries(title: "Original", at: epoch)
        let viewModel = SeriesDetailViewModel(database: database, ledgerReducer: makeReducer(db: database))
        await viewModel.load(seriesId)

        // Leave a stale error behind from an unrelated failed rebuild.
        await viewModel.rebuildLedger()
        #expect(viewModel.errorMessage != nil)

        await viewModel.rename(to: "Renamed")

        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.series.value?.title == "Renamed")
    }

    @Test("clearError blanks a stale message without touching any other state")
    func clearErrorBlanksMessage() async throws {
        let database = try AppDatabase.makeInMemory()
        let seriesId = try await database.series.createSeries(title: "Original", at: epoch)
        let viewModel = SeriesDetailViewModel(database: database, ledgerReducer: makeReducer(db: database))
        await viewModel.load(seriesId)

        await viewModel.rebuildLedger()
        #expect(viewModel.errorMessage != nil)

        viewModel.clearError()

        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.series.value?.title == "Original")
    }

    @Test("delete clears a stale error left over from a different failed action")
    func deleteClearsStaleError() async throws {
        let database = try AppDatabase.makeInMemory()
        let seriesId = try await database.series.createSeries(title: "Gone soon", at: epoch)
        let viewModel = SeriesDetailViewModel(database: database, ledgerReducer: makeReducer(db: database))
        await viewModel.load(seriesId)

        await viewModel.rebuildLedger()
        #expect(viewModel.errorMessage != nil)

        let succeeded = await viewModel.delete()

        #expect(succeeded)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("merge clears a stale error left over from a different failed action")
    func mergeClearsStaleError() async throws {
        let database = try AppDatabase.makeInMemory()
        let sourceId = try await database.series.createSeries(title: "Duplicate", at: epoch)
        let targetId = try await database.series.createSeries(title: "Canonical", at: epoch)
        let viewModel = SeriesDetailViewModel(database: database, ledgerReducer: makeReducer(db: database))
        await viewModel.load(sourceId)

        await viewModel.rebuildLedger()
        #expect(viewModel.errorMessage != nil)

        let result = await viewModel.merge(into: targetId)

        #expect(result == targetId)
        #expect(viewModel.errorMessage == nil)
    }

    // MARK: - Rebuild ledger

    @Test("rebuildLedger surfaces an honest message when there is nothing to build from")
    func rebuildLedgerHonestEmpty() async throws {
        let database = try AppDatabase.makeInMemory()
        let seriesId = try await database.series.createSeries(title: "No summaries yet", at: epoch)
        let viewModel = SeriesDetailViewModel(database: database, ledgerReducer: makeReducer(db: database))
        await viewModel.load(seriesId)

        await viewModel.rebuildLedger()

        #expect(viewModel.isRebuildingLedger == false)
        #expect(viewModel.errorMessage == "No summarized meetings yet — nothing to build a ledger from.")
    }

    @Test("rebuildLedger clears isRebuildingLedger and populates the ledger on success")
    func rebuildLedgerSucceeds() async throws {
        let database = try AppDatabase.makeInMemory()
        let seriesId = try await database.series.createSeries(title: "Weekly 1:1", at: epoch)
        let meeting = Meeting(id: "m1", title: "1:1", createdAt: epoch, updatedAt: epoch)
        try await database.meetings.upsert(meeting)
        try await database.series.addMember(seriesId: seriesId, meetingId: meeting.id, at: epoch)
        try await database.summaries.upsert(Summary(
            id: SummaryID("s1"),
            meetingId: meeting.id,
            bodyMarkdown: "- Ship the beta",
            createdAt: epoch,
            updatedAt: epoch
        ))

        let cannedLedger = "## Open action items\n- Ship the beta\n\n## Decisions\n_None yet._\n\n## Recurring themes\n_None yet._\n\n## Per-person threads\n_None yet._"
        let viewModel = SeriesDetailViewModel(
            database: database,
            ledgerReducer: makeReducer(db: database, cannedResponse: cannedLedger)
        )
        await viewModel.load(seriesId)

        await viewModel.rebuildLedger()

        #expect(viewModel.isRebuildingLedger == false)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.series.value?.ledgerMarkdown == cannedLedger)
    }
}
