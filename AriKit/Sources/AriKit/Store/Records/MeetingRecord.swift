//
//  MeetingRecord.swift — GRDB record for the `meeting` table (plan §4.1).
//
//  Store-internal only (not `public`) — `MeetingRepository` is the sole translator between this
//  record and the public `AriKit.Models.Meeting` value type. Feature code never sees this type.
//
//  ⚠️ `templateId` exists as a schema column (§4.1) but `Meeting` (AriKit.Models, ported
//  2026-07-17) carries no `templateId` field yet — that's a Models-layer follow-on out of scope
//  for this slice (steps 3–10 are excluded here). The column is always persisted as `NULL` from
//  this slice and is not part of the `asModel()`/`init(_:)` round trip; wire it up when template
//  selection lands in `Models`.
//
import Foundation
import GRDB

struct MeetingRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "meeting"

    var id: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var audioReferencePath: String?
    var transcriptionProvider: String?
    var transcriptionModel: String?
    var summaryProvider: String?
    var summaryModel: String?
    var templateId: String?
    var isDeleted: Bool
    var deletedAt: Date?
}

extension MeetingRecord {
    init(_ meeting: Meeting) {
        id = meeting.id.rawValue
        title = meeting.title
        createdAt = meeting.createdAt
        updatedAt = meeting.updatedAt
        audioReferencePath = meeting.audioReference?.path
        transcriptionProvider = meeting.transcriptionProvider
        transcriptionModel = meeting.transcriptionModel
        summaryProvider = meeting.summaryProvider
        summaryModel = meeting.summaryModel
        templateId = nil
        isDeleted = false
        deletedAt = nil
    }

    func asModel() -> Meeting {
        Meeting(
            id: MeetingID(id),
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            audioReference: audioReferencePath.map(LocalAudioReference.init(path:)),
            transcriptionProvider: transcriptionProvider,
            transcriptionModel: transcriptionModel,
            summaryProvider: summaryProvider,
            summaryModel: summaryModel
        )
    }
}
