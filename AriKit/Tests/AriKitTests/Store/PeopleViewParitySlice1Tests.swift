//
//  PeopleViewParitySlice1Tests.swift — Slice 1 repository-surface coverage
//  (`docs/plans/people-view-parity.md` §2.1, §5 tests 1–8): `PersonRepository.meetings(forPerson:)`
//  / `.upsertStubFromAttendee`, `ProfileFactRepository.confirmFact`/`.rejectFact`/`.addManualFact`/
//  `.pendingFactsAll`/`.factCounts`, `SpeakerRepository.canonicalEnrolledSpeaker`/`.listCanonicalEnrolled`.
//
import Foundation
import Testing
@testable import AriKit

@Suite("People view parity — Slice 1 repository surface")
struct PeopleViewParitySlice1Tests {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Fixtures

    private func person(
        id: PersonID,
        email: String? = nil,
        displayName: String = "Someone",
        role: String? = nil,
        notes: String? = nil,
        isOwner: Bool = false
    ) -> Person {
        Person(
            id: id, email: email, displayName: displayName, role: role, notes: notes,
            isOwner: isOwner, createdAt: base, updatedAt: base
        )
    }

    private func meeting(id: MeetingID, createdAt: Date) -> Meeting {
        Meeting(id: id, title: "Meeting \(id.rawValue)", createdAt: createdAt, updatedAt: createdAt)
    }

    private func fact(
        id: ProfileFactID,
        personId: PersonID,
        factText: String = "Likes coffee",
        factKind: FactKind = .interest,
        origin: FactOrigin = .attributed,
        confidence: Double = 0.7,
        status: FactStatus = .pending,
        sourceMeetingId: MeetingID? = nil,
        createdAt: Date? = nil
    ) -> ProfileFact {
        ProfileFact(
            id: id, personId: personId, factText: factText, factKind: factKind,
            sourceMeetingId: sourceMeetingId, origin: origin, confidence: confidence,
            sourceCount: 0, status: status, createdAt: createdAt ?? base
        )
    }

    private func speaker(
        id: SpeakerID,
        personId: PersonID?,
        enrollmentState: EnrollmentState,
        totalSpeechSecs: Double = 0,
        samples: Int = 0
    ) -> Speaker {
        Speaker(
            id: id, personId: personId, centroid: Data([0, 1, 2, 3]), embeddingModel: "test-model",
            dim: 4, samples: samples, enrollmentState: enrollmentState, totalSpeechSecs: totalSpeechSecs,
            createdAt: base, updatedAt: base
        )
    }

    // MARK: - 1. PersonRepository.meetings(forPerson:)

    @Test("meetings(forPerson:) returns only that person's non-deleted meetings, newest first")
    func meetingsForPersonReturnsOnlyLinkedNonDeleted() async throws {
        let db = try AppDatabase.makeInMemory()
        let personId: PersonID = "person-1"
        let otherPersonId: PersonID = "person-2"
        try await db.persons.upsert(person(id: personId, displayName: "Alice"))
        try await db.persons.upsert(person(id: otherPersonId, displayName: "Bob"))

        let older: MeetingID = "meeting-older"
        let newer: MeetingID = "meeting-newer"
        let deleted: MeetingID = "meeting-deleted"
        let unlinked: MeetingID = "meeting-unlinked"
        try await db.meetings.upsert(meeting(id: older, createdAt: base))
        try await db.meetings.upsert(meeting(id: newer, createdAt: base.addingTimeInterval(3600)))
        try await db.meetings.upsert(meeting(id: deleted, createdAt: base.addingTimeInterval(7200)))
        try await db.meetings.upsert(meeting(id: unlinked, createdAt: base.addingTimeInterval(-3600)))
        try await db.meetings.softDelete(deleted, at: base)

        try await db.persons.addParticipant(meetingId: older, personId: personId)
        try await db.persons.addParticipant(meetingId: newer, personId: personId)
        try await db.persons.addParticipant(meetingId: deleted, personId: personId)
        try await db.persons.addParticipant(meetingId: unlinked, personId: otherPersonId)

        let result = try await db.persons.meetings(forPerson: personId)
        #expect(result.map(\.id) == [newer, older])
    }

    @Test("meetings(forPerson:) is empty when unlinked")
    func meetingsForPersonEmptyWhenUnlinked() async throws {
        let db = try AppDatabase.makeInMemory()
        let personId: PersonID = "person-1"
        try await db.persons.upsert(person(id: personId))

        let result = try await db.persons.meetings(forPerson: personId)
        #expect(result.isEmpty)
    }

    // MARK: - 2. PersonRepository.upsertStubFromAttendee

    @Test("upsertStubFromAttendee returns an existing person by email unchanged")
    func upsertStubFromAttendeeReturnsExistingUnchanged() async throws {
        let db = try AppDatabase.makeInMemory()
        let existingId: PersonID = "person-existing"
        try await db.persons.upsert(person(
            id: existingId, email: "Alice@Example.com", displayName: "Alice Authored",
            role: "Engineer", notes: "hand-authored notes"
        ))

        let result = try await db.persons.upsertStubFromAttendee(
            email: "alice@example.com", displayName: "Alice From Calendar", at: base
        )

        #expect(result.id == existingId)
        #expect(result.displayName == "Alice Authored")
        #expect(result.role == "Engineer")
        #expect(result.notes == "hand-authored notes")
        let all = try await db.persons.all()
        #expect(all.count == 1)
    }

    @Test("upsertStubFromAttendee creates a stub with no email, name resolution, and idempotency")
    func upsertStubFromAttendeeCreatesStubAndResolvesName() async throws {
        let db = try AppDatabase.makeInMemory()

        // name present -> use trimmed name
        let withName = try await db.persons.upsertStubFromAttendee(
            email: nil, displayName: "  Bob Jones  ", at: base
        )
        #expect(withName.displayName == "Bob Jones")
        #expect(withName.isOwner == false)
        #expect(withName.email == nil)
        #expect(withName.role == nil)

        // no name, has email -> local-part of email
        let withEmailOnly = try await db.persons.upsertStubFromAttendee(
            email: "carol@example.com", displayName: "", at: base
        )
        #expect(withEmailOnly.displayName == "carol")

        // no name, no email -> "Unknown"
        let withNeither = try await db.persons.upsertStubFromAttendee(
            email: nil, displayName: "   ", at: base
        )
        #expect(withNeither.displayName == "Unknown")

        // re-run with the same email is idempotent (returns same row, no duplicate)
        let again = try await db.persons.upsertStubFromAttendee(
            email: "carol@example.com", displayName: "Someone Else", at: base
        )
        #expect(again.id == withEmailOnly.id)
        #expect(again.displayName == "carol")

        let all = try await db.persons.all()
        #expect(all.count == 3)
    }

    // MARK: - 3. ProfileFactRepository.confirmFact

    @Test("confirmFact sets active + lastConfirmedAt, and retires a supersede target")
    func confirmFactActivatesAndRetiresSupersedeTarget() async throws {
        let db = try AppDatabase.makeInMemory()
        let personId: PersonID = "person-1"
        try await db.persons.upsert(person(id: personId))

        let oldFactId: ProfileFactID = "fact-old"
        let newFactId: ProfileFactID = "fact-new"
        try await db.profileFacts.upsert(fact(id: oldFactId, personId: personId, status: .active))
        try await db.profileFacts.upsert(fact(id: newFactId, personId: personId, status: .pending))
        try await db.profileFacts.markSupersedes(newFactId: newFactId, oldFactId: oldFactId)

        try await db.profileFacts.confirmFact(newFactId, at: base.addingTimeInterval(60))

        let confirmed = try #require(try await db.profileFacts.find(newFactId))
        #expect(confirmed.status == .active)

        let old = try #require(try await db.profileFacts.find(oldFactId))
        #expect(old.status == .superseded)
        #expect(old.supersededBy == newFactId)
    }

    @Test("confirmFact with no supersede target only activates the fact")
    func confirmFactWithoutSupersedeTarget() async throws {
        let db = try AppDatabase.makeInMemory()
        let personId: PersonID = "person-1"
        try await db.persons.upsert(person(id: personId))

        let factId: ProfileFactID = "fact-1"
        try await db.profileFacts.upsert(fact(id: factId, personId: personId, status: .pending))

        try await db.profileFacts.confirmFact(factId, at: base)

        let confirmed = try #require(try await db.profileFacts.find(factId))
        #expect(confirmed.status == .active)
    }

    // MARK: - 4. ProfileFactRepository.rejectFact

    @Test("rejectFact sets rejected and never retires a supersede target")
    func rejectFactDoesNotRetireSupersedeTarget() async throws {
        let db = try AppDatabase.makeInMemory()
        let personId: PersonID = "person-1"
        try await db.persons.upsert(person(id: personId))

        let oldFactId: ProfileFactID = "fact-old"
        let newFactId: ProfileFactID = "fact-new"
        try await db.profileFacts.upsert(fact(id: oldFactId, personId: personId, status: .active))
        try await db.profileFacts.upsert(fact(id: newFactId, personId: personId, status: .pending))
        try await db.profileFacts.markSupersedes(newFactId: newFactId, oldFactId: oldFactId)

        try await db.profileFacts.rejectFact(newFactId)

        let rejected = try #require(try await db.profileFacts.find(newFactId))
        #expect(rejected.status == .rejected)

        let old = try #require(try await db.profileFacts.find(oldFactId))
        #expect(old.status == .active)
        #expect(old.supersededBy == nil)
    }

    // MARK: - 5. ProfileFactRepository.addManualFact

    @Test("addManualFact creates an active, fully-attributed fact")
    func addManualFactCreatesActiveFact() async throws {
        let db = try AppDatabase.makeInMemory()
        let personId: PersonID = "person-1"
        try await db.persons.upsert(person(id: personId))

        let created = try await db.profileFacts.addManualFact(
            personId: personId, factText: "Owns a dog", factKind: .other, at: base
        )

        #expect(created.personId == personId)
        #expect(created.factText == "Owns a dog")
        #expect(created.factKind == .other)
        #expect(created.origin == .attributed)
        #expect(created.confidence == 1.0)
        #expect(created.status == .active)
        #expect(created.sourceMeetingId == nil)
        #expect(created.sourceCount == 0)

        let persisted = try #require(try await db.profileFacts.find(created.id))
        #expect(persisted.status == .active)
    }

    // MARK: - 6. ProfileFactRepository.pendingFactsAll

    @Test("pendingFactsAll returns every pending fact across persons with correct personDisplayName")
    func pendingFactsAllAcrossPersons() async throws {
        let db = try AppDatabase.makeInMemory()
        let alice: PersonID = "person-alice"
        let bob: PersonID = "person-bob"
        try await db.persons.upsert(person(id: alice, displayName: "Alice"))
        try await db.persons.upsert(person(id: bob, displayName: "Bob"))

        let alicePending: ProfileFactID = "fact-alice-pending"
        let bobPending: ProfileFactID = "fact-bob-pending"
        let aliceActive: ProfileFactID = "fact-alice-active"
        let deletedPending: ProfileFactID = "fact-deleted-pending"
        try await db.profileFacts.upsert(fact(id: alicePending, personId: alice, status: .pending))
        try await db.profileFacts.upsert(fact(id: bobPending, personId: bob, status: .pending))
        try await db.profileFacts.upsert(fact(id: aliceActive, personId: alice, status: .active))
        try await db.profileFacts.upsert(fact(id: deletedPending, personId: alice, status: .pending))
        try await db.profileFacts.softDelete(deletedPending, at: base)

        let result = try await db.profileFacts.pendingFactsAll()

        #expect(result.count == 2)
        let byId = Dictionary(uniqueKeysWithValues: result.map { ($0.fact.id, $0) })
        #expect(byId[alicePending]?.personDisplayName == "Alice")
        #expect(byId[alicePending]?.personId == alice)
        #expect(byId[bobPending]?.personDisplayName == "Bob")
    }

    // MARK: - 7. ProfileFactRepository.factCounts

    @Test("factCounts returns correct per-person (pending, active) counts")
    func factCountsPerPerson() async throws {
        let db = try AppDatabase.makeInMemory()
        let alice: PersonID = "person-alice"
        let bob: PersonID = "person-bob"
        try await db.persons.upsert(person(id: alice, displayName: "Alice"))
        try await db.persons.upsert(person(id: bob, displayName: "Bob"))

        try await db.profileFacts.upsert(fact(id: "fact-1", personId: alice, status: .pending))
        try await db.profileFacts.upsert(fact(id: "fact-2", personId: alice, status: .pending))
        try await db.profileFacts.upsert(fact(id: "fact-3", personId: alice, status: .active))
        try await db.profileFacts.upsert(fact(id: "fact-4", personId: bob, status: .active))
        try await db.profileFacts.upsert(fact(id: "fact-5", personId: alice, status: .rejected))
        let deleted: ProfileFactID = "fact-6"
        try await db.profileFacts.upsert(fact(id: deleted, personId: alice, status: .active))
        try await db.profileFacts.softDelete(deleted, at: base)

        let counts = try await db.profileFacts.factCounts()

        #expect(counts[alice]?.pending == 2)
        #expect(counts[alice]?.active == 1)
        #expect(counts[bob]?.pending == 0)
        #expect(counts[bob]?.active == 1)
    }

    // MARK: - 8. SpeakerRepository.canonicalEnrolledSpeaker / listCanonicalEnrolled

    @Test("canonicalEnrolledSpeaker prefers owner, then higher totalSpeechSecs, then higher samples")
    func canonicalEnrolledSpeakerOrdering() async throws {
        let db = try AppDatabase.makeInMemory()
        let personId: PersonID = "person-1"
        try await db.persons.upsert(person(id: personId))

        let confirmedWeak: SpeakerID = "speaker-confirmed-weak"
        let confirmedStrong: SpeakerID = "speaker-confirmed-strong"
        let ownerSpeaker: SpeakerID = "speaker-owner"
        let provisional: SpeakerID = "speaker-provisional"
        let unenrolledOther: SpeakerID = "speaker-other-person"
        try await db.speakers.upsert(speaker(
            id: confirmedWeak, personId: personId, enrollmentState: .confirmed,
            totalSpeechSecs: 10, samples: 1
        ))
        try await db.speakers.upsert(speaker(
            id: confirmedStrong, personId: personId, enrollmentState: .confirmed,
            totalSpeechSecs: 500, samples: 9
        ))
        try await db.speakers.upsert(speaker(
            id: ownerSpeaker, personId: personId, enrollmentState: .owner,
            totalSpeechSecs: 1, samples: 1
        ))
        try await db.speakers.upsert(speaker(
            id: provisional, personId: personId, enrollmentState: .provisional,
            totalSpeechSecs: 9999, samples: 99
        ))
        try await db.speakers.upsert(speaker(
            id: unenrolledOther, personId: nil, enrollmentState: .confirmed,
            totalSpeechSecs: 9999, samples: 99
        ))

        let result = try await db.speakers.canonicalEnrolledSpeaker(for: personId)
        #expect(result?.id == ownerSpeaker)
    }

    @Test("canonicalEnrolledSpeaker ignores deleted rows and returns nil when none enrolled")
    func canonicalEnrolledSpeakerIgnoresDeletedAndUnenrolled() async throws {
        let db = try AppDatabase.makeInMemory()
        let personId: PersonID = "person-1"
        try await db.persons.upsert(person(id: personId))

        let deletedOwner: SpeakerID = "speaker-deleted-owner"
        try await db.speakers.upsert(speaker(
            id: deletedOwner, personId: personId, enrollmentState: .owner, totalSpeechSecs: 100, samples: 5
        ))
        try await db.speakers.softDelete(deletedOwner, at: base)

        let onlyProvisional: SpeakerID = "speaker-provisional-only"
        try await db.speakers.upsert(speaker(
            id: onlyProvisional, personId: personId, enrollmentState: .provisional
        ))

        let result = try await db.speakers.canonicalEnrolledSpeaker(for: personId)
        #expect(result == nil)
    }

    @Test("listCanonicalEnrolled yields one row per person, preferring each person's canonical")
    func listCanonicalEnrolledOneRowPerPerson() async throws {
        let db = try AppDatabase.makeInMemory()
        let alice: PersonID = "person-alice"
        let bob: PersonID = "person-bob"
        try await db.persons.upsert(person(id: alice, displayName: "Alice"))
        try await db.persons.upsert(person(id: bob, displayName: "Bob"))

        try await db.speakers.upsert(speaker(
            id: "speaker-alice-weak", personId: alice, enrollmentState: .confirmed,
            totalSpeechSecs: 5, samples: 1
        ))
        try await db.speakers.upsert(speaker(
            id: "speaker-alice-owner", personId: alice, enrollmentState: .owner,
            totalSpeechSecs: 1, samples: 1
        ))
        try await db.speakers.upsert(speaker(
            id: "speaker-bob-confirmed", personId: bob, enrollmentState: .confirmed,
            totalSpeechSecs: 50, samples: 3
        ))

        let result = try await db.speakers.listCanonicalEnrolled()
        #expect(result.count == 2)
        let byPerson = Dictionary(uniqueKeysWithValues: result.compactMap { speaker in
            speaker.personId.map { ($0, speaker.id) }
        })
        #expect(byPerson[alice] == "speaker-alice-owner")
        #expect(byPerson[bob] == "speaker-bob-confirmed")
    }

    // MARK: - ensureOwner (owner-profile seeding)

    @Test("ensureOwner creates an owner from the default name when none exists")
    func ensureOwnerCreatesFromDefault() async throws {
        let db = try AppDatabase.makeInMemory()

        let owner = try await db.persons.ensureOwner(defaultDisplayName: "Paul Fox-Reeks", at: base)

        #expect(owner.isOwner)
        #expect(owner.displayName == "Paul Fox-Reeks")
        let fetched = try await db.persons.owner()
        #expect(fetched?.id == owner.id)
        #expect(try await db.persons.all().count == 1)
    }

    @Test("ensureOwner returns the existing owner unchanged and never creates a second")
    func ensureOwnerIsIdempotent() async throws {
        let db = try AppDatabase.makeInMemory()
        let existingId: PersonID = "owner-existing"
        try await db.persons.upsert(person(
            id: existingId, displayName: "Authored Owner", role: "VP", isOwner: true
        ))

        let result = try await db.persons.ensureOwner(defaultDisplayName: "Paul Fox-Reeks", at: base)

        #expect(result.id == existingId)
        #expect(result.displayName == "Authored Owner")
        #expect(result.role == "VP")
        #expect(try await db.persons.all().count == 1)
    }

    @Test("ensureOwner falls back to \"You\" when the default name is blank")
    func ensureOwnerBlankNameFallsBackToYou() async throws {
        let db = try AppDatabase.makeInMemory()

        let owner = try await db.persons.ensureOwner(defaultDisplayName: "   ", at: base)

        #expect(owner.displayName == "You")
        #expect(owner.isOwner)
    }
}
