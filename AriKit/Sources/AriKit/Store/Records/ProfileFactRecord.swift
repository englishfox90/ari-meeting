//
//  ProfileFactRecord.swift — GRDB record for the `profileFact` table (plan §4.6).
//
//  Store-internal only — `ProfileFactRepository` translates to/from the public
//  `AriKit.Models.ProfileFact` value type. `factKind`/`origin`/`status` are stored as their raw
//  `String`s; unknown raws round-trip losslessly through each enum's `UnknownTolerantEnum`
//  conformance.
//
//  ⚠️ `sourceMeetingTitle` and `sourceCount` are NOT columns on this record (plan §4.6 /
//  §0.1 No-Fake-State): they are computed at read time by `ProfileFactRepository` — a join
//  against `meeting.title` and a `COUNT(*)` over `profileFactSource`, respectively — never a
//  denormalized, driftable copy. `asModel(sourceMeetingTitle:sourceCount:)` takes both as
//  parameters the repository supplies; there is no zero-argument `asModel()` on this record.
//
import Foundation
import GRDB

struct ProfileFactRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "profileFact"

    var id: String
    var personId: String
    var factText: String
    var factKind: String
    var sourceMeetingId: String?
    var sourceSegmentRef: String?
    var origin: String
    var confidence: Double
    var status: String
    var supersededBy: String?
    var createdAt: Date
    var isDeleted: Bool
    var deletedAt: Date?
}

extension ProfileFactRecord {
    init(_ fact: ProfileFact) {
        id = fact.id.rawValue
        personId = fact.personId.rawValue
        factText = fact.factText
        factKind = fact.factKind.rawValue
        sourceMeetingId = fact.sourceMeetingId?.rawValue
        sourceSegmentRef = fact.sourceSegmentRef
        origin = fact.origin.rawValue
        confidence = fact.confidence
        status = fact.status.rawValue
        supersededBy = fact.supersededBy?.rawValue
        createdAt = fact.createdAt
        isDeleted = false
        deletedAt = nil
    }

    /// See file header: `sourceMeetingTitle`/`sourceCount` are read-time-computed, always
    /// supplied by the repository, never derived from this record alone.
    func asModel(sourceMeetingTitle: String?, sourceCount: Int) -> ProfileFact {
        ProfileFact(
            id: ProfileFactID(id),
            personId: PersonID(personId),
            factText: factText,
            factKind: FactKind(rawValue: factKind) ?? FactKind.unknownCase(factKind),
            sourceMeetingId: sourceMeetingId.map { MeetingID($0) },
            sourceMeetingTitle: sourceMeetingTitle,
            sourceSegmentRef: sourceSegmentRef,
            origin: FactOrigin(rawValue: origin) ?? FactOrigin.unknownCase(origin),
            confidence: confidence,
            sourceCount: sourceCount,
            status: FactStatus(rawValue: status) ?? FactStatus.unknownCase(status),
            supersededBy: supersededBy.map { ProfileFactID($0) },
            createdAt: createdAt
        )
    }
}
