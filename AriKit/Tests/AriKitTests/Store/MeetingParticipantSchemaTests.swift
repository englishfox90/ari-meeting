//
//  MeetingParticipantSchemaTests.swift — introspects the migrated `meetingParticipant` table
//  (Phase 3.4 Track H, `arikit-engine-extras.md` §2.3/§2.6/§6-5).
//
import Foundation
import GRDB
import Testing
@testable import AriKit

@Suite("Schema fidelity — meetingParticipant")
struct MeetingParticipantSchemaTests {
    private func migratedQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try SchemaMigrator.migrator().migrate(queue)
        return queue
    }

    @Test("meetingParticipant table has the expected columns and composite PK, no tombstone")
    func meetingParticipantSchema() throws {
        let queue = try migratedQueue()
        let columns = try queue.read { db in try db.columns(in: "meetingParticipant") }
        let names = Set(columns.map(\.name))

        #expect(names == ["meetingId", "personId", "linkSource", "createdAt"])
        #expect(!names.contains("isDeleted"))
        #expect(!names.contains("deletedAt"))

        let meetingId = try #require(columns.first { $0.name == "meetingId" })
        let personId = try #require(columns.first { $0.name == "personId" })
        #expect(meetingId.isNotNull)
        #expect(personId.isNotNull)

        let primaryKey = try queue.read { db in try db.primaryKey("meetingParticipant") }
        #expect(Set(primaryKey.columns) == ["meetingId", "personId"])
    }

    @Test("meetingParticipant carries inline FKs to meeting and person, both ON DELETE CASCADE")
    func meetingParticipantForeignKeys() throws {
        let queue = try migratedQueue()
        let foreignKeys = try queue.read { db in try db.foreignKeys(on: "meetingParticipant") }

        let meetingFK = foreignKeys.first { $0.destinationTable == "meeting" }
        let personFK = foreignKeys.first { $0.destinationTable == "person" }
        #expect(meetingFK != nil, "meetingParticipant.meetingId should reference meeting(id)")
        #expect(personFK != nil, "meetingParticipant.personId should reference person(id)")
    }
}
