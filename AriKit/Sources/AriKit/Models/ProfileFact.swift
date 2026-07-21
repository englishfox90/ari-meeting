//
//  ProfileFact.swift — inferred facts, tier 2, with provenance (F2).
//
//  Ports Rust `ProfileFact` (persons/models.rs:36) and `ProfileFactSource` (persons/models.rs:58)
//  plus their four forward-tolerant enums, and adds the `ProfileFactWithProvenance` aggregate.
//
//  Invariants preserved (plan §6):
//  - Two-tier identity: `ProfileFact` (inferred) is distinct from `Person` (authored).
//  - Provenance / never-invents-citations (data-level analog): every inferred fact is traceable
//    via `sourceMeetingId`, `sourceSegmentRef`, `origin`, `confidence`, plus a `[ProfileFactSource]`
//    lineage. Un-sourced inferred facts are expressible (nullable source refs) while the
//    corroboration signal (`sourceCount`) survives. `supersededBy` models the supersession chain
//    as a pointer.
//  - No-Fake-State: `sourceCount` is a real recorded count from the engine, not a computed view
//    aggregate; no derived counts are fabricated here.
//
//  Rename delta (plan §7.2): the Rust wire key `sourceKind` maps to the Swift property `origin`
//  (of type `FactOrigin`), reconciling the `source_kind → origin` rename. Explicit `CodingKeys`
//  carry this so real engine JSON still decodes.
//
import Foundation

/// Typed identifier for a `ProfileFact` (plan §7.4).
public typealias ProfileFactID = Identifier<ProfileFact>

/// Typed identifier for a `ProfileFactSource` provenance row (plan §7.4).
public typealias ProfileFactSourceID = Identifier<ProfileFactSource>

// MARK: - Tolerant enums (plan §7.2)

/// Category of an inferred fact.
public enum FactKind: UnknownTolerantEnum {
    case goal
    case interest
    case project
    case roleSignal
    case other
    case unknown(String)

    public init?(rawValue: String) {
        switch rawValue {
        case "goal": self = .goal
        case "interest": self = .interest
        case "project": self = .project
        case "role_signal": self = .roleSignal
        case "other": self = .other
        default: return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .goal: "goal"
        case .interest: "interest"
        case .project: "project"
        case .roleSignal: "role_signal"
        case .other: "other"
        case let .unknown(raw): raw
        }
    }

    public static func unknownCase(_ rawValue: String) -> Self {
        .unknown(rawValue)
    }

    public init(from decoder: any Decoder) throws {
        try self.init(tolerantFrom: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        try encodeTolerant(to: encoder)
    }
}

/// Lifecycle status of a fact under reconciliation/supersession.
///
/// `.removed` (plan §6-4, `arikit-engine-extras.md`): the automated-pruning status the
/// reconciliation engine (or the active/pending cap backstop) applies — distinct from
/// `.rejected` (a human explicitly said no). Rust's `mark_removed` sets the same string status
/// ("removed") on the `profile_facts.status` column (← `person.rs:688`); this is a genuinely new
/// domain case, not a rename of an existing one, so it round-trips as a KNOWN case rather than
/// falling through to `.unknown(_)`.
public enum FactStatus: UnknownTolerantEnum {
    case pending
    case active
    case superseded
    case rejected
    case removed
    case unknown(String)

    public init?(rawValue: String) {
        switch rawValue {
        case "pending": self = .pending
        case "active": self = .active
        case "superseded": self = .superseded
        case "rejected": self = .rejected
        case "removed": self = .removed
        default: return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .pending: "pending"
        case .active: "active"
        case .superseded: "superseded"
        case .rejected: "rejected"
        case .removed: "removed"
        case let .unknown(raw): raw
        }
    }

    public static func unknownCase(_ rawValue: String) -> Self {
        .unknown(rawValue)
    }

    public init(from decoder: any Decoder) throws {
        try self.init(tolerantFrom: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        try encodeTolerant(to: encoder)
    }
}

/// How a fact/source was obtained (Rust `source_kind`; the Store skill's `origin`). Reconciles
/// the `source_kind → origin` rename.
public enum FactOrigin: UnknownTolerantEnum {
    case selfReported
    case attributed
    case unknown(String)

    public init?(rawValue: String) {
        switch rawValue {
        case "self_reported": self = .selfReported
        case "attributed": self = .attributed
        default: return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .selfReported: "self_reported"
        case .attributed: "attributed"
        case let .unknown(raw): raw
        }
    }

    public static func unknownCase(_ rawValue: String) -> Self {
        .unknown(rawValue)
    }

    public init(from decoder: any Decoder) throws {
        try self.init(tolerantFrom: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        try encodeTolerant(to: encoder)
    }
}

/// A source's relation to the fact it backs.
public enum FactSourceRelation: UnknownTolerantEnum {
    case origin
    case reaffirmed
    case carried
    case unknown(String)

    public init?(rawValue: String) {
        switch rawValue {
        case "origin": self = .origin
        case "reaffirmed": self = .reaffirmed
        case "carried": self = .carried
        default: return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .origin: "origin"
        case .reaffirmed: "reaffirmed"
        case .carried: "carried"
        case let .unknown(raw): raw
        }
    }

    public static func unknownCase(_ rawValue: String) -> Self {
        .unknown(rawValue)
    }

    public init(from decoder: any Decoder) throws {
        try self.init(tolerantFrom: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        try encodeTolerant(to: encoder)
    }
}

// MARK: - ProfileFact (tier 2 row)

public struct ProfileFact: Codable, Hashable, Sendable, Identifiable {
    public var id: ProfileFactID
    public var personId: PersonID
    public var factText: String
    public var factKind: FactKind
    public var sourceMeetingId: MeetingID?
    public var sourceMeetingTitle: String?
    public var sourceSegmentRef: String?
    /// Rust wire key `sourceKind`; renamed to `origin` (plan §7.2).
    public var origin: FactOrigin
    public var confidence: Double
    /// Real recorded count of backing sources (origin + reaffirmations + carried lineage);
    /// `0` for manually-added facts. Not a computed view aggregate.
    public var sourceCount: Int
    public var status: FactStatus
    /// Pointer to the fact that supersedes this one, if any (supersession chain).
    public var supersededBy: ProfileFactID?
    public var createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case personId
        case factText
        case factKind
        case sourceMeetingId
        case sourceMeetingTitle
        case sourceSegmentRef
        case origin = "sourceKind"
        case confidence
        case sourceCount
        case status
        case supersededBy
        case createdAt
    }

    public init(
        id: ProfileFactID,
        personId: PersonID,
        factText: String,
        factKind: FactKind,
        sourceMeetingId: MeetingID? = nil,
        sourceMeetingTitle: String? = nil,
        sourceSegmentRef: String? = nil,
        origin: FactOrigin,
        confidence: Double,
        sourceCount: Int,
        status: FactStatus,
        supersededBy: ProfileFactID? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.personId = personId
        self.factText = factText
        self.factKind = factKind
        self.sourceMeetingId = sourceMeetingId
        self.sourceMeetingTitle = sourceMeetingTitle
        self.sourceSegmentRef = sourceSegmentRef
        self.origin = origin
        self.confidence = confidence
        self.sourceCount = sourceCount
        self.status = status
        self.supersededBy = supersededBy
        self.createdAt = createdAt
    }
}

// MARK: - ProfileFactSource (one recorded observation backing a fact)

public struct ProfileFactSource: Codable, Hashable, Sendable, Identifiable {
    public var id: ProfileFactSourceID
    public var factId: ProfileFactID
    public var meetingId: MeetingID?
    public var meetingTitle: String?
    public var segmentRef: String?
    /// Rust wire key `sourceKind`; renamed to `origin` (plan §7.2).
    public var origin: FactOrigin
    public var relation: FactSourceRelation
    public var confidence: Double
    public var observedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case factId
        case meetingId
        case meetingTitle
        case segmentRef
        case origin = "sourceKind"
        case relation
        case confidence
        case observedAt
    }

    public init(
        id: ProfileFactSourceID,
        factId: ProfileFactID,
        meetingId: MeetingID? = nil,
        meetingTitle: String? = nil,
        segmentRef: String? = nil,
        origin: FactOrigin,
        relation: FactSourceRelation,
        confidence: Double,
        observedAt: Date
    ) {
        self.id = id
        self.factId = factId
        self.meetingId = meetingId
        self.meetingTitle = meetingTitle
        self.segmentRef = segmentRef
        self.origin = origin
        self.relation = relation
        self.confidence = confidence
        self.observedAt = observedAt
    }
}

// MARK: - Aggregate

/// A `ProfileFact` composed with its provenance lineage, without forcing the Store to
/// denormalize (plan §7.5). Purely a composition of two persisted value types.
public struct ProfileFactWithProvenance: Codable, Hashable, Sendable {
    public var fact: ProfileFact
    public var sources: [ProfileFactSource]

    public init(fact: ProfileFact, sources: [ProfileFactSource]) {
        self.fact = fact
        self.sources = sources
    }
}
