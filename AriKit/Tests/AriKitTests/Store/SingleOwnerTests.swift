//
//  SingleOwnerTests.swift — the single-DB-owner discipline (plan principle 3 / §7 test 6).
//
//  Honest about what SQLite can and cannot enforce: SQLite itself permits multiple connections to
//  one file across processes by design, so this suite does NOT claim GRDB prevents a second
//  connection. What it encodes is the APPLICATION-LEVEL invariant the design rests on: `AppDatabase`
//  is the one vending point for repositories, every repository it hands out reads/writes the SAME
//  underlying store (one owner), and two separately-constructed stores are independent (each file
//  has its own owner — the shape the importer relies on: Rust owns its file, Swift owns a different
//  one).
//
import Foundation
import Testing
@testable import AriKit

@Suite("Store single-owner discipline")
struct SingleOwnerTests {

    @Test("All repositories vended by one AppDatabase share the same underlying store")
    func repositoriesShareOneOwner() async throws {
        let store = try AppDatabase.makeInMemory()

        // A write through one repository accessor is visible through a freshly-vended accessor of
        // the same type — proving they are not independent connections with divergent state.
        let meeting = ModelSamples.meeting
        try await store.meetings.upsert(meeting)

        let viaFreshAccessor = try await store.meetings.find(meeting.id)
        #expect(viaFreshAccessor?.id == meeting.id)

        // A cross-repository FK write also resolves within the same owner (person → speaker).
        try await store.persons.upsert(ModelSamples.person)
        try await store.speakers.upsert(ModelSamples.speaker)
        #expect(try await store.speakers.find(ModelSamples.speaker.id) != nil)
    }

    @Test("Two separately-constructed stores are independent owners (distinct files)")
    func separateStoresAreIndependent() async throws {
        let storeA = try AppDatabase.makeInMemory()
        let storeB = try AppDatabase.makeInMemory()

        try await storeA.meetings.upsert(ModelSamples.meeting)

        // storeB never received the write — it owns its own (in-memory) file, mirroring the
        // Rust-owns-its-file / Swift-owns-its-file separation the importer depends on.
        #expect(try await storeB.meetings.all().isEmpty)
        #expect(try await storeA.meetings.all().count == 1)
    }
}
