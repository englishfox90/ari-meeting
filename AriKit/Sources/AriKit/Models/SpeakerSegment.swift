//
//  SpeakerSegment.swift — a diarized span within a meeting
//  (← Rust `SpeakerSegment`, database/models.rs:71).
//
//  `startTime`/`endTime` are recording-relative `Double` seconds. `embedding` is opaque
//  per-segment f32 bytes (matcher-owned) — a model vector, `nil` when not computed; exempt from
//  the no-audio-blob rule (plan §6/test 6). `source` is a forward-tolerant enum seeded with the
//  known writer value `import` (plan decision 0.5).
//
//  ⚠️ Wire surface: the Rust `SpeakerSegment` has no `#[serde(rename_all)]`; the engine emits
//  snake_case (`meeting_id`, `cluster_key`, `start_time`, …), so this camelCase-native type
//  needs a snake→camel adapter at the Store/Engine seam to decode raw engine JSON (plan §7.7).
//
import Foundation

/// Typed identifier for a `SpeakerSegment` (plan §7.4).
public typealias SpeakerSegmentID = Identifier<SpeakerSegment>

/// How a `SpeakerSegment` entered the store (plan §7.2). Seed set is `import`; the writer set is
/// forward-tolerant, so a future engine value decodes to `.unknown` rather than failing.
public enum SegmentSource: UnknownTolerantEnum {
    case `import`
    case unknown(String)

    public init?(rawValue: String) {
        switch rawValue {
        case "import": self = .import
        default: return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .import: "import"
        case let .unknown(raw): raw
        }
    }

    public static func unknownCase(_ rawValue: String) -> Self { .unknown(rawValue) }
    public init(from decoder: any Decoder) throws { try self.init(tolerantFrom: decoder) }
    public func encode(to encoder: any Encoder) throws { try encodeTolerant(to: encoder) }
}

public struct SpeakerSegment: Codable, Hashable, Sendable, Identifiable {
    public var id: SpeakerSegmentID
    public var meetingId: MeetingID
    public var speakerId: SpeakerID?
    public var clusterKey: String
    /// Recording-relative start offset, seconds.
    public var startTime: Double
    /// Recording-relative end offset, seconds.
    public var endTime: Double
    public var source: SegmentSource
    /// Opaque per-segment f32 embedding bytes (matcher-owned). A model vector, not audio.
    public var embedding: Data?
    public var createdAt: Date

    public init(
        id: SpeakerSegmentID,
        meetingId: MeetingID,
        speakerId: SpeakerID? = nil,
        clusterKey: String,
        startTime: Double,
        endTime: Double,
        source: SegmentSource,
        embedding: Data? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.meetingId = meetingId
        self.speakerId = speakerId
        self.clusterKey = clusterKey
        self.startTime = startTime
        self.endTime = endTime
        self.source = source
        self.embedding = embedding
        self.createdAt = createdAt
    }
}
