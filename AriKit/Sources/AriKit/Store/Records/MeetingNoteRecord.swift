//
//  MeetingNoteRecord.swift — GRDB record for the `meetingNote` table (plan §4.12).
//
//  Store-internal only — `MeetingNoteRepository` translates to/from the public
//  `AriKit.Models.MeetingNote` value type. The primary key is `meetingId` itself, matching the
//  legacy `meeting_notes` row shape exactly (see `Models/MeetingNote.swift`'s header) — there is
//  no separate synthetic `id` column here.
//
import Foundation
import GRDB

struct MeetingNoteRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "meetingNote"

    var meetingId: String
    var notesMarkdown: String?
    var notesJson: String?
    var createdAt: Date
    var updatedAt: Date
    var isDeleted: Bool
    var deletedAt: Date?
}

extension MeetingNoteRecord {
    init(_ note: MeetingNote) {
        meetingId = note.meetingId.rawValue
        notesMarkdown = note.notesMarkdown
        notesJson = note.notesJson
        createdAt = note.createdAt
        updatedAt = note.updatedAt
        isDeleted = false
        deletedAt = nil
    }

    func asModel() -> MeetingNote {
        MeetingNote(
            meetingId: MeetingID(meetingId),
            notesMarkdown: notesMarkdown,
            notesJson: notesJson,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
