//
//  ProfileFactSourceRecord.swift — GRDB record for the `profileFactSource` table (plan §4.6).
//
//  Store-internal only — `ProfileFactRepository` translates to/from the public
//  `AriKit.Models.ProfileFactSource` value type.
//
//  ⚠️ Tombstone columns (`isDeleted`/`deletedAt`) exist on this table even though the plan's
//  §4.6 table listing for `profileFactSource` doesn't enumerate them — this slice folds
//  tombstones into every table it creates (the plan's step 7 done per-table rather than as a
//  separate later pass, as already done for the foundation-slice tables). A documented deviation
//  from §4.6's literal column list, not from the tombstone invariant itself.
//
//  ⚠️ `meetingTitle` is NOT a column (plan §4.6 / §0.1 No-Fake-State): computed at read time by
//  `ProfileFactRepository` via a join against `meeting.title`, matching `ProfileFact
//  .sourceMeetingTitle`'s treatment. `asModel(meetingTitle:)` takes it as a repository-supplied
//  parameter; there is no zero-argument `asModel()` on this record.
//
import Foundation
import GRDB

struct ProfileFactSourceRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "profileFactSource"

    var id: String
    var factId: String
    var meetingId: String?
    var segmentRef: String?
    var origin: String
    var relation: String
    var confidence: Double
    var observedAt: Date
    var isDeleted: Bool
    var deletedAt: Date?
}

extension ProfileFactSourceRecord {
    init(_ source: ProfileFactSource) {
        id = source.id.rawValue
        factId = source.factId.rawValue
        meetingId = source.meetingId?.rawValue
        segmentRef = source.segmentRef
        origin = source.origin.rawValue
        relation = source.relation.rawValue
        confidence = source.confidence
        observedAt = source.observedAt
        isDeleted = false
        deletedAt = nil
    }

    /// See file header: `meetingTitle` is read-time-computed, always supplied by the repository.
    func asModel(meetingTitle: String?) -> ProfileFactSource {
        ProfileFactSource(
            id: ProfileFactSourceID(id),
            factId: ProfileFactID(factId),
            meetingId: meetingId.map { MeetingID($0) },
            meetingTitle: meetingTitle,
            segmentRef: segmentRef,
            origin: FactOrigin(rawValue: origin) ?? FactOrigin.unknownCase(origin),
            relation: FactSourceRelation(rawValue: relation) ?? FactSourceRelation.unknownCase(relation),
            confidence: confidence,
            observedAt: observedAt
        )
    }
}
