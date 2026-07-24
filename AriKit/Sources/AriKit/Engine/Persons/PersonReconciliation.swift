//
//  PersonReconciliation.swift — F2 fact-RECONCILIATION engine (Phase 3.4 Track H §2, ←
//  `ari-engine/src/persons/reconciliation.rs`). Supersedes plain extraction as the trigger fired
//  after a summary completes: instead of only ever inserting new pending facts, it shows the
//  model each participant's CURRENT facts (active + pending) alongside the new transcript and
//  asks it to decide, per participant, whether to ADD/SUPERSEDE/KEEP/REMOVE. A per-person
//  active/pending cap is enforced afterward as a hard backstop regardless of the model's choices.
//
//  Same degrade-gracefully contract as `PersonExtraction`: unconfigured provider, empty
//  transcript, no participants, or malformed model response all return an honest all-zero
//  `ReconciliationResult` — never `throws`.
//
//  No-Fake-State (← `reconciliation.rs:20-22`): every ADD/SUPERSEDE operation must carry a
//  `sourceSegmentRef` (the evidence quote from the transcript) — operations missing required
//  evidence are skipped, never guessed. A `fact_id` not owned by the resolved person is refused.
//
import Foundation

public struct ReconciliationResult: Sendable, Equatable {
    public let added: Int
    public let superseded: Int
    public let kept: Int
    public let removed: Int
    public let capped: Int
    public let message: String

    public init(added: Int, superseded: Int, kept: Int, removed: Int, capped: Int, message: String) {
        self.added = added
        self.superseded = superseded
        self.kept = kept
        self.removed = removed
        self.capped = capped
        self.message = message
    }
}

public struct PersonReconciliation: Sendable {
    /// ← the reconciliation caps/staleness window (`reconciliation.rs:45-54`).
    public enum Limits {
        public static let maxActiveFactsPerPerson = 12
        public static let maxPendingFactsPerPerson = 10
        public static let staleAfterDays = 28
    }

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

    public func reconcileFacts(forMeeting meetingId: MeetingID) async throws -> ReconciliationResult {
        func emptyResult(_ message: String) -> ReconciliationResult {
            ReconciliationResult(added: 0, superseded: 0, kept: 0, removed: 0, capped: 0, message: message)
        }

        let participants = try await db.persons.participants(inMeeting: meetingId)
        guard !participants.isEmpty else {
            return emptyResult("No linked participants for this meeting — nothing to reconcile.")
        }

        let transcriptText = try await PersonExtraction.resolveTranscriptText(db: db, meetingId: meetingId)
        guard !transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return emptyResult("No transcript text found for this meeting.")
        }

        guard let modelConfig = try await settings.summaryModelConfig() else {
            return emptyResult("No summarization provider configured — skipping fact reconciliation.")
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
            return emptyResult(PersonExtraction.degradeMessage(for: error, verb: "reconciliation"))
        }

        // Load each participant's CURRENT facts (active + pending) so the model reconciles
        // against them instead of blindly appending.
        var existingFactsByPerson: [PersonID: [ProfileFact]] = [:]
        for participant in participants {
            existingFactsByPerson[participant.id] = try await db.profileFacts.listActiveAndPending(
                for: participant.id
            )
        }

        let now = Date()
        let participantBlock = participants
            .map { Self.formatPersonBlock($0, facts: existingFactsByPerson[$0.id] ?? [], now: now) }
            .joined(separator: "\n\n")
        let boundedTranscript = String(transcriptText.prefix(PersonExtraction.maxTranscriptChars))

        let systemPrompt = """
        You maintain a SMALL, managed set of facts about each meeting participant — you do not \
        let it grow without bound. You are shown each participant's CURRENT facts (with their \
        id, kind, confidence, and age) plus a new meeting transcript. For every piece of \
        concrete new information, and for every existing fact that the transcript touches on, \
        decide one operation. Output STRICT JSON only — a JSON array, no prose, no markdown \
        code fences. If nothing in the transcript is concrete or relevant, output an empty \
        array `[]`. Never invent facts or ids that were not given to you.
        """
        let userPrompt = """
        Participants and their CURRENT facts:
        \(participantBlock)

        New transcript:
        \(boundedTranscript)

        For each fact-worthy observation, output one JSON object. Valid operations:
        - "add": a genuinely NEW fact not already covered by an existing one. Requires \
        fact_text, fact_kind, confidence, source_segment_ref. fact_id must be null.
        - "supersede": an EXISTING fact (by fact_id) is now outdated/incomplete and should be \
        replaced with an updated fact_text. Requires fact_id, fact_text, fact_kind, \
        confidence, source_segment_ref.
        - "keep": an EXISTING fact (by fact_id) is reaffirmed by this transcript and stays \
        exactly as-is. Requires only fact_id.
        - "remove": an EXISTING fact (by fact_id) is contradicted, no longer true, or is a \
        near-duplicate of a better fact and should be dropped. Requires only fact_id.
        Do NOT add a fact that duplicates or lightly rephrases one already listed — use \
        "supersede" on the existing fact_id instead. Only emit ops for facts you have real \
        evidence for; when unsure, omit rather than guess.

        Output a JSON array where each item is:
        {"person_email": string|null, "person_name": string, \
        "op": "add"|"supersede"|"keep"|"remove", "fact_id": string|null, \
        "fact_text": string|null, \
        "fact_kind": "goal"|"interest"|"project"|"role_signal"|"other"|null, \
        "confidence": number|null, "source_segment_ref": string|null, "reason": string|null}
        """

        let client: any LLMClient
        do {
            client = try clientFactory(providerConfig)
        } catch {
            return emptyResult("LLM call failed: \(error)")
        }

        let rawResponse: String
        do {
            rawResponse = try await client.generate(LLMRequest(system: systemPrompt, user: userPrompt))
        } catch {
            return emptyResult("LLM call failed: \(error)")
        }

        let ops: [ReconcileOp]
        do {
            ops = try Self.parseOps(rawResponse)
        } catch {
            return emptyResult("Could not parse model response as JSON: \(error)")
        }

        guard !ops.isEmpty else {
            return emptyResult("No fact changes needed for this meeting.")
        }

        var added = 0
        var superseded = 0
        var kept = 0
        var removed = 0

        for op in ops {
            guard let person = PersonResolve.resolvePerson(
                in: participants,
                email: op.personEmail,
                name: op.personName
            ) else {
                continue // can't attribute this op to a known participant — skip, never guess
            }

            // Only allow fact_id references that actually belong to THIS person's existing
            // fact set — never let the model touch another participant's facts.
            let existingForPerson = existingFactsByPerson[person.id] ?? []

            switch op.op {
            case "add":
                guard let factText = op.factText, let evidence = op.sourceSegmentRef,
                      !factText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    continue // No-Fake-State: an added fact must carry evidence
                }
                let factKind = FactKind(rawValue: op.factKind ?? "other") ?? .other
                let confidence = min(max(op.confidence ?? 0.0, 0.0), 1.0)
                let factId = ProfileFactID(UUID().uuidString)
                let fact = ProfileFact(
                    id: factId,
                    personId: person.id,
                    factText: factText,
                    factKind: factKind,
                    sourceMeetingId: meetingId,
                    sourceSegmentRef: evidence,
                    origin: .attributed,
                    confidence: confidence,
                    sourceCount: 0,
                    status: .pending,
                    createdAt: now
                )
                try await db.profileFacts.upsert(fact)
                try await db.profileFacts.recordSource(ProfileFactSource(
                    id: ProfileFactSourceID(UUID().uuidString),
                    factId: factId,
                    meetingId: meetingId,
                    segmentRef: evidence,
                    origin: .attributed,
                    relation: .origin,
                    confidence: confidence,
                    observedAt: now
                ))
                added += 1

            case "supersede":
                guard let oldFactId = op.factId,
                      existingForPerson.contains(where: { $0.id.rawValue == oldFactId })
                else {
                    continue // fact_id not owned by this person — refuse to guess
                }
                guard let factText = op.factText, let evidence = op.sourceSegmentRef,
                      !factText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    continue
                }
                let factKind = FactKind(rawValue: op.factKind ?? "other") ?? .other
                let confidence = min(max(op.confidence ?? 0.0, 0.0), 1.0)
                let newFactId = ProfileFactID(UUID().uuidString)
                let newFact = ProfileFact(
                    id: newFactId,
                    personId: person.id,
                    factText: factText,
                    factKind: factKind,
                    sourceMeetingId: meetingId,
                    sourceSegmentRef: evidence,
                    origin: .attributed,
                    confidence: confidence,
                    sourceCount: 0,
                    status: .pending,
                    createdAt: now
                )
                try await db.profileFacts.upsert(newFact)
                try await db.profileFacts.recordSource(ProfileFactSource(
                    id: ProfileFactSourceID(UUID().uuidString),
                    factId: newFactId,
                    meetingId: meetingId,
                    segmentRef: evidence,
                    origin: .attributed,
                    relation: .origin,
                    confidence: confidence,
                    observedAt: now
                ))
                // Deferred supersession: record the replacement's intent but DO NOT retire the
                // old fact yet — it stays active until a future confirm flow retires it.
                try await db.profileFacts.markSupersedes(newFactId: newFactId, oldFactId: ProfileFactID(oldFactId))
                superseded += 1

            case "keep":
                guard let factId = op.factId,
                      let existing = existingForPerson.first(where: { $0.id.rawValue == factId })
                else {
                    continue
                }
                try await db.profileFacts.touchConfirmed(existing.id)
                let sourceConfidence = min(max(op.confidence ?? existing.confidence, 0.0), 1.0)
                try await db.profileFacts.addSourceDedup(
                    factId: existing.id,
                    meetingId: meetingId,
                    segmentRef: op.sourceSegmentRef,
                    origin: .attributed,
                    relation: .reaffirmed,
                    confidence: sourceConfidence
                )
                kept += 1

            case "remove":
                guard let factId = op.factId,
                      let existing = existingForPerson.first(where: { $0.id.rawValue == factId })
                else {
                    continue
                }
                try await db.profileFacts.markRemoved(existing.id)
                removed += 1

            default:
                continue // unknown op — skip, never guess
            }
        }

        // Backstop: regardless of what the model decided, keep each participant's ACTIVE and
        // PENDING fact counts under their respective caps.
        var capped = 0
        for participant in participants {
            capped += try await db.profileFacts.trimActiveToCap(
                person: participant.id,
                cap: Limits.maxActiveFactsPerPerson
            )
            capped += try await db.profileFacts.trimPendingToCap(
                person: participant.id,
                cap: Limits.maxPendingFactsPerPerson
            )
        }

        var message = "Reconciled facts: \(added) added, \(superseded) superseded (pending confirm), " +
            "\(kept) kept, \(removed) removed"
        if capped > 0 {
            message += ", \(capped) pruned for exceeding a per-person cap"
        }
        message += "."

        return ReconciliationResult(
            added: added,
            superseded: superseded,
            kept: kept,
            removed: removed,
            capped: capped,
            message: message
        )
    }

    /// Facts for `personId` that haven't been (re)confirmed in `Limits.staleAfterDays` — surfaced
    /// for a future "needs review" UI affordance (← `facts_needing_review`,
    /// `reconciliation.rs:455`).
    public func factsNeedingReview(for personId: PersonID) async throws -> [ProfileFact] {
        try await db.profileFacts.factsNeedingReview(person: personId, staleDays: Limits.staleAfterDays)
    }

    // MARK: - Prompt formatting (← `format_person_block`, `reconciliation.rs:462`)

    /// `internal` (module-default access, widened from `private` — docs/plans/
    /// person-fact-consolidation.md §5): reused verbatim by `PersonFactConsolidation` so both
    /// prompts show the model the identical id/kind/confidence/status/age format it has already
    /// proven reliable at parsing, with no risk of the two formatters drifting apart.
    static func formatPersonBlock(_ person: Person, facts: [ProfileFact], now: Date) -> String {
        let header = "- \(person.displayName) <\(person.email ?? "no email")>"
        guard !facts.isEmpty else {
            return "\(header)\n  (no existing facts)"
        }
        let lines = facts.map { fact -> String in
            let ageDays = max(0, Int(now.timeIntervalSince(fact.createdAt) / 86400))
            let confidenceText = String(format: "%.2f", fact.confidence)
            return "  - id=\(fact.id.rawValue) kind=\(fact.factKind.rawValue) " +
                "confidence=\(confidenceText) status=\(fact.status.rawValue) age_days=\(ageDays) " +
                "text=\"\(fact.factText)\""
        }.joined(separator: "\n")
        return "\(header)\n\(lines)"
    }

    // MARK: - JSON parsing (← `ReconcileOp`, `reconciliation.rs:56`)

    struct ReconcileOp: Decodable {
        let personEmail: String?
        let personName: String?
        let op: String
        let factId: String?
        let factText: String?
        let factKind: String?
        let confidence: Double?
        let sourceSegmentRef: String?

        private enum CodingKeys: String, CodingKey {
            case personEmail = "person_email"
            case personName = "person_name"
            case op
            case factId = "fact_id"
            case factText = "fact_text"
            case factKind = "fact_kind"
            case confidence
            case sourceSegmentRef = "source_segment_ref"
            // `reason` is decoded by the model but never applied — kept for prompt fidelity only
            // (← `#[allow(dead_code)]`, `reconciliation.rs:72-73`); intentionally not a CodingKey
            // here since nothing reads it.
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            personEmail = try container.decodeIfPresent(String.self, forKey: .personEmail)
            personName = try container.decodeIfPresent(String.self, forKey: .personName)
            op = try container.decode(String.self, forKey: .op)
            factId = try container.decodeIfPresent(String.self, forKey: .factId)
            factText = try container.decodeIfPresent(String.self, forKey: .factText)
            factKind = try container.decodeIfPresent(String.self, forKey: .factKind)
            confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
            sourceSegmentRef = try container.decodeIfPresent(String.self, forKey: .sourceSegmentRef)
        }
    }

    static func parseOps(_ raw: String) throws -> [ReconcileOp] {
        let cleaned = PersonExtraction.stripCodeFences(raw)
        return try JSONDecoder().decode([ReconcileOp].self, from: Data(cleaned.utf8))
    }
}
