//
//  Summary.swift — the LLM-generated meeting summary (NEW type, no Rust row; plan §4.9).
//
//  The frozen Rust engine has no dedicated `summary` table — a summary today lives in
//  `summary_processes.result` JSON plus `meetings.summary_*` provider/model columns
//  (resolves `arikit-models.md` decision 0.2). This is a net-new, additive domain type: a typed
//  row the Store persists directly, not a port of an existing Rust struct.
//
import Foundation

/// Typed identifier for a `Summary` (plan §7.4).
public typealias SummaryID = Identifier<Summary>

public struct Summary: Codable, Hashable, Sendable, Identifiable {
    public var id: SummaryID
    public var meetingId: MeetingID
    public var bodyMarkdown: String
    public var provider: String?
    public var model: String?
    public var templateId: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: SummaryID,
        meetingId: MeetingID,
        bodyMarkdown: String,
        provider: String? = nil,
        model: String? = nil,
        templateId: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.meetingId = meetingId
        self.bodyMarkdown = bodyMarkdown
        self.provider = provider
        self.model = model
        self.templateId = templateId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
