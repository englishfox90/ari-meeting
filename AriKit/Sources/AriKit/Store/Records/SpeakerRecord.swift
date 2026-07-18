//
//  SpeakerRecord.swift — GRDB record for the `speaker` table (plan §4.3).
//
//  Store-internal only — `SpeakerRepository` translates to/from the public
//  `AriKit.Models.Speaker` value type. `enrollmentState` is stored as its raw `String`; unknown
//  raws round-trip losslessly through `EnrollmentState`'s `UnknownTolerantEnum` conformance.
//
import Foundation
import GRDB

struct SpeakerRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "speaker"

    var id: String
    var personId: String?
    var label: String?
    var centroid: Data
    var embeddingModel: String
    var dim: Int
    var samples: Int
    var enrollmentState: String
    var totalSpeechSecs: Double
    var createdAt: Date
    var updatedAt: Date
    var isDeleted: Bool
    var deletedAt: Date?
}

extension SpeakerRecord {
    init(_ speaker: Speaker) {
        id = speaker.id.rawValue
        personId = speaker.personId?.rawValue
        label = speaker.label
        centroid = speaker.centroid
        embeddingModel = speaker.embeddingModel
        dim = speaker.dim
        samples = speaker.samples
        enrollmentState = speaker.enrollmentState.rawValue
        totalSpeechSecs = speaker.totalSpeechSecs
        createdAt = speaker.createdAt
        updatedAt = speaker.updatedAt
        isDeleted = false
        deletedAt = nil
    }

    func asModel() -> Speaker {
        Speaker(
            id: SpeakerID(id),
            personId: personId.map { PersonID($0) },
            label: label,
            centroid: centroid,
            embeddingModel: embeddingModel,
            dim: dim,
            samples: samples,
            enrollmentState: EnrollmentState(rawValue: enrollmentState)
                ?? EnrollmentState.unknownCase(enrollmentState),
            totalSpeechSecs: totalSpeechSecs,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
