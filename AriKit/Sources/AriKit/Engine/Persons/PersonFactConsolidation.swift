//
//  PersonFactConsolidation.swift — F2 fact-CONSOLIDATION engine (docs/plans/
//  person-fact-consolidation.md §2/§5/§6). A narrow, on-demand, transcript-FREE pass that
//  collapses a person's existing near-duplicate `ProfileFact` rows (accumulated across many
//  meetings, or from the legacy importer) into fewer, better facts. Distinct from
//  `PersonReconciliation.reconcileFacts(forMeeting:)`, which only ever reconciles facts against a
//  NEW meeting transcript — this pass shows the model ONLY the person's current active+pending
//  facts (no transcript, no new content) and asks it to decide, per fact, "merge" or "keep".
//
//  Same degrade-gracefully contract as `PersonReconciliation`/`PersonExtraction`: unconfigured
//  provider, fewer than 2 facts, or a malformed model response all return an honest all-zero
//  `ConsolidationResult` — never `throws` for a degrade path. `throws` is reserved for genuine
//  Store failures.
//
//  No-Fake-State (plan §5/§9): this pass NEVER fabricates new fact content — there is no "add"
//  op. A "merge" may only reorganize/rephrase text already present across the source facts (a
//  prompt-enforced trust boundary, same as `reconcileFacts`'s "never invent facts" instruction).
//  A merged fact's `sourceSegmentRef` is an honest description of its own provenance
//  ("Consolidated from N existing facts"), never a fabricated transcript quote, and it carries NO
//  source row (§6 step 6) — `sourceCount` stays read-time-computed, honestly `0` until a future
//  meeting reaffirms it.
//
import Foundation

public struct ConsolidationResult: Sendable, Equatable {
    /// Number of NEW pending facts created by a `"merge"` op.
    public let merged: Int
    /// Number of OLD facts pointed at by a merge — summed across every applied `"merge"` op.
    public let factsRetired: Int
    /// `"keep"` ops applied — no DB write, informational only (there is no new evidence to
    /// record a reaffirmation against, unlike `reconcileFacts`'s "keep").
    public let kept: Int
    public let message: String

    public init(merged: Int, factsRetired: Int, kept: Int, message: String) {
        self.merged = merged
        self.factsRetired = factsRetired
        self.kept = kept
        self.message = message
    }
}

public struct PersonFactConsolidation: Sendable {
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

    /// One-time (but re-runnable) pass over `personId`'s current active+pending facts: no
    /// transcript, no new content — only reorganizes what's already stored. Never throws for a
    /// degrade path; genuine Store failures (e.g. `upsert`/`recordSupersession`) still propagate.
    public func consolidateFacts(for personId: PersonID) async throws -> ConsolidationResult {
        func emptyResult(_ message: String) -> ConsolidationResult {
            ConsolidationResult(merged: 0, factsRetired: 0, kept: 0, message: message)
        }

        let existingFacts = try await db.profileFacts.listActiveAndPending(for: personId)
        guard existingFacts.count >= 2 else {
            return emptyResult("Fewer than 2 facts on file — nothing to consolidate.")
        }

        guard let person = try await db.persons.find(personId) else {
            return emptyResult("Person not found — nothing to consolidate.")
        }

        guard let modelConfig = try await settings.summaryModelConfig() else {
            return emptyResult("No summarization provider configured — skipping fact consolidation.")
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
            return emptyResult(PersonExtraction.degradeMessage(for: error, verb: "consolidation"))
        }

        let now = Date()
        let personBlock = PersonReconciliation.formatPersonBlock(person, facts: existingFacts, now: now)

        let systemPrompt = """
        You are shown ALL of one person's current facts (id/kind/confidence/status/age/text), \
        with NO meeting transcript. Identify facts that are near-duplicates or restate \
        overlapping information, and propose merging them into fewer, better facts. Output \
        STRICT JSON only — a JSON array, no prose, no markdown code fences. Never invent a \
        fact_id not given to you. Never invent new factual content not already present across \
        the merged facts' texts — a merge may rephrase for clarity/concision but must not \
        introduce a claim absent from every source fact. If nothing overlaps, output an empty \
        array `[]`.
        """
        let userPrompt = """
        Current facts:
        \(personBlock)

        For each disposition, output one JSON object. Valid operations:
        - "merge": TWO OR MORE existing facts (by fact_ids) are near-duplicates or restate \
        overlapping information and should be collapsed into ONE new fact. Requires fact_ids \
        (an array of 2 or more existing ids), fact_text (the single consolidated replacement \
        text), fact_kind, confidence. Even an exact duplicate pair should be "merge"d (into a \
        new fact with that same text) rather than dropped outright.
        - "keep": an EXISTING fact (by fact_id) is distinct enough to leave alone. Requires only \
        fact_id.
        Do NOT fabricate a "merge" for facts that aren't genuinely overlapping — when unsure, \
        "keep" both instead. A fact_id may be referenced by at most one op in your response.

        Output a JSON array where each item is:
        {"op": "merge"|"keep", "fact_ids": [string]|null, "fact_id": string|null, \
        "fact_text": string|null, \
        "fact_kind": "goal"|"interest"|"project"|"role_signal"|"other"|null, \
        "confidence": number|null, "reason": string|null}
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

        let ops: [ConsolidateOp]
        do {
            ops = try Self.parseOps(rawResponse)
        } catch {
            return emptyResult("Could not parse model response as JSON: \(error)")
        }

        guard !ops.isEmpty else {
            return emptyResult("Nothing to consolidate.")
        }

        let ownedIds = Set(existingFacts.map(\.id.rawValue))
        // No `fact_id` may be referenced by more than one op in this response — first reference
        // wins, later duplicate references are rejected (plan §6/§8/§10, this plan's own
        // determinism choice; no Rust precedent to defer to).
        var referencedIds: Set<String> = []
        var merged = 0
        var factsRetired = 0
        var kept = 0

        for op in ops {
            switch op.op {
            case "merge":
                guard let factIds = op.factIds, factIds.count >= 2 else {
                    continue // a single-id "merge" isn't a merge
                }
                guard factIds.allSatisfy({ ownedIds.contains($0) }) else {
                    continue // never trust an id the model wasn't shown / isn't this person's
                }
                guard factIds.allSatisfy({ !referencedIds.contains($0) }) else {
                    continue // duplicate reference within this response — reject the whole op
                }
                guard let factText = op.factText,
                      !factText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    continue // No-Fake-State: no empty consolidated fact
                }

                let factKind = FactKind(rawValue: op.factKind ?? "other") ?? .other
                let confidence = min(max(op.confidence ?? 0.0, 0.0), 1.0)
                let newFact = ProfileFact(
                    id: ProfileFactID(UUID().uuidString),
                    personId: personId,
                    factText: factText,
                    factKind: factKind,
                    sourceMeetingId: nil,
                    sourceSegmentRef: "Consolidated from \(factIds.count) existing facts",
                    origin: .attributed,
                    confidence: confidence,
                    sourceCount: 0,
                    status: .pending,
                    createdAt: now
                )
                // §6 step 4: the new N-ary primitive, NOT `markSupersedes` called N times (§4.1 —
                // that would overwrite the single `supersedesFactId` column and lose all but the
                // last pointer). No source row is recorded (§6 step 6) — there is no meeting/
                // segment evidence to attach.
                try await db.profileFacts.upsert(newFact)
                let oldFactIds = factIds.map { ProfileFactID($0) }
                try await db.profileFacts.recordSupersession(newFactId: newFact.id, oldFactIds: oldFactIds)

                referencedIds.formUnion(factIds)
                merged += 1
                factsRetired += factIds.count

            case "keep":
                guard let factId = op.factId, ownedIds.contains(factId) else {
                    continue
                }
                guard !referencedIds.contains(factId) else {
                    continue // duplicate reference within this response — reject
                }
                referencedIds.insert(factId)
                kept += 1

            default:
                continue // unknown op — skip, never guess
            }
        }

        let message = merged > 0 || kept > 0
            ? "Consolidated facts: \(merged) merge(s) created (\(factsRetired) old fact(s) " +
            "pending retirement on confirm), \(kept) kept as-is."
            : "No fact changes proposed."
        return ConsolidationResult(merged: merged, factsRetired: factsRetired, kept: kept, message: message)
    }

    // MARK: - JSON parsing (← `PersonReconciliation.ReconcileOp`, narrowed op vocabulary — §5)

    struct ConsolidateOp: Decodable {
        let op: String
        let factIds: [String]?
        let factId: String?
        let factText: String?
        let factKind: String?
        let confidence: Double?

        private enum CodingKeys: String, CodingKey {
            case op
            case factIds = "fact_ids"
            case factId = "fact_id"
            case factText = "fact_text"
            case factKind = "fact_kind"
            case confidence
            // `reason` is decoded by the model but never applied — kept for prompt fidelity only,
            // mirrors `PersonReconciliation.ReconcileOp`; intentionally not a CodingKey here since
            // nothing reads it.
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            op = try container.decode(String.self, forKey: .op)
            factIds = try container.decodeIfPresent([String].self, forKey: .factIds)
            factId = try container.decodeIfPresent(String.self, forKey: .factId)
            factText = try container.decodeIfPresent(String.self, forKey: .factText)
            factKind = try container.decodeIfPresent(String.self, forKey: .factKind)
            confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
        }
    }

    static func parseOps(_ raw: String) throws -> [ConsolidateOp] {
        let cleaned = PersonExtraction.stripCodeFences(raw)
        return try JSONDecoder().decode([ConsolidateOp].self, from: Data(cleaned.utf8))
    }
}
