//
//  SummaryRecord.swift — GRDB record for the `summary` table (plan §4.9).
//
//  Store-internal only — `SummaryRepository` translates to/from the public
//  `AriKit.Models.Summary` value type. No Rust source row (§4.9) — this table is net-new.
//
import Foundation
import GRDB

struct SummaryRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "summary"

    var id: String
    var meetingId: String
    var bodyMarkdown: String
    var provider: String?
    var model: String?
    var templateId: String?
    /// ← `v7_summary_custom_prompt`. The raw user-entered instructions only — never the merged
    /// context+instructions prompt (see `Summary.customInstructions`'s header).
    var customInstructions: String?
    var createdAt: Date
    var updatedAt: Date
    var isDeleted: Bool
    var deletedAt: Date?
}

extension SummaryRecord {
    init(_ summary: Summary) {
        id = summary.id.rawValue
        meetingId = summary.meetingId.rawValue
        bodyMarkdown = summary.bodyMarkdown
        provider = summary.provider
        model = summary.model
        templateId = summary.templateId
        customInstructions = summary.customInstructions
        createdAt = summary.createdAt
        updatedAt = summary.updatedAt
        isDeleted = false
        deletedAt = nil
    }

    func asModel() -> Summary {
        Summary(
            id: SummaryID(id),
            meetingId: MeetingID(meetingId),
            bodyMarkdown: bodyMarkdown,
            provider: provider,
            model: model,
            templateId: templateId,
            customInstructions: customInstructions,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
