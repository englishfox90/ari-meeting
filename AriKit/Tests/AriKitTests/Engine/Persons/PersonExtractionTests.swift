//
//  PersonExtractionTests.swift — Phase 3.4 Track H §2.6 (← `ari-engine/src/persons/
//  extraction.rs` `#[cfg(test)]`), driven against `AppDatabase.makeInMemory()` + injected
//  `StubSettingsReading`/`StubSecretsReading` + a canned `StubLLMClient` — headless, no
//  network/Store-owner violation.
//
import Foundation
import Testing
@testable import AriKit

@Suite("PersonExtraction — Phase 3.4 Track H")
struct PersonExtractionTests {
    private func makeMeeting() -> Meeting {
        Meeting(
            id: "meeting-1",
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

    private func makeTranscript(id: String, meetingId: MeetingID, text: String, start: Double) -> Transcript {
        Transcript(
            id: TranscriptID(id),
            meetingId: meetingId,
            transcript: text,
            timestamp: "00:00:0\(Int(start))",
            audioStartTime: start,
            audioEndTime: start + 2
        )
    }

    /// Seeds a meeting with one linked participant and one transcript line, and returns a
    /// `PersonExtraction` wired to a `StubLLMClient` returning `cannedResponse`.
    private func makeExtraction(
        db: AppDatabase,
        cannedResponse: String,
        summaryModelConfigValue: SummaryModelConfig? = SummaryModelConfig(
            providerKey: "claude",
            model: "claude-3-5-sonnet"
        )
    ) -> PersonExtraction {
        PersonExtraction(
            db: db,
            settings: StubSettingsReading(summaryModelConfigValue: summaryModelConfigValue),
            secrets: StubSecretsReading(apiKeys: ["claude": "test-key"]),
            clientFactory: { _ in StubLLMClient(kind: .claude, cannedResponse: cannedResponse) }
        )
    }

    private func seedMeetingWithParticipant(db: AppDatabase) async throws -> (Meeting, Person) {
        let meeting = makeMeeting()
        try await db.meetings.upsert(meeting)
        let sarah = makePerson(id: "person-sarah", email: "sarah@example.com", name: "Sarah")
        try await db.persons.upsert(sarah)
        try await db.persons.addParticipant(meetingId: meeting.id, personId: sarah.id)
        try await db.transcripts.upsert(makeTranscript(
            id: "t1", meetingId: meeting.id, text: "I want to ship v2 by Q3.", start: 0
        ))
        return (meeting, sarah)
    }

    // MARK: - Happy path

    @Test("A canned JSON array creates pending facts, each with evidence + an origin source row")
    func createsPendingFactsWithEvidence() async throws {
        let db = try AppDatabase.makeInMemory()
        let (meeting, sarah) = try await seedMeetingWithParticipant(db: db)

        let canned = """
        [{"person_email": "sarah@example.com", "person_name": "Sarah", "fact_kind": "goal", \
        "source_kind": "self_reported", "confidence": 0.8, \
        "fact_text": "Wants to ship v2 by Q3", "evidence": "I want to ship v2 by Q3."}]
        """
        let extraction = makeExtraction(db: db, cannedResponse: canned)

        let result = try await extraction.extractFacts(forMeeting: meeting.id)
        #expect(result.created == 1)

        let facts = try await db.profileFacts.activeFacts(for: sarah.id) // none active yet (all pending)
        #expect(facts.isEmpty)

        let all = try await db.profileFacts.all()
        #expect(all.count == 1)
        let fact = try #require(all.first)
        #expect(fact.personId == sarah.id)
        #expect(fact.status == .pending)
        #expect(fact.sourceSegmentRef == "I want to ship v2 by Q3.")
        #expect(fact.sourceMeetingId == meeting.id)
        #expect(fact.factKind == .goal)
        #expect(fact.origin == .selfReported)

        let withProvenance = try await db.profileFacts.withProvenance(fact.id)
        #expect(withProvenance?.sources.count == 1)
        #expect(withProvenance?.sources.first?.relation == .origin)
    }

    @Test("Multiple canned items create multiple facts")
    func createsMultipleFacts() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting()
        try await db.meetings.upsert(meeting)
        let sarah = makePerson(id: "person-sarah", email: "sarah@example.com", name: "Sarah")
        let bob = makePerson(id: "person-bob", email: "bob@example.com", name: "Bob")
        try await db.persons.upsert(sarah)
        try await db.persons.upsert(bob)
        try await db.persons.addParticipant(meetingId: meeting.id, personId: sarah.id)
        try await db.persons.addParticipant(meetingId: meeting.id, personId: bob.id)
        try await db.transcripts.upsert(makeTranscript(
            id: "t1", meetingId: meeting.id, text: "Sarah: I like hiking. Bob: I'm leading the API project.", start: 0
        ))

        let canned = """
        [
          {"person_email": "sarah@example.com", "person_name": "Sarah", "fact_kind": "interest", \
           "source_kind": "self_reported", "confidence": 0.6, "fact_text": "Likes hiking", \
           "evidence": "I like hiking."},
          {"person_email": "bob@example.com", "person_name": "Bob", "fact_kind": "project", \
           "source_kind": "self_reported", "confidence": 0.9, "fact_text": "Leads the API project", \
           "evidence": "I'm leading the API project."}
        ]
        """
        let extraction = makeExtraction(db: db, cannedResponse: canned)
        let result = try await extraction.extractFacts(forMeeting: meeting.id)
        #expect(result.created == 2)
        #expect(try await db.profileFacts.all().count == 2)
    }

    @Test("An item that can't be resolved to a known participant is skipped, never guessed")
    func unresolvedItemIsSkipped() async throws {
        let db = try AppDatabase.makeInMemory()
        let (meeting, _) = try await seedMeetingWithParticipant(db: db)

        let canned = """
        [{"person_email": "stranger@example.com", "person_name": "Stranger", "fact_kind": "goal", \
        "source_kind": "attributed", "confidence": 0.5, "fact_text": "Unattributable", \
        "evidence": "someone said something"}]
        """
        let extraction = makeExtraction(db: db, cannedResponse: canned)
        let result = try await extraction.extractFacts(forMeeting: meeting.id)
        #expect(result.created == 0)
        #expect(try await db.profileFacts.all().isEmpty)
    }

    // MARK: - Degrade-gracefully (never throws)

    @Test("No linked participants degrades to created: 0")
    func noParticipantsDegrades() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting()
        try await db.meetings.upsert(meeting)

        let extraction = makeExtraction(db: db, cannedResponse: "[]")
        let result = try await extraction.extractFacts(forMeeting: meeting.id)
        #expect(result.created == 0)
        #expect(!result.message.isEmpty)
    }

    @Test("Empty transcript text degrades to created: 0")
    func emptyTranscriptDegrades() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting()
        try await db.meetings.upsert(meeting)
        let sarah = makePerson(id: "person-sarah", email: "sarah@example.com", name: "Sarah")
        try await db.persons.upsert(sarah)
        try await db.persons.addParticipant(meetingId: meeting.id, personId: sarah.id)
        // No transcript rows at all.

        let extraction = makeExtraction(db: db, cannedResponse: "[]")
        let result = try await extraction.extractFacts(forMeeting: meeting.id)
        #expect(result.created == 0)
    }

    @Test("Unconfigured provider (no summaryModelConfig) degrades to created: 0")
    func unconfiguredProviderDegrades() async throws {
        let db = try AppDatabase.makeInMemory()
        let (meeting, _) = try await seedMeetingWithParticipant(db: db)

        let extraction = makeExtraction(db: db, cannedResponse: "[]", summaryModelConfigValue: nil)
        let result = try await extraction.extractFacts(forMeeting: meeting.id)
        #expect(result.created == 0)
    }

    @Test("An unparseable-provider key degrades to created: 0 (never throws)")
    func unparseableProviderKeyDegrades() async throws {
        let db = try AppDatabase.makeInMemory()
        let (meeting, _) = try await seedMeetingWithParticipant(db: db)

        let extraction = makeExtraction(
            db: db,
            cannedResponse: "[]",
            summaryModelConfigValue: SummaryModelConfig(providerKey: "not-a-real-provider", model: "whatever")
        )
        let result = try await extraction.extractFacts(forMeeting: meeting.id)
        #expect(result.created == 0)
    }

    @Test("Missing API key degrades to created: 0 (never throws)")
    func missingAPIKeyDegrades() async throws {
        let db = try AppDatabase.makeInMemory()
        let (meeting, _) = try await seedMeetingWithParticipant(db: db)

        let extraction = PersonExtraction(
            db: db,
            settings: StubSettingsReading(
                summaryModelConfigValue: SummaryModelConfig(providerKey: "claude", model: "claude-3-5-sonnet")
            ),
            secrets: StubSecretsReading(apiKeys: [:]),
            clientFactory: { _ in StubLLMClient(kind: .claude) }
        )
        let result = try await extraction.extractFacts(forMeeting: meeting.id)
        #expect(result.created == 0)
    }

    @Test("Unparseable model response degrades to created: 0")
    func unparseableModelResponseDegrades() async throws {
        let db = try AppDatabase.makeInMemory()
        let (meeting, _) = try await seedMeetingWithParticipant(db: db)

        let extraction = makeExtraction(db: db, cannedResponse: "not json at all")
        let result = try await extraction.extractFacts(forMeeting: meeting.id)
        #expect(result.created == 0)
        #expect(try await db.profileFacts.all().isEmpty)
    }

    @Test("An empty JSON array degrades to created: 0")
    func emptyArrayDegrades() async throws {
        let db = try AppDatabase.makeInMemory()
        let (meeting, _) = try await seedMeetingWithParticipant(db: db)

        let extraction = makeExtraction(db: db, cannedResponse: "[]")
        let result = try await extraction.extractFacts(forMeeting: meeting.id)
        #expect(result.created == 0)
    }

    @Test("A code-fenced JSON response is parsed correctly")
    func codeFencedResponseIsParsed() async throws {
        let db = try AppDatabase.makeInMemory()
        let (meeting, sarah) = try await seedMeetingWithParticipant(db: db)

        let canned = """
        ```json
        [{"person_email": "sarah@example.com", "person_name": "Sarah", "fact_kind": "goal", \
        "source_kind": "self_reported", "confidence": 0.8, \
        "fact_text": "Wants to ship v2 by Q3", "evidence": "I want to ship v2 by Q3."}]
        ```
        """
        let extraction = makeExtraction(db: db, cannedResponse: canned)
        let result = try await extraction.extractFacts(forMeeting: meeting.id)
        #expect(result.created == 1)
        let facts = try await db.profileFacts.all()
        #expect(facts.first?.personId == sarah.id)
    }
}
