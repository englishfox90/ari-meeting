//
//  SummaryServiceTests.swift — plan §6 Slice G (← `ari-engine/src/summary/service.rs`, driven
//  against `AppDatabase.makeInMemory()` + injected `StubSettingsReading`/`StubSecretsReading` +
//  a stub `LLMClient` — headless, no network/Keychain/MLX).
//
import Foundation
import Testing
@testable import AriKit

@Suite("SummaryService — Slice G")
struct SummaryServiceTests {
    private func makeMeeting(id: String, title: String) -> Meeting {
        Meeting(
            id: MeetingID(id),
            title: title,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeService(
        db: AppDatabase,
        cancellation: TaskCancellationCoordinator = TaskCancellationCoordinator(),
        clientFactory: @escaping @Sendable (ProviderConfig) throws -> any LLMClient
    ) -> SummaryService {
        SummaryService(
            db: db,
            settings: StubSettingsReading(),
            secrets: StubSecretsReading(apiKeys: ["claude": "test-key"]),
            cancellation: cancellation,
            clientFactory: clientFactory
        )
    }

    // MARK: - 1. Happy path: body + provenance persisted

    @Test("Stub provider generates a summary; body + provider/model/templateId provenance are persisted")
    func generatesAndPersistsBodyAndProvenance() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "meeting-1", title: "New Meeting")
        try await db.meetings.upsert(meeting)

        let stub = StubLLMClient(
            kind: .claude,
            cannedResponse: "# Team Sync\n\n**Summary**\n\nWe discussed the roadmap."
        )
        let service = makeService(db: db, clientFactory: { _ in stub })

        let request = SummaryProcessRequest(
            meetingId: meeting.id,
            text: "[00:00] Paul: Let's discuss the roadmap.",
            modelProviderKey: "claude",
            modelName: "claude-3-5-sonnet",
            templateId: "standard_meeting",
            detectedTranscriptLanguage: "en"
        )

        let summary = try await service.processTranscript(request)

        #expect(summary.bodyMarkdown.contains("We discussed the roadmap."))
        #expect(summary.provider == "claude")
        #expect(summary.model == "claude-3-5-sonnet")
        #expect(summary.templateId == "standard_meeting")

        let persisted = try #require(try await db.summaries.forMeeting(meeting.id))
        #expect(persisted.id == summary.id)
        #expect(persisted.bodyMarkdown == summary.bodyMarkdown)
        #expect(persisted.provider == "claude")
        #expect(persisted.model == "claude-3-5-sonnet")
    }

    @Test("A second run for the same meeting updates the existing Summary row rather than duplicating it")
    func secondRunUpdatesExistingSummaryRow() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "meeting-rerun", title: "New Meeting")
        try await db.meetings.upsert(meeting)

        let request = SummaryProcessRequest(
            meetingId: meeting.id,
            text: "[00:00] Paul: hello",
            modelProviderKey: "claude",
            modelName: "claude-3-5-sonnet",
            templateId: "standard_meeting",
            detectedTranscriptLanguage: "en"
        )

        let firstStub = StubLLMClient(kind: .claude, cannedResponse: "# First\n\n**Summary**\n\nFirst pass.")
        let firstService = makeService(db: db, clientFactory: { _ in firstStub })
        let first = try await firstService.processTranscript(request)

        let secondStub = StubLLMClient(kind: .claude, cannedResponse: "# Second\n\n**Summary**\n\nSecond pass.")
        let secondService = makeService(db: db, clientFactory: { _ in secondStub })
        let second = try await secondService.processTranscript(request)

        #expect(second.id == first.id)
        #expect(second.bodyMarkdown.contains("Second pass."))

        let allSummaries = try await db.summaries.all()
        #expect(allSummaries.filter { $0.meetingId == meeting.id }.count == 1)
    }

    // MARK: - 2. Auto-title rename gate (← `is_automatic_meeting_title`)

    @Test("An automatic placeholder title is renamed to the AI-generated meeting name")
    func automaticTitleIsRenamed() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "meeting-auto-title", title: "Meeting 12_07_26_14_03_59")
        try await db.meetings.upsert(meeting)

        let stub = StubLLMClient(kind: .claude, cannedResponse: "# Weekly Product Sync\n\n**Summary**\n\nDetails.")
        let service = makeService(db: db, clientFactory: { _ in stub })

        let request = SummaryProcessRequest(
            meetingId: meeting.id,
            text: "[00:00] Paul: hello",
            modelProviderKey: "claude",
            modelName: "claude-3-5-sonnet",
            templateId: "standard_meeting",
            detectedTranscriptLanguage: "en"
        )
        _ = try await service.processTranscript(request)

        let updated = try #require(try await db.meetings.find(meeting.id))
        #expect(updated.title == "Weekly Product Sync")
        #expect(updated.summaryProvider == "claude")
        #expect(updated.summaryModel == "claude-3-5-sonnet")
    }

    @Test("The Swift 'Untitled meeting' placeholder is renamed to the AI-generated meeting name")
    func untitledMeetingPlaceholderIsRenamed() async throws {
        let db = try AppDatabase.makeInMemory()
        // The RecordingSession default for an un-named recording — must be treated as an app
        // placeholder, not a user title, so the generated name replaces it.
        let meeting = makeMeeting(id: "meeting-untitled", title: "Untitled meeting")
        try await db.meetings.upsert(meeting)

        let stub = StubLLMClient(kind: .claude, cannedResponse: "# Preston 1:1\n\n**Summary**\n\nDetails.")
        let service = makeService(db: db, clientFactory: { _ in stub })

        let request = SummaryProcessRequest(
            meetingId: meeting.id,
            text: "[00:00] Paul: hello",
            modelProviderKey: "claude",
            modelName: "claude-3-5-sonnet",
            templateId: "standard_meeting",
            detectedTranscriptLanguage: "en"
        )
        _ = try await service.processTranscript(request)

        let updated = try #require(try await db.meetings.find(meeting.id))
        #expect(updated.title == "Preston 1:1")
    }

    @Test("An explicit user-given title is preserved even though a name was generated")
    func explicitTitleIsPreserved() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "meeting-explicit-title", title: "Weekly Sync with Trent")
        try await db.meetings.upsert(meeting)

        let stub = StubLLMClient(kind: .claude, cannedResponse: "# Something Else\n\n**Summary**\n\nDetails.")
        let service = makeService(db: db, clientFactory: { _ in stub })

        let request = SummaryProcessRequest(
            meetingId: meeting.id,
            text: "[00:00] Paul: hello",
            modelProviderKey: "claude",
            modelName: "claude-3-5-sonnet",
            templateId: "standard_meeting",
            detectedTranscriptLanguage: "en"
        )
        _ = try await service.processTranscript(request)

        let updated = try #require(try await db.meetings.find(meeting.id))
        #expect(updated.title == "Weekly Sync with Trent")
        // Provenance is still recorded even when the title itself is preserved.
        #expect(updated.summaryProvider == "claude")
    }

    // MARK: - 3. Settings/secrets resolution failures never leave a partial write

    @Test("Missing API key throws .notConfigured and writes nothing to the Store")
    func missingAPIKeyThrowsNotConfiguredNoPartialWrite() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "meeting-no-key", title: "New Meeting")
        try await db.meetings.upsert(meeting)

        let service = SummaryService(
            db: db,
            settings: StubSettingsReading(),
            secrets: StubSecretsReading(apiKeys: [:]), // no key configured for "claude"
            cancellation: TaskCancellationCoordinator(),
            clientFactory: { _ in StubLLMClient(kind: .claude) }
        )

        let request = SummaryProcessRequest(
            meetingId: meeting.id,
            text: "[00:00] Paul: hello",
            modelProviderKey: "claude",
            modelName: "claude-3-5-sonnet",
            templateId: "standard_meeting"
        )

        do {
            _ = try await service.processTranscript(request)
            Issue.record("expected LLMError.notConfigured")
        } catch LLMError.notConfigured {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(try await db.summaries.forMeeting(meeting.id) == nil)
    }

    @Test("An unparseable provider key throws .notConfigured")
    func unknownProviderThrowsNotConfigured() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "meeting-bad-provider", title: "New Meeting")
        try await db.meetings.upsert(meeting)

        let service = makeService(db: db, clientFactory: { _ in StubLLMClient() })
        let request = SummaryProcessRequest(
            meetingId: meeting.id,
            text: "hello",
            modelProviderKey: "not-a-real-provider",
            modelName: "whatever",
            templateId: "standard_meeting"
        )

        do {
            _ = try await service.processTranscript(request)
            Issue.record("expected LLMError.notConfigured")
        } catch LLMError.notConfigured {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - 4. Cancellation mid-run

    @Test("Cancellation mid-run throws .cancelled and leaves no partial Store write")
    func cancellationMidRunThrowsCancelledWithNoPartialWrite() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "meeting-cancel", title: "New Meeting")
        try await db.meetings.upsert(meeting)

        let signal = StartSignal()
        let client = SlowGateStubClient(signal: signal)
        let coordinator = TaskCancellationCoordinator()
        let service = SummaryService(
            db: db,
            settings: StubSettingsReading(),
            secrets: StubSecretsReading(apiKeys: ["claude": "test-key"]),
            cancellation: coordinator,
            clientFactory: { _ in client }
        )

        let request = SummaryProcessRequest(
            meetingId: meeting.id,
            text: "[00:00] Paul: hello",
            modelProviderKey: "claude",
            modelName: "claude-3-5-sonnet",
            templateId: "standard_meeting",
            detectedTranscriptLanguage: "en"
        )

        async let outcome = service.processTranscript(request)

        // Wait until the stub client's `generate` is actually in flight before cancelling, so the
        // cancellation is guaranteed to land mid-run rather than racing the initial dispatch.
        await signal.waitUntilStarted()
        let didCancel = await service.cancelSummary(meeting.id)
        #expect(didCancel)

        do {
            _ = try await outcome
            Issue.record("expected LLMError.cancelled")
        } catch LLMError.cancelled {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        // No partial write: the meeting title/provenance and the summary row are both untouched.
        let meetingAfter = try #require(try await db.meetings.find(meeting.id))
        #expect(meetingAfter.title == "New Meeting")
        #expect(meetingAfter.summaryProvider == nil)
        #expect(try await db.summaries.forMeeting(meeting.id) == nil)
    }

    @Test("Cancelling a meeting with no in-flight generation returns false")
    func cancelWithNothingRunningReturnsFalse() async throws {
        let coordinator = TaskCancellationCoordinator()
        let db = try AppDatabase.makeInMemory()
        let service = makeService(db: db, cancellation: coordinator, clientFactory: { _ in StubLLMClient() })
        let didCancel = await service.cancelSummary(MeetingID("no-such-meeting"))
        #expect(!didCancel)
    }
}

// MARK: - Test doubles

/// A one-shot "has the client's `generate` actually started" signal, so the cancellation test can
/// wait for the in-flight call instead of relying on a fixed sleep duration.
private actor StartSignal {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }

    func waitUntilStarted() async {
        if started {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

/// An `LLMClient` whose `generate` signals `StartSignal` then sleeps long enough for a concurrent
/// `cancelSummary` call to land before it would ever return a real response.
private struct SlowGateStubClient: LLMClient {
    let kind: ProviderKind = .claude
    let signal: StartSignal

    func generate(_: LLMRequest) async throws -> String {
        await signal.markStarted()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        try Task.checkCancellation()
        return "should never be reached — cancelled first"
    }
}
