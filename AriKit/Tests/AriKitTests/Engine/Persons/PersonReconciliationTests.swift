//
//  PersonReconciliationTests.swift — Phase 3.4 Track H §2.6 (← `ari-engine/src/persons/
//  reconciliation.rs` `#[cfg(test)]`-equivalent behavior), driven against
//  `AppDatabase.makeInMemory()` + injected `StubSettingsReading`/`StubSecretsReading` + a canned
//  `StubLLMClient` — headless, no network/Store-owner violation.
//
import Foundation
import Testing
@testable import AriKit

@Suite("PersonReconciliation — Phase 3.4 Track H")
struct PersonReconciliationTests {
    private func makeMeeting(id: String = "meeting-1") -> Meeting {
        Meeting(
            id: MeetingID(id),
            title: "Weekly sync",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makePerson(id: String, email: String, name: String) -> Person {
        Person(
            id: PersonID(id),
            email: email,
            displayName: name,
            isOwner: false,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeTranscript(meetingId: MeetingID, text: String) -> Transcript {
        Transcript(
            id: TranscriptID(UUID().uuidString),
            meetingId: meetingId,
            transcript: text,
            timestamp: "00:00:00",
            audioStartTime: 0,
            audioEndTime: 2
        )
    }

    private func makeReconciliation(
        db: AppDatabase,
        cannedResponse: String,
        summaryModelConfigValue: SummaryModelConfig? = SummaryModelConfig(
            providerKey: "claude",
            model: "claude-3-5-sonnet"
        )
    ) -> PersonReconciliation {
        PersonReconciliation(
            db: db,
            settings: StubSettingsReading(summaryModelConfigValue: summaryModelConfigValue),
            secrets: StubSecretsReading(apiKeys: ["claude": "test-key"]),
            clientFactory: { _ in StubLLMClient(kind: .claude, cannedResponse: cannedResponse) }
        )
    }

    /// Seeds a meeting with one linked participant + one transcript line; returns the meeting
    /// and person for the caller to build on.
    private func seedMeetingWithParticipant(db: AppDatabase) async throws -> (Meeting, Person) {
        let meeting = makeMeeting()
        try await db.meetings.upsert(meeting)
        let sarah = makePerson(id: "person-sarah", email: "sarah@example.com", name: "Sarah")
        try await db.persons.upsert(sarah)
        try await db.persons.addParticipant(meetingId: meeting.id, personId: sarah.id)
        try await db.transcripts.upsert(makeTranscript(meetingId: meeting.id, text: "Some transcript text."))
        return (meeting, sarah)
    }

    private func makeExistingFact(
        person: PersonID,
        text: String = "Existing fact",
        status: FactStatus = .active,
        confidence: Double = 0.5,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> ProfileFact {
        ProfileFact(
            id: ProfileFactID(UUID().uuidString),
            personId: person,
            factText: text,
            factKind: .other,
            origin: .attributed,
            confidence: confidence,
            sourceCount: 0,
            status: status,
            createdAt: createdAt
        )
    }

    // MARK: - Add / keep / supersede / remove decision loop

    @Test("'add' with evidence creates a new pending fact + origin source")
    func addCreatesNewPendingFact() async throws {
        let db = try AppDatabase.makeInMemory()
        let (meeting, sarah) = try await seedMeetingWithParticipant(db: db)

        let canned = """
        [{"person_email": "sarah@example.com", "person_name": "Sarah", "op": "add", \
        "fact_id": null, "fact_text": "Leads the migration", "fact_kind": "project", \
        "confidence": 0.7, "source_segment_ref": "I'm leading the migration.", "reason": null}]
        """
        let reconciliation = makeReconciliation(db: db, cannedResponse: canned)
        let result = try await reconciliation.reconcileFacts(forMeeting: meeting.id)

        #expect(result.added == 1)
        #expect(result.superseded == 0)
        #expect(result.kept == 0)
        #expect(result.removed == 0)

        let facts = try await db.profileFacts.all()
        #expect(facts.count == 1)
        #expect(facts.first?.personId == sarah.id)
        #expect(facts.first?.status == .pending)
        let withProvenance = try await db.profileFacts.withProvenance(facts[0].id)
        #expect(withProvenance?.sources.count == 1)
    }

    @Test("'add' missing fact_text or source_segment_ref is skipped (No-Fake-State: never guessed)")
    func addMissingEvidenceIsSkipped() async throws {
        let db = try AppDatabase.makeInMemory()
        let (meeting, _) = try await seedMeetingWithParticipant(db: db)

        let canned = """
        [{"person_email": "sarah@example.com", "person_name": "Sarah", "op": "add", \
        "fact_id": null, "fact_text": null, "fact_kind": "project", \
        "confidence": 0.7, "source_segment_ref": null, "reason": null}]
        """
        let reconciliation = makeReconciliation(db: db, cannedResponse: canned)
        let result = try await reconciliation.reconcileFacts(forMeeting: meeting.id)

        #expect(result.added == 0)
        #expect(try await db.profileFacts.all().isEmpty)
    }

    @Test("'supersede' on an existing fact creates a pending replacement WITHOUT retiring the old fact")
    func supersedeCreatesDeferredReplacement() async throws {
        let db = try AppDatabase.makeInMemory()
        let (meeting, sarah) = try await seedMeetingWithParticipant(db: db)
        let oldFact = makeExistingFact(person: sarah.id, text: "Ships v2 by Q3", status: .active, confidence: 0.6)
        try await db.profileFacts.upsert(oldFact)

        let canned = """
        [{"person_email": "sarah@example.com", "person_name": "Sarah", "op": "supersede", \
        "fact_id": "\(oldFact.id.rawValue)", "fact_text": "Ships v2 by end of Q3", \
        "fact_kind": "goal", "confidence": 0.8, \
        "source_segment_ref": "Actually it's end of Q3.", "reason": null}]
        """
        let reconciliation = makeReconciliation(db: db, cannedResponse: canned)
        let result = try await reconciliation.reconcileFacts(forMeeting: meeting.id)

        #expect(result.superseded == 1)

        // Deferred supersession: the OLD fact stays active — nothing retires it in this track.
        let reloadedOld = try await db.profileFacts.find(oldFact.id)
        #expect(reloadedOld?.status == .active)

        let all = try await db.profileFacts.all()
        #expect(all.count == 2)
        let newFact = try #require(all.first { $0.id != oldFact.id })
        #expect(newFact.status == .pending)
        #expect(newFact.factText == "Ships v2 by end of Q3")
    }

    @Test("'supersede' referencing a fact_id NOT owned by the resolved person is refused")
    func supersedeRefusesUnownedFactId() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting()
        try await db.meetings.upsert(meeting)
        let sarah = makePerson(id: "person-sarah", email: "sarah@example.com", name: "Sarah")
        let bob = makePerson(id: "person-bob", email: "bob@example.com", name: "Bob")
        try await db.persons.upsert(sarah)
        try await db.persons.upsert(bob)
        try await db.persons.addParticipant(meetingId: meeting.id, personId: sarah.id)
        try await db.persons.addParticipant(meetingId: meeting.id, personId: bob.id)
        try await db.transcripts.upsert(makeTranscript(meetingId: meeting.id, text: "Some text."))

        // A fact that belongs to Bob, not Sarah.
        let bobsFact = makeExistingFact(person: bob.id, text: "Bob's fact")
        try await db.profileFacts.upsert(bobsFact)

        let canned = """
        [{"person_email": "sarah@example.com", "person_name": "Sarah", "op": "supersede", \
        "fact_id": "\(bobsFact.id.rawValue)", "fact_text": "Hijacked", "fact_kind": "other", \
        "confidence": 0.9, "source_segment_ref": "evidence", "reason": null}]
        """
        let reconciliation = makeReconciliation(db: db, cannedResponse: canned)
        let result = try await reconciliation.reconcileFacts(forMeeting: meeting.id)

        #expect(result.superseded == 0)
        // Bob's fact is untouched — no new pending replacement was created.
        #expect(try await db.profileFacts.all().count == 1)
        let reloaded = try await db.profileFacts.find(bobsFact.id)
        #expect(reloaded?.factText == "Bob's fact")
    }

    @Test("'keep' resets the staleness clock and dedup-records a reaffirming source")
    func keepTouchesConfirmedAndAddsSource() async throws {
        let db = try AppDatabase.makeInMemory()
        let (meeting, sarah) = try await seedMeetingWithParticipant(db: db)
        let existing = makeExistingFact(person: sarah.id, status: .active, confidence: 0.5)
        try await db.profileFacts.upsert(existing)

        let canned = """
        [{"person_email": "sarah@example.com", "person_name": "Sarah", "op": "keep", \
        "fact_id": "\(existing.id.rawValue)", "fact_text": null, "fact_kind": null, \
        "confidence": 0.6, "source_segment_ref": "reaffirmed here", "reason": null}]
        """
        let reconciliation = makeReconciliation(db: db, cannedResponse: canned)
        let result = try await reconciliation.reconcileFacts(forMeeting: meeting.id)

        #expect(result.kept == 1)
        let withProvenance = try await db.profileFacts.withProvenance(existing.id)
        #expect(withProvenance?.sources.count == 1)
        #expect(withProvenance?.sources.first?.relation == .reaffirmed)
    }

    @Test("'remove' marks an existing fact .removed")
    func removeMarksFactRemoved() async throws {
        let db = try AppDatabase.makeInMemory()
        let (meeting, sarah) = try await seedMeetingWithParticipant(db: db)
        let existing = makeExistingFact(person: sarah.id, status: .active)
        try await db.profileFacts.upsert(existing)

        let canned = """
        [{"person_email": "sarah@example.com", "person_name": "Sarah", "op": "remove", \
        "fact_id": "\(existing.id.rawValue)", "fact_text": null, "fact_kind": null, \
        "confidence": null, "source_segment_ref": null, "reason": null}]
        """
        let reconciliation = makeReconciliation(db: db, cannedResponse: canned)
        let result = try await reconciliation.reconcileFacts(forMeeting: meeting.id)

        #expect(result.removed == 1)
        let reloaded = try await db.profileFacts.find(existing.id)
        #expect(reloaded?.status == .removed)
    }

    @Test("An unknown op is skipped, never guessed")
    func unknownOpIsSkipped() async throws {
        let db = try AppDatabase.makeInMemory()
        let (meeting, _) = try await seedMeetingWithParticipant(db: db)

        let canned = """
        [{"person_email": "sarah@example.com", "person_name": "Sarah", "op": "frobnicate", \
        "fact_id": null, "fact_text": null, "fact_kind": null, "confidence": null, \
        "source_segment_ref": null, "reason": null}]
        """
        let reconciliation = makeReconciliation(db: db, cannedResponse: canned)
        let result = try await reconciliation.reconcileFacts(forMeeting: meeting.id)

        #expect(result.added == 0 && result.superseded == 0 && result.kept == 0 && result.removed == 0)
    }

    // MARK: - Cap backstops

    @Test("The active-fact cap prunes past 12 regardless of the model's decisions")
    func activeCapPrunesPastTwelve() async throws {
        let db = try AppDatabase.makeInMemory()
        let (meeting, sarah) = try await seedMeetingWithParticipant(db: db)

        // Seed 12 existing active facts (at the cap already) with ascending confidence, so the
        // 13th `add` pushes it 1 over and the LOWEST-confidence one gets pruned.
        for i in 0 ..< 12 {
            try await db.profileFacts.upsert(makeExistingFact(
                person: sarah.id,
                text: "Active fact \(i)",
                status: .active,
                confidence: Double(i) / 20.0,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i))
            ))
        }

        let canned = """
        [{"person_email": "sarah@example.com", "person_name": "Sarah", "op": "add", \
        "fact_id": null, "fact_text": "One more fact", "fact_kind": "other", \
        "confidence": 0.99, "source_segment_ref": "evidence", "reason": null}]
        """
        let reconciliation = makeReconciliation(db: db, cannedResponse: canned)
        let result = try await reconciliation.reconcileFacts(forMeeting: meeting.id)

        #expect(result.added == 1)
        // The new fact is `pending`, so it doesn't count toward the ACTIVE cap — the 12
        // pre-existing active facts are exactly at cap, so nothing should be pruned yet.
        #expect(result.capped == 0)
        #expect(try await db.profileFacts.activeFacts(for: sarah.id).count == 12)
    }

    @Test("The active-fact cap prunes the lowest-confidence/oldest fact when the count exceeds 12")
    func activeCapPrunesLowestConfidenceFact() async throws {
        let db = try AppDatabase.makeInMemory()
        let (meeting, sarah) = try await seedMeetingWithParticipant(db: db)

        // 13 pre-existing ACTIVE facts — already 1 over the cap of 12.
        var facts: [ProfileFact] = []
        for i in 0 ..< 13 {
            let fact = makeExistingFact(
                person: sarah.id,
                text: "Active fact \(i)",
                status: .active,
                confidence: Double(i) / 20.0, // fact 0 has the lowest confidence
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i))
            )
            try await db.profileFacts.upsert(fact)
            facts.append(fact)
        }

        // The cap backstop runs regardless of the model's ops — a harmless "keep" on the
        // highest-confidence fact (← the ops array just can't be EMPTY, which short-circuits
        // before the cap section is ever reached, matching Rust's own early return).
        let keepTarget = try #require(facts.last)
        let canned = """
        [{"person_email": "sarah@example.com", "person_name": "Sarah", "op": "keep", \
        "fact_id": "\(keepTarget.id.rawValue)", "fact_text": null, "fact_kind": null, \
        "confidence": null, "source_segment_ref": null, "reason": null}]
        """
        let reconciliation = makeReconciliation(db: db, cannedResponse: canned)
        let result = try await reconciliation.reconcileFacts(forMeeting: meeting.id)

        #expect(result.kept == 1)
        #expect(result.capped == 1)
        let active = try await db.profileFacts.activeFacts(for: sarah.id)
        #expect(active.count == 12)
        #expect(!active.contains { $0.factText == "Active fact 0" })
    }

    @Test("The pending-fact cap prunes past 10 the same way")
    func pendingCapPrunesPastTen() async throws {
        let db = try AppDatabase.makeInMemory()
        let (meeting, sarah) = try await seedMeetingWithParticipant(db: db)

        var facts: [ProfileFact] = []
        for i in 0 ..< 11 {
            let fact = makeExistingFact(
                person: sarah.id,
                text: "Pending fact \(i)",
                status: .pending,
                confidence: Double(i) / 20.0,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i))
            )
            try await db.profileFacts.upsert(fact)
            facts.append(fact)
        }

        let keepTarget = try #require(facts.last)
        let canned = """
        [{"person_email": "sarah@example.com", "person_name": "Sarah", "op": "keep", \
        "fact_id": "\(keepTarget.id.rawValue)", "fact_text": null, "fact_kind": null, \
        "confidence": null, "source_segment_ref": null, "reason": null}]
        """
        let reconciliation = makeReconciliation(db: db, cannedResponse: canned)
        let result = try await reconciliation.reconcileFacts(forMeeting: meeting.id)

        #expect(result.capped == 1)
        let all = try await db.profileFacts.all()
        let stillPending = all.filter { $0.status == .pending }
        #expect(stillPending.count == 10)
    }

    // MARK: - Degrade-gracefully (never throws)

    @Test("No linked participants degrades to an all-zero result")
    func noParticipantsDegrades() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting()
        try await db.meetings.upsert(meeting)

        let reconciliation = makeReconciliation(db: db, cannedResponse: "[]")
        let result = try await reconciliation.reconcileFacts(forMeeting: meeting.id)
        #expect(result == ReconciliationResult(
            added: 0,
            superseded: 0,
            kept: 0,
            removed: 0,
            capped: 0,
            message: result.message
        ))
    }

    @Test("Empty transcript degrades to an all-zero result")
    func emptyTranscriptDegrades() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting()
        try await db.meetings.upsert(meeting)
        let sarah = makePerson(id: "person-sarah", email: "sarah@example.com", name: "Sarah")
        try await db.persons.upsert(sarah)
        try await db.persons.addParticipant(meetingId: meeting.id, personId: sarah.id)

        let reconciliation = makeReconciliation(db: db, cannedResponse: "[]")
        let result = try await reconciliation.reconcileFacts(forMeeting: meeting.id)
        #expect(result.added == 0 && result.capped == 0)
    }

    @Test("Unconfigured provider degrades to an all-zero result")
    func unconfiguredProviderDegrades() async throws {
        let db = try AppDatabase.makeInMemory()
        let (meeting, _) = try await seedMeetingWithParticipant(db: db)

        let reconciliation = makeReconciliation(db: db, cannedResponse: "[]", summaryModelConfigValue: nil)
        let result = try await reconciliation.reconcileFacts(forMeeting: meeting.id)
        #expect(result.added == 0)
    }

    @Test("Unparseable model response degrades to an all-zero result (never throws)")
    func unparseableModelResponseDegrades() async throws {
        let db = try AppDatabase.makeInMemory()
        let (meeting, _) = try await seedMeetingWithParticipant(db: db)

        let reconciliation = makeReconciliation(db: db, cannedResponse: "not json")
        let result = try await reconciliation.reconcileFacts(forMeeting: meeting.id)
        #expect(result.added == 0)
    }

    @Test("An empty ops array degrades to an all-zero result")
    func emptyOpsArrayDegrades() async throws {
        let db = try AppDatabase.makeInMemory()
        let (meeting, _) = try await seedMeetingWithParticipant(db: db)

        let reconciliation = makeReconciliation(db: db, cannedResponse: "[]")
        let result = try await reconciliation.reconcileFacts(forMeeting: meeting.id)
        #expect(result.added == 0 && result.superseded == 0 && result.kept == 0 && result.removed == 0)
    }

    @Test("factsNeedingReview surfaces a fact stale beyond the review window")
    func factsNeedingReviewSurfacesStaleFacts() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(makeMeeting())
        let sarah = makePerson(id: "person-sarah", email: "sarah@example.com", name: "Sarah")
        try await db.persons.upsert(sarah)

        let staleFact = makeExistingFact(
            person: sarah.id,
            status: .active,
            createdAt: Date().addingTimeInterval(-40 * 86400) // 40 days ago > 28-day window
        )
        let freshFact = makeExistingFact(
            person: sarah.id,
            status: .active,
            createdAt: Date() // just created
        )
        try await db.profileFacts.upsert(staleFact)
        try await db.profileFacts.upsert(freshFact)

        let reconciliation = makeReconciliation(db: db, cannedResponse: "[]")
        let needingReview = try await reconciliation.factsNeedingReview(for: sarah.id)

        #expect(needingReview.map(\.id) == [staleFact.id])
    }
}
