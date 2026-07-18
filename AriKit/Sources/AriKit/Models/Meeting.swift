//
//  Meeting.swift — a recorded meeting (← Rust `MeetingModel`, database/models.rs:6).
//
//  Domain mirror of a meeting row. `folder_path` maps to `audioReference`
//  (`LocalAudioReference?`, plan §6) — audio stays a device-local path, never a synced blob.
//  `createdAt`/`updatedAt` are real instants (`Date`); the provider/model fields are the
//  transcription/summary engine selection recorded on the meeting.
//
//  ⚠️ Wire surface: the Rust `MeetingModel` has no `#[serde(rename_all)]`, so the engine's IPC
//  DTO emits snake_case (`folder_path`, `created_at`, …). This camelCase-native domain type
//  therefore does NOT decode raw engine JSON directly — a snake→camel adapter belongs at the
//  Store/Engine seam (plan §7.7). Same caveat applies to Transcript/Speaker/SpeakerSegment.
//
import Foundation

/// Typed identifier for a `Meeting` (plan §7.4).
public typealias MeetingID = Identifier<Meeting>

public struct Meeting: Codable, Hashable, Sendable, Identifiable {
    public var id: MeetingID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Local-only path to the meeting's audio/recording folder (Rust `folder_path`).
    public var audioReference: LocalAudioReference?
    public var transcriptionProvider: String?
    public var transcriptionModel: String?
    public var summaryProvider: String?
    public var summaryModel: String?

    public init(
        id: MeetingID,
        title: String,
        createdAt: Date,
        updatedAt: Date,
        audioReference: LocalAudioReference? = nil,
        transcriptionProvider: String? = nil,
        transcriptionModel: String? = nil,
        summaryProvider: String? = nil,
        summaryModel: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.audioReference = audioReference
        self.transcriptionProvider = transcriptionProvider
        self.transcriptionModel = transcriptionModel
        self.summaryProvider = summaryProvider
        self.summaryModel = summaryModel
    }
}
