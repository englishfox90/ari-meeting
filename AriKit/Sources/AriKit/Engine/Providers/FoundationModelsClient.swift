//
//  FoundationModelsClient.swift — the in-process on-device provider (plan §2.3, Slice D).
//
//  Absorbs the `apple-helper` sidecar's `summarize` mode IN-PROCESS (`swift-migration-plan.md:255`,
//  "Absorbed in-process") — no spawn, no NDJSON round trip. ← `ari-engine/src/apple/helper.rs::summarize`
//  + `apple-helper/Sources/apple-helper/Summarize.swift`, using `FoundationModels.LanguageModelSession`
//  directly: `system` → `instructions`, `user` → `prompt` (plan §2.3 mapping — the LLMClient contract
//  already carries the full user-facing prompt, so unlike the sidecar's own doubled
//  `"\(instruction)\n\nTranscript:\n\(text)"` composition, we do not re-embed `system` into `user`).
//
//  Short-context floor only (4k window, `service.rs:464` → threshold 3500) — the caller
//  (`SummaryGenerator`/`SummaryService`, Slice F/G) is responsible for routing large transcripts to
//  map-reduce chunking before reaching this client; this client itself does not chunk.
//
//  No-Fake-State (plan §7): if the on-device model is unavailable, this THROWS
//  `LLMError.providerUnavailable` — it never substitutes fabricated text. Output additionally passes
//  through `PlaceholderTimestampCleanup.strip` (← `apple/text_cleanup.rs`) to remove the literal
//  `MM:SS`/`[MM:SS]`/`(HH:MM:SS)` placeholder tokens the compact on-device model tends to echo
//  verbatim instead of a real digit timestamp.
//
//  No streaming (← `llm_stream.rs:69-97`: FoundationModels has no incremental output path here) —
//  relies on the `LLMClient` extension's single-yield fallback (`LLMClient.swift`).
//
import Foundation
import FoundationModels

public struct FoundationModelsClient: LLMClient {
    public let kind: ProviderKind = .appleFoundation

    /// Default on-device generation budget when the caller supplies none (← `llm_client.rs:175`,
    /// the ONLY call site of `apple::helper::summarize`: `max_tokens.unwrap_or(512)`). Resolved
    /// here, one layer above `realRespond`/the injected `respond` seam, so the common case (no
    /// explicit `LLMRequest.maxTokens`) is bounded exactly like Rust instead of generating
    /// unbounded output.
    static let defaultMaxTokens = 512

    /// Bounds the whole on-device generation exchange (← `SUMMARIZE_TIMEOUT`,
    /// `ari-engine/src/apple/helper.rs:32`, raced at `helper.rs:192` via `send_oneshot`) so a
    /// wedged `LanguageModelSession` never stalls the calling summary pipeline forever.
    static let generationTimeout: Duration = .seconds(180)

    /// Injectable probe over on-device model availability (← `SystemLanguageModel.default
    /// .availability`, mirrored from `apple-helper/Sources/apple-helper/Summarize.swift:64-71` /
    /// `Probe.swift:74-94`). Returns `nil` when available, or the honest reason message when not —
    /// decoupled from the live singleton so tests can force the unavailable path headlessly, without
    /// requiring Apple Intelligence to be enabled on the machine running `swift test` (plan §6 Slice
    /// D: "device-gated smoke test only" — real generation is never exercised by the default suite).
    let unavailableReason: @Sendable () -> String?

    /// Injectable generation seam (← `LanguageModelSession(instructions:).respond(to:options:)`,
    /// `Summarize.swift:75-97`) so tests never spin up a real on-device session.
    let respond: @Sendable (_ system: String, _ user: String, _ maxTokens: Int?) async throws -> String

    /// Per-instance override of `Self.generationTimeout`, defaulted to the real 180s production
    /// budget. Injectable ONLY so `wedgedRespondTimesOutInsteadOfHangingForever` can exercise the
    /// timeout race on a test-scale duration instead of actually waiting 180 real seconds —
    /// production code always gets the real default.
    let timeout: Duration

    public init(config: ProviderConfig) throws {
        guard config.kind == .appleFoundation else {
            throw LLMError.notConfigured(
                "FoundationModelsClient only supports .appleFoundation, got \(config.kind)"
            )
        }
        unavailableReason = { Self.realUnavailableReason() }
        respond = { system, user, maxTokens in
            try await Self.realRespond(system: system, user: user, maxTokens: maxTokens)
        }
        timeout = Self.generationTimeout
    }

    /// Test-only initializer with injected seams — mirrors `ClaudeCLIClient`'s `binaryResolver:`
    /// pattern (plan §6 Slice D) so `FoundationModelsAvailabilityTests` can force the
    /// unavailable/available/failure paths headlessly.
    init(
        unavailableReason: @escaping @Sendable () -> String?,
        respond: @escaping @Sendable (_ system: String, _ user: String, _ maxTokens: Int?) async throws -> String,
        timeout: Duration = FoundationModelsClient.generationTimeout
    ) {
        self.unavailableReason = unavailableReason
        self.respond = respond
        self.timeout = timeout
    }

    // MARK: - LLMClient

    public func generate(_ request: LLMRequest) async throws -> String {
        try Task.checkCancellation()

        // Gate on real availability FIRST (mirrors `Summarize.swift:64-71`). If the on-device model
        // can't run, say WHY — never proceed to fabricate a summary (No-Fake-State, plan §7).
        if let reason = unavailableReason() {
            throw LLMError.providerUnavailable(reason)
        }

        // ← `llm_client.rs:175`: `max_tokens.unwrap_or(512)` — resolve the default budget here,
        // before the respond seam, so a caller that supplies no explicit budget (the common case)
        // is still bounded like Rust instead of generating unboundedly.
        let effectiveMaxTokens = request.maxTokens ?? Self.defaultMaxTokens

        let raw: String
        do {
            raw = try await Self.runWithTimeout(timeout) {
                try await respond(request.system, request.user, effectiveMaxTokens)
            }
        } catch let error as LLMError {
            throw error
        } catch {
            // A thrown `GenerationError` (guardrail refusal, context overflow, …) is a generation
            // failure, not a device-availability problem — `.requestFailed`, distinct from the
            // pre-flight `.providerUnavailable` check above (← `Summarize.swift:94-102`).
            throw LLMError.requestFailed("on-device generation failed: \(error.localizedDescription)")
        }

        // Empty output is a failure, not a summary (← `Summarize.swift:104-108`).
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LLMError.requestFailed("on-device model returned an empty summary")
        }

        return PlaceholderTimestampCleanup.strip(trimmed)
    }

    // No `stream` override — see the file header; the default `LLMClient` extension's single-yield
    // fallback applies.

    /// Races `operation` against `timeout`, mirroring `ClaudeCLIClient.run`'s
    /// `withThrowingTaskGroup` timeout race (`ClaudeCLIClient.swift:159-179`) and Rust's
    /// `send_oneshot(&req, SUMMARIZE_TIMEOUT, cancellation)` (`apple/helper.rs:192`) — a wedged
    /// on-device session throws instead of hanging the caller forever.
    private static func runWithTimeout(
        _ timeout: Duration,
        operation: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw LLMError.requestFailed("on-device generation timed out after 180s")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw LLMError.requestFailed("on-device generation produced no result")
            }
            return result
        }
    }

    // MARK: - Real seams (production only; never exercised by the headless test suite)

    private static func realUnavailableReason() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case let .unavailable(reason):
            return unavailabilityMessage(reason)
        @unknown default:
            return "the Apple on-device model is unavailable for an unrecognized reason"
        }
    }

    private static func realRespond(system: String, user: String, maxTokens: Int?) async throws -> String {
        // ← `Summarize.swift:75-97`: the caller's system prompt becomes the session instructions;
        // the caller's user prompt is passed through verbatim (see file header for the delta from
        // apple-helper's own doubled composition).
        let session = LanguageModelSession(instructions: system)
        let options = GenerationOptions(
            maximumResponseTokens: (maxTokens ?? 0) > 0 ? maxTokens : nil
        )
        let response = try await session.respond(to: user, options: options)
        return response.content
    }

    /// Human-readable, truthful reason for an unavailable system language model (← `Summarize.swift
    /// :112-126`). Pure — testable directly with literal `UnavailableReason` cases, no live model
    /// needed (plan §6: "asserted via an injectable availability check / seam so it runs
    /// headlessly").
    static func unavailabilityMessage(
        _ reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> String {
        switch reason {
        case .appleIntelligenceNotEnabled:
            "Apple Intelligence is not enabled — enable it in System Settings to use on-device summarization"
        case .deviceNotEligible:
            "this device is not eligible for Apple Intelligence on-device summarization"
        case .modelNotReady:
            "the Apple on-device model is not ready yet (still downloading or preparing) — try again shortly"
        @unknown default:
            "the Apple on-device model is unavailable for an unrecognized reason"
        }
    }
}

// ============================================================================
// PlaceholderTimestampCleanup — ← `ari-engine/src/apple/text_cleanup.rs::strip_placeholder_timestamps`
// ============================================================================

/// Strip never-legitimate placeholder timestamps (`MM:SS`, `[MM:SS]`, `(HH:MM:SS)`, …) that a weak
/// on-device model echoes verbatim, then tidy the small residue (empty `[]`/`()`, doubled spaces, a
/// space before punctuation) WITHOUT disturbing line structure (markdown tables/lists are preserved).
///
/// Pure and side-effect free. Only touches literal H/M/S time shapes — anything containing digits (a
/// real timestamp) is left exactly as-is. 1:1 port of `text_cleanup.rs`; order matters (wrapped tokens
/// first so their brackets go too, then bare tokens, then residue cleanup).
enum PlaceholderTimestampCleanup {
    // Regex literals are computed properties (NOT stored `static let`s): `Regex<Output>` does not
    // conform to `Sendable` in this SDK, so a stored global would fail the Swift 6 strict-concurrency
    // "shared mutable state" check. Recompiling a literal regex per call is cheap and this runs
    // post-hoc on summary output, never on a hot path (plan §3).

    /// A placeholder time token wrapped in brackets or parentheses, e.g. `[MM:SS]`, `(MM:SS)`,
    /// `[HH:MM:SS]`. Components are the literal letters H/M/S only.
    private static var wrapped: Regex<Substring> {
        /[\[(]\s*[HMS]{1,2}:[MS]{2}(?::[MS]{2})?\s*[\])]/
    }

    /// A bare placeholder time token, e.g. `MM:SS`, `HH:MM:SS`, not wrapped.
    private static var bare: Regex<Substring> {
        /\b[HMS]{1,2}:[MS]{2}(?::[MS]{2})?\b/
    }

    /// Empty brackets/parentheses left behind after removing a wrapped token, e.g. `[]`, `[ ]`,
    /// `()`, `(  )`.
    private static var emptyDelimiters: Regex<Substring> {
        /[\[(]\s*[\])]/
    }

    /// Collapse runs of spaces/tabs (not newlines) into a single space.
    private static var multipleSpacesOrTabs: Regex<Substring> {
        /[ \t]{2,}/
    }

    /// A run of spaces directly before sentence punctuation after a removal, e.g. `analysis .` →
    /// `analysis.`.
    private static var spaceBeforePunctuation: Regex<Substring> {
        /[ ]+[.,;:]/
    }

    static func strip(_ text: String) -> String {
        var result = text.replacing(wrapped, with: "")
        result = result.replacing(bare, with: "")
        result = result.replacing(emptyDelimiters, with: "")
        result = result.replacing(multipleSpacesOrTabs, with: " ")
        result = result.replacing(spaceBeforePunctuation) { match in
            // The match is "<spaces><one punctuation char>" — keep only the trailing punctuation
            // (← Rust's capture-group replacement `"$1"`, `text_cleanup.rs:46-47`).
            match.output.suffix(1)
        }

        // Trim trailing spaces/tabs on each line without collapsing blank lines or touching
        // markdown table pipes' meaningful structure.
        return result
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String(trimmingTrailingSpacesAndTabs($0)) }
            .joined(separator: "\n")
    }

    private static func trimmingTrailingSpacesAndTabs(_ line: Substring) -> Substring {
        var end = line.endIndex
        while end > line.startIndex {
            let previous = line.index(before: end)
            guard line[previous] == " " || line[previous] == "\t" else { break }
            end = previous
        }
        return line[line.startIndex ..< end]
    }
}
