//
//  PersonExtraction.swift — F2 fact-extraction engine (Phase 3.4 Track H §2, ←
//  `ari-engine/src/persons/extraction.rs`). Rides the already-landed `LLMClient` layer via the
//  shared `ProviderConfigResolution` helper (§6-7) — no new client. Runs off the STT hot path,
//  triggered by the app after a summary completes; never blocks capture/transcription.
//
//  Degrades gracefully (← `extraction.rs:53-55`): unconfigured provider, empty transcript, no
//  participants, or a malformed model response all return an honest `ExtractionResult{created:
//  0, ...}` — never `throws`. `throws` is reserved for genuine Store failures.
//
import Foundation

public struct ExtractionResult: Sendable, Equatable {
    public let created: Int
    public let message: String

    public init(created: Int, message: String) {
        self.created = created
        self.message = message
    }
}

public struct PersonExtraction: Sendable {
    /// ← the local-recall context bound, mirrored (`extraction.rs:28`).
    static let maxTranscriptChars = 48000

    private let db: AppDatabase
    private let settings: any SettingsReading
    private let secrets: any SecretsReading
    private let clientFactory: @Sendable (ProviderConfig) throws -> any LLMClient

    public init(
        db: AppDatabase,
        settings: any SettingsReading,
        secrets: any SecretsReading,
        clientFactory: @escaping @Sendable (ProviderConfig) throws -> any LLMClient = {
            try ProviderFactory.make(config: $0)
        }
    ) {
        self.db = db
        self.settings = settings
        self.secrets = secrets
        self.clientFactory = clientFactory
    }

    public func extractFacts(forMeeting meetingId: MeetingID) async throws -> ExtractionResult {
        let participants = try await db.persons.participants(inMeeting: meetingId)
        guard !participants.isEmpty else {
            return ExtractionResult(
                created: 0,
                message: "No linked participants for this meeting — nothing to extract facts about."
            )
        }

        let transcriptText = try await Self.resolveTranscriptText(db: db, meetingId: meetingId)
        guard !transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ExtractionResult(created: 0, message: "No transcript text found for this meeting.")
        }

        guard let modelConfig = try await settings.summaryModelConfig() else {
            return ExtractionResult(
                created: 0,
                message: "No summarization provider configured — skipping fact extraction."
            )
        }

        let providerConfig: ProviderConfig
        do {
            providerConfig = try await ProviderConfigResolution.resolve(
                providerKey: modelConfig.providerKey,
                modelName: modelConfig.model,
                settings: settings,
                secrets: secrets
            )
        } catch let error as LLMError {
            return ExtractionResult(created: 0, message: Self.degradeMessage(for: error, verb: "extraction"))
        }

        let participantList = participants
            .map { "- \($0.displayName) <\($0.email ?? "no email")>" }
            .joined(separator: "\n")
        let boundedTranscript = String(transcriptText.prefix(Self.maxTranscriptChars))

        let systemPrompt = """
        You extract concrete facts people state about themselves or that others attribute to \
        them in a meeting transcript. Output STRICT JSON only — a JSON array, no prose, no \
        markdown code fences. Only include facts about the listed participants. Never \
        speculate; if nothing concrete is present, output an empty array `[]`.
        """
        let userPrompt = """
        Known participants:
        \(participantList)

        Transcript:
        \(boundedTranscript)

        Output a JSON array where each item is:
        {"person_email": string|null, "person_name": string, \
        "fact_kind": "goal"|"interest"|"project"|"role_signal"|"other", \
        "source_kind": "self_reported"|"attributed", "confidence": number (0.0-1.0), \
        "fact_text": string, "evidence": string}
        """

        let client: any LLMClient
        do {
            client = try clientFactory(providerConfig)
        } catch {
            return ExtractionResult(created: 0, message: "LLM call failed: \(error)")
        }

        let rawResponse: String
        do {
            rawResponse = try await client.generate(LLMRequest(system: systemPrompt, user: userPrompt))
        } catch {
            return ExtractionResult(created: 0, message: "LLM call failed: \(error)")
        }

        let items: [ExtractedFact]
        do {
            items = try Self.parseExtractedFacts(rawResponse)
        } catch {
            return ExtractionResult(created: 0, message: "Could not parse model response as JSON: \(error)")
        }

        guard !items.isEmpty else {
            return ExtractionResult(created: 0, message: "No concrete facts found in this meeting.")
        }

        let now = Date()
        var created = 0
        for item in items {
            guard let person = PersonResolve.resolvePerson(
                in: participants,
                email: item.personEmail,
                name: item.personName
            ) else {
                continue // can't attribute this item to a known participant — skip, never guess
            }

            let confidence = min(max(item.confidence, 0.0), 1.0)
            let factId = ProfileFactID(UUID().uuidString)
            let fact = ProfileFact(
                id: factId,
                personId: person.id,
                factText: item.factText,
                factKind: FactKind(rawValue: item.factKind) ?? .other,
                sourceMeetingId: meetingId,
                sourceSegmentRef: item.evidence,
                origin: FactOrigin(rawValue: item.sourceKind) ?? .attributed,
                confidence: confidence,
                sourceCount: 0,
                status: .pending,
                createdAt: now
            )
            try await db.profileFacts.upsert(fact)
            // Record this meeting as the fact's origin source (F2 multi-source facts).
            try await db.profileFacts.recordSource(ProfileFactSource(
                id: ProfileFactSourceID(UUID().uuidString),
                factId: factId,
                meetingId: meetingId,
                segmentRef: item.evidence,
                origin: fact.origin,
                relation: .origin,
                confidence: confidence,
                observedAt: now
            ))
            created += 1
        }

        let message = created > 0
            ? "Extracted \(created) pending fact(s) for review."
            : "No facts could be matched to a known participant."
        return ExtractionResult(created: created, message: message)
    }

    // MARK: - Shared transcript resolution (also used by `PersonReconciliation`)

    static func resolveTranscriptText(db: AppDatabase, meetingId: MeetingID) async throws -> String {
        if let labeled = try await LabeledTranscript.buildLabeledTranscriptText(db: db, meetingId: meetingId) {
            return labeled
        }
        return try await LabeledTranscript.loadTranscriptText(db: db, meetingId: meetingId)
    }

    /// Degrades an `LLMError` from `ProviderConfigResolution.resolve(...)` into an honest,
    /// non-throwing message (← the varied `empty_result(&format!(...))` call sites,
    /// `extraction.rs:94,106-109,125-127`). Shared with `PersonReconciliation`.
    static func degradeMessage(for error: LLMError, verb: String) -> String {
        switch error {
        case let .notConfigured(detail):
            "\(detail) — skipping fact \(verb)."
        case .loopbackViolation:
            "Local-only provider misconfigured — skipping fact \(verb)."
        case let .requestFailed(detail):
            "LLM call failed: \(detail)"
        case .cancelled:
            "LLM call failed: cancelled"
        case let .providerUnavailable(detail):
            "LLM call failed: \(detail)"
        }
    }

    // MARK: - JSON parsing (← `ExtractedFact`, `extraction.rs:30`; `strip_code_fences`, `:274`)

    struct ExtractedFact: Decodable {
        let personEmail: String?
        let personName: String?
        let factKind: String
        let sourceKind: String
        let confidence: Double
        let factText: String
        let evidence: String?

        private enum CodingKeys: String, CodingKey {
            case personEmail = "person_email"
            case personName = "person_name"
            case factKind = "fact_kind"
            case sourceKind = "source_kind"
            case confidence
            case factText = "fact_text"
            case evidence
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            personEmail = try container.decodeIfPresent(String.self, forKey: .personEmail)
            personName = try container.decodeIfPresent(String.self, forKey: .personName)
            factKind = try container.decodeIfPresent(String.self, forKey: .factKind) ?? "other"
            sourceKind = try container.decodeIfPresent(String.self, forKey: .sourceKind) ?? "attributed"
            confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0.0
            factText = try container.decode(String.self, forKey: .factText)
            evidence = try container.decodeIfPresent(String.self, forKey: .evidence)
        }
    }

    static func parseExtractedFacts(_ raw: String) throws -> [ExtractedFact] {
        let cleaned = stripCodeFences(raw)
        return try JSONDecoder().decode([ExtractedFact].self, from: Data(cleaned.utf8))
    }

    /// Strips Markdown code fences (```json ... ``` or ``` ... ```) some providers wrap JSON in
    /// (← `strip_code_fences`, `extraction.rs:274`). `internal` (module-default access), reused by
    /// `PersonReconciliation.parseOps(_:)`.
    static func stripCodeFences(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }

        var rest = String(trimmed.dropFirst(3))
        if rest.hasPrefix("json") {
            rest = String(rest.dropFirst(4))
        }
        while rest.hasPrefix("\n") {
            rest = String(rest.dropFirst())
        }
        if let range = rest.range(of: "```", options: .backwards) {
            return String(rest[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
