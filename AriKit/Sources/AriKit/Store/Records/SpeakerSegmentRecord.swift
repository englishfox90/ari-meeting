//
//  SpeakerSegmentRecord.swift — GRDB record for the `speakerSegment` table (plan §4.4).
//
//  Store-internal only — `SpeakerSegmentRepository` translates to/from the public
//  `AriKit.Models.SpeakerSegment` value type. `source` is stored as its raw `String`; unknown
//  raws round-trip losslessly through `SegmentSource`'s `UnknownTolerantEnum` conformance.
//
//  No `isDeleted`/`deletedAt` here — §4.4 does not list tombstone columns for this table; they
//  land for every table in step 7 (docs/plans/arikit-store.md §10).
//
import Foundation
import GRDB

struct SpeakerSegmentRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "speakerSegment"

    var id: String
    var meetingId: String
    var speakerId: String?
    var clusterKey: String
    var startTime: Double
    var endTime: Double
    var source: String
    var embedding: Data?
    var createdAt: Date
}

extension SpeakerSegmentRecord {
    init(_ segment: SpeakerSegment) {
        id = segment.id.rawValue
        meetingId = segment.meetingId.rawValue
        speakerId = segment.speakerId?.rawValue
        clusterKey = segment.clusterKey
        startTime = segment.startTime
        endTime = segment.endTime
        source = segment.source.rawValue
        embedding = segment.embedding
        createdAt = segment.createdAt
    }

    func asModel() -> SpeakerSegment {
        SpeakerSegment(
            id: SpeakerSegmentID(id),
            meetingId: MeetingID(meetingId),
            speakerId: speakerId.map { SpeakerID($0) },
            clusterKey: clusterKey,
            startTime: startTime,
            endTime: endTime,
            source: SegmentSource(rawValue: source) ?? SegmentSource.unknownCase(source),
            embedding: embedding,
            createdAt: createdAt
        )
    }
}
