//
//  PersonDetailViewModelTests.swift — resolve; reverse-meetings; voiceprint; fact bucketing;
//  identity save; manual add; provenance (docs/plans/people-view-parity.md §5 test 15).
//
import Foundation
import Testing
@testable import AriKit
@testable import AriViewModels

@Suite("PersonDetailViewModel")
@MainActor
struct PersonDetailViewModelTests {

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("resolves an authored person")
    func resolvesPerson() async throws {
        let database = try AppDatabase.makeInMemory()
        let personId: PersonID = "person-1"
        let person = Person(
            id: personId, displayName: "Ada Lovelace", isOwner: false,
            createdAt: Self.now, updatedAt: Self.now
        )
        try await database.persons.upsert(person)

        let viewModel = PersonDetailViewModel(database: database)
        await viewModel.load(personId)

        #expect(viewModel.person.value?.id == personId)
        #expect(viewModel.person.value?.displayName == "Ada Lovelace")
    }

    @Test("honest failed when the person does not exist")
    func honestFailedOnMissingPerson() async throws {
        let database = try AppDatabase.makeInMemory()
        let viewModel = PersonDetailViewModel(database: database)
        await viewModel.load("does-not-exist")

        guard case .failed = viewModel.person else {
            Issue.record("expected .failed, got \(viewModel.person)")
            return
        }
    }

    @Test("participantMeetings/meetingCount reflect the real reverse query")
    func reverseMeetingsQuery() async throws {
        let database = try AppDatabase.makeInMemory()
        let personId: PersonID = "person-2"
        let person = Person(
            id: personId, displayName: "Ada Lovelace", isOwner: false,
            createdAt: Self.now, updatedAt: Self.now
        )
        try await database.persons.upsert(person)

        let meetingId: MeetingID = "meeting-1"
        let meeting = Meeting(id: meetingId, title: "1:1", createdAt: Self.now, updatedAt: Self.now)
        try await database.meetings.upsert(meeting)
        try await database.persons.addParticipant(meetingId: meetingId, personId: personId)

        let viewModel = PersonDetailViewModel(database: database)
        await viewModel.load(personId)

        #expect(viewModel.participantMeetings.map(\.id) == [meetingId])
        #expect(viewModel.meetingCount == 1)
    }

    @Test("no voiceprint yet — signature stays nil")
    func noVoiceprintStaysNil() async throws {
        let database = try AppDatabase.makeInMemory()
        let personId: PersonID = "person-3"
        let person = Person(
            id: personId, displayName: "Grace Hopper", isOwner: false,
            createdAt: Self.now, updatedAt: Self.now
        )
        try await database.persons.upsert(person)

        let viewModel = PersonDetailViewModel(database: database)
        await viewModel.load(personId)

        #expect(viewModel.signature == nil)
    }

    @Test("enrolled canonical speaker resolves to a real signature")
    func enrolledSignatureResolves() async throws {
        let database = try AppDatabase.makeInMemory()
        let personId: PersonID = "person-4"
        let person = Person(
            id: personId, displayName: "Grace Hopper", isOwner: false,
            createdAt: Self.now, updatedAt: Self.now
        )
        try await database.persons.upsert(person)

        let embedding = (0 ..< 192).map { Float($0) }
        let centroid = CentroidCodec.data(from: embedding)
        let speaker = Speaker(
            id: "speaker-1",
            personId: personId,
            centroid: centroid,
            embeddingModel: "test-model",
            dim: embedding.count,
            samples: 4,
            enrollmentState: .confirmed,
            totalSpeechSecs: 30,
            createdAt: Self.now,
            updatedAt: Self.now
        )
        try await database.speakers.upsert(speaker)

        let viewModel = PersonDetailViewModel(database: database)
        await viewModel.load(personId)

        #expect(viewModel.signature != nil)
        #expect(viewModel.signature?.count == 32)
    }

    @Test("fact buckets: pending / needsReview / active / others")
    func factBucketing() async throws {
        let database = try AppDatabase.makeInMemory()
        let personId: PersonID = "person-5"
        let person = Person(
            id: personId, displayName: "Ada Lovelace", isOwner: false,
            createdAt: Self.now, updatedAt: Self.now
        )
        try await database.persons.upsert(person)

        // `factsNeedingReview` measures staleness against the real wall clock, so these must be
        // relative to `Date()` (not the fixed `Self.now` epoch used elsewhere in this suite).
        let staleDate = Date().addingTimeInterval(-40 * 86400)
        let freshDate = Date()

        let pending = ProfileFact(
            id: "fact-pending", personId: personId, factText: "Pending fact", factKind: .other,
            origin: .attributed, confidence: 0.5, sourceCount: 0, status: .pending, createdAt: freshDate
        )
        let staleActive = ProfileFact(
            id: "fact-stale", personId: personId, factText: "Stale active fact", factKind: .goal,
            origin: .attributed, confidence: 0.8, sourceCount: 1, status: .active, createdAt: staleDate
        )
        let freshActive = ProfileFact(
            id: "fact-fresh", personId: personId, factText: "Fresh active fact", factKind: .interest,
            origin: .selfReported, confidence: 0.9, sourceCount: 1, status: .active, createdAt: freshDate
        )
        let rejected = ProfileFact(
            id: "fact-rejected", personId: personId, factText: "Rejected fact", factKind: .other,
            origin: .attributed, confidence: 0.5, sourceCount: 0, status: .rejected, createdAt: freshDate
        )

        try await database.profileFacts.upsert(pending)
        try await database.profileFacts.upsert(staleActive)
        try await database.profileFacts.upsert(freshActive)
        try await database.profileFacts.upsert(rejected)

        let viewModel = PersonDetailViewModel(database: database)
        await viewModel.load(personId)

        #expect(viewModel.pendingFacts.map(\.id) == [pending.id])
        #expect(viewModel.needsReviewFacts.map(\.id) == [staleActive.id])
        #expect(viewModel.activeFacts.map(\.id) == [freshActive.id])
        #expect(viewModel.otherFacts.map(\.id) == [rejected.id])
    }

    @Test("saveIdentity no-ops on empty name, preserves isOwner")
    func saveIdentityGuards() async throws {
        let database = try AppDatabase.makeInMemory()
        let personId: PersonID = "person-6"
        let person = Person(
            id: personId, email: "old@example.com", displayName: "Original Name",
            isOwner: true, createdAt: Self.now, updatedAt: Self.now
        )
        try await database.persons.upsert(person)

        let viewModel = PersonDetailViewModel(database: database)
        await viewModel.load(personId)

        let emptyNameError = await viewModel.saveIdentity(
            name: "   ", email: "new@example.com", role: nil, domain: nil, notes: nil
        )
        #expect(emptyNameError != nil)
        #expect(viewModel.person.value?.displayName == "Original Name")
        #expect(viewModel.person.value?.email == "old@example.com")

        // Email is read-only once set: the incoming "new@example.com" is ignored, the rest saves.
        let error = await viewModel.saveIdentity(
            name: "New Name", email: "new@example.com", role: "Engineer", domain: "Platform", notes: "Notes"
        )
        #expect(error == nil)
        #expect(viewModel.person.value?.displayName == "New Name")
        #expect(viewModel.person.value?.email == "old@example.com")
        #expect(viewModel.person.value?.role == "Engineer")
        #expect(viewModel.person.value?.isOwner == true)
        #expect(viewModel.person.value?.id == personId)
    }

    @Test("saveIdentity rejects a non-email when first setting the email key")
    func saveIdentityRejectsInvalidEmail() async throws {
        let database = try AppDatabase.makeInMemory()
        let personId: PersonID = "person-6b"
        // No email set yet — the field is editable, so validation applies.
        let person = Person(
            id: personId, displayName: "ryan.chadwick@arivo.com", isOwner: false,
            createdAt: Self.now, updatedAt: Self.now
        )
        try await database.persons.upsert(person)

        let viewModel = PersonDetailViewModel(database: database)
        await viewModel.load(personId)

        // The exact incident: a display name typed into the email field must be rejected, not stored.
        let error = await viewModel.saveIdentity(
            name: "Ryan Chadwick", email: "Ryan Chadwick", role: "Group Product Manager",
            domain: nil, notes: nil
        )
        #expect(error != nil)
        #expect(viewModel.person.value?.email == nil)
        #expect(viewModel.person.value?.role != "Group Product Manager") // whole save rejected
    }

    @Test("saveIdentity normalizes a valid email when first set (trim + lowercase)")
    func saveIdentityNormalizesEmail() async throws {
        let database = try AppDatabase.makeInMemory()
        let personId: PersonID = "person-6c"
        let person = Person(
            id: personId, displayName: "Ryan", isOwner: false,
            createdAt: Self.now, updatedAt: Self.now
        )
        try await database.persons.upsert(person)

        let viewModel = PersonDetailViewModel(database: database)
        await viewModel.load(personId)

        let error = await viewModel.saveIdentity(
            name: "Ryan", email: "  Ryan.Chadwick@Arivo.com ", role: nil, domain: nil, notes: nil
        )
        #expect(error == nil)
        #expect(viewModel.person.value?.email == "ryan.chadwick@arivo.com")
    }

    @Test("addManualFact lands active")
    func addManualFactLandsActive() async throws {
        let database = try AppDatabase.makeInMemory()
        let personId: PersonID = "person-7"
        let person = Person(
            id: personId, displayName: "Ada Lovelace", isOwner: false,
            createdAt: Self.now, updatedAt: Self.now
        )
        try await database.persons.upsert(person)

        let viewModel = PersonDetailViewModel(database: database)
        await viewModel.load(personId)

        await viewModel.addManualFact(text: "Leads the migration project", kind: .project)

        #expect(viewModel.activeFacts.count == 1)
        #expect(viewModel.activeFacts.first?.factText == "Leads the migration project")
        #expect(viewModel.activeFacts.first?.origin == .attributed)
        #expect(viewModel.activeFacts.first?.confidence == 1.0)

        // Blank text is a no-op.
        await viewModel.addManualFact(text: "   ", kind: .other)
        #expect(viewModel.activeFacts.count == 1)
    }

    @Test("provenance(for:) returns real sources, never fabricated")
    func provenanceIsReal() async throws {
        let database = try AppDatabase.makeInMemory()
        let personId: PersonID = "person-8"
        let person = Person(
            id: personId, displayName: "Ada Lovelace", isOwner: false,
            createdAt: Self.now, updatedAt: Self.now
        )
        try await database.persons.upsert(person)

        let fact = ProfileFact(
            id: "fact-with-source", personId: personId, factText: "Has a source", factKind: .other,
            origin: .attributed, confidence: 0.7, sourceCount: 0, status: .active, createdAt: Self.now
        )
        try await database.profileFacts.upsert(fact)
        try await database.profileFacts.recordSource(ProfileFactSource(
            id: "source-1", factId: fact.id, origin: .attributed, relation: .origin,
            confidence: 0.7, observedAt: Self.now
        ))

        let viewModel = PersonDetailViewModel(database: database)
        await viewModel.load(personId)

        let provenance = await viewModel.provenance(for: fact.id)
        #expect(provenance?.sources.count == 1)
        #expect(provenance?.sources.first?.id == "source-1")

        // A fact with no recorded sources returns an empty (never fabricated) lineage.
        let unsourced = ProfileFact(
            id: "fact-no-source", personId: personId, factText: "No source", factKind: .other,
            origin: .attributed, confidence: 1.0, sourceCount: 0, status: .active, createdAt: Self.now
        )
        try await database.profileFacts.upsert(unsourced)
        let emptyProvenance = await viewModel.provenance(for: unsourced.id)
        #expect(emptyProvenance?.sources.isEmpty == true)
    }
}
