//
//  Speaker.swift — persistent voiceprint (F1) (← Rust `Speaker`, database/models.rs:50).
//
//  `centroid` is an opaque little-endian f32 vector the matcher module owns; this layer treats
//  it as `Data` (a model vector, exempt from the no-audio-blob rule — plan §6/test 6, it is not
//  audio). `enrollmentState` is a forward-tolerant enum. `totalSpeechSecs` is the duration-
//  weighted fold weight (distinct from `samples`, a raw fold count for display).
//
//  ⚠️ Wire surface: the Rust `Speaker` has no `#[serde(rename_all)]`; the engine emits
//  snake_case (`embedding_model`, `enrollment_state`, `total_speech_secs`, …), so this
//  camelCase-native type needs a snake→camel adapter at the Store/Engine seam (plan §7.7).
//
import Foundation

/// Typed identifier for a `Speaker` voiceprint (plan §7.4).
public typealias SpeakerID = Identifier<Speaker>

/// Confirm-before-enroll lifecycle of a voiceprint (plan §7.2). `.owner` is the recording owner.
public enum EnrollmentState: UnknownTolerantEnum {
    case provisional
    case confirmed
    case owner
    case unknown(String)

    public init?(rawValue: String) {
        switch rawValue {
        case "provisional": self = .provisional
        case "confirmed": self = .confirmed
        case "owner": self = .owner
        default: return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .provisional: "provisional"
        case .confirmed: "confirmed"
        case .owner: "owner"
        case let .unknown(raw): raw
        }
    }

    public static func unknownCase(_ rawValue: String) -> Self { .unknown(rawValue) }
    public init(from decoder: any Decoder) throws { try self.init(tolerantFrom: decoder) }
    public func encode(to encoder: any Encoder) throws { try encodeTolerant(to: encoder) }
}

public struct Speaker: Codable, Hashable, Sendable, Identifiable {
    public var id: SpeakerID
    public var personId: PersonID?
    public var label: String?
    /// Opaque f32 voiceprint centroid bytes (matcher-owned). A model vector, not audio.
    public var centroid: Data
    public var embeddingModel: String
    public var dim: Int
    /// Raw fold count, for display.
    public var samples: Int
    public var enrollmentState: EnrollmentState
    /// Total speech seconds folded into `centroid` (duration-weighted fold weight).
    public var totalSpeechSecs: Double
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: SpeakerID,
        personId: PersonID? = nil,
        label: String? = nil,
        centroid: Data,
        embeddingModel: String,
        dim: Int,
        samples: Int,
        enrollmentState: EnrollmentState,
        totalSpeechSecs: Double,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.personId = personId
        self.label = label
        self.centroid = centroid
        self.embeddingModel = embeddingModel
        self.dim = dim
        self.samples = samples
        self.enrollmentState = enrollmentState
        self.totalSpeechSecs = totalSpeechSecs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
