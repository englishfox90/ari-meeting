//
//  Protocol.swift
//  apple-helper
//
//  Swift `Codable` mirror of the Apple Helper IPC wire protocol.
//
//  SINGLE SOURCE OF TRUTH lives on the Rust side, alongside the shared fixtures:
//  `frontend/src-tauri/src/apple/fixtures/*.json`. These types MUST decode those
//  exact fixture files byte-for-byte.
//
//  Unlike the ari-notch sidecar (snake_case), this protocol is camelCase, and
//  each response carries a DISTINCT `type` discriminator (`probeResult`,
//  `error`) — there is no single `"response"` tag.
//
//  Field names are spelled explicitly as CodingKeys (rather than relying on a
//  key strategy) so the mapping is auditable against the fixtures.
//
//  Forward-compatibility: any unrecognized `type` decodes to `.unknown` and
//  never throws.
//
//  Both enums provide decode AND encode so the tests can round-trip
//  symmetrically. In practice the sidecar DECODES requests and ENCODES
//  responses.
//

import Foundation

// MARK: - Inbound (Rust core → sidecar)

/// Requests sent from the Rust core down to the sidecar. Phase 1 subset.
enum AppleRequest: Equatable {
    /// Availability check — reply with `.probeResult`.
    case probe
    /// On-device summarization via FoundationModels — reply with `.summarizeResult`
    /// on success or `.error` on any failure.
    case summarize(text: String, instruction: String, maxTokens: Int)
    /// On-device speech-to-text of ONE complete audio segment via
    /// SpeechAnalyzer/SpeechTranscriber — reply with `.transcribeResult` on
    /// success or `.error` on any failure. `pcmBase64` is base64 of raw
    /// little-endian Float32, 16 kHz, mono PCM.
    case transcribe(pcmBase64: String, locale: String)
    /// On-device text embeddings via NaturalLanguage `NLEmbedding` — reply with
    /// `.embedResult` (one vector per input, in order) on success or `.error` on
    /// any failure.
    case embedBatch(texts: [String])
    /// Clean shutdown — the sidecar should `exit(0)`.
    case shutdown
    /// Install on-device model assets and STREAM real download progress. Unlike
    /// every other request, this yields MULTIPLE response lines: zero or more
    /// `.progress` lines followed by exactly one terminal `.ensureResult` (or
    /// `.error`). `which` selects the asset family (Phase 3: only `"speech"`).
    case ensureAssets(which: String)
    /// Forward-compat catch-all: any unknown `type` lands here.
    case unknown
}

// MARK: - Outbound (sidecar → Rust core)

/// Responses sent from the sidecar up to the Rust core.
enum AppleResponse: Equatable {
    /// Result of a `probe`: every boolean reflects a real framework query.
    case probeResult(
        speechAvailable: Bool,
        foundationAvailable: Bool,
        osOk: Bool,
        appleIntelligence: Bool,
        speechAssetsInstalled: Bool
    )
    /// Result of a `summarize`: the generated summary text.
    case summarizeResult(text: String)
    /// Result of a `transcribe`: the finalized transcript text and an OPTIONAL
    /// confidence in `[0, 1]`. `confidence` is `nil` (encoded as JSON null) when
    /// the SDK does not report one — never fabricated (No-Fake-State). Mirrors the
    /// Rust `Option<f32>`.
    case transcribeResult(text: String, confidence: Double?)
    /// Result of an `embedBatch`: one embedding vector per input text, in the
    /// SAME order. Each vector is 512-d (NLEmbedding sentence embedding).
    case embedResult(vectors: [[Float]])
    /// Incremental progress for an `ensureAssets` install: a real fraction in
    /// `[0, 1]`. Emitted zero or more times BEFORE the terminal `.ensureResult`.
    case progress(fraction: Double)
    /// Terminal result of an `ensureAssets` install: whether the assets are now
    /// installed. Emitted exactly once (on success) after any `.progress` lines.
    case ensureResult(installed: Bool)
    /// A failure or degraded condition, carried as a human-readable message.
    case error(message: String)
    /// Forward-compat catch-all: any unknown `type` lands here.
    case unknown
}

// MARK: - Coding keys (exact camelCase, matching the shared fixtures)

/// One flat key-space covering every field across every message.
private enum WireKey: String, CodingKey {
    case type
    // error
    case message
    // summarize (request) / summarizeResult (response) / transcribeResult (response)
    case text
    case instruction
    case maxTokens
    // transcribe (request)
    case pcmBase64
    case locale
    // transcribeResult (response)
    case confidence
    // embedBatch (request)
    case texts
    // embedResult (response)
    case vectors
    // probeResult
    case speechAvailable
    case foundationAvailable
    case osOk
    case appleIntelligence
    case speechAssetsInstalled
    // ensureAssets (request)
    case which
    // progress (response)
    case fraction
    // ensureResult (response)
    case installed
}

// MARK: - Inbound decoding

extension AppleRequest: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        // An unknown or absent `type` must degrade to `.unknown`, never throw.
        guard let type = try? c.decode(String.self, forKey: .type) else {
            self = .unknown
            return
        }
        switch type {
        case "probe":
            self = .probe
        case "summarize":
            self = .summarize(
                text: try c.decode(String.self, forKey: .text),
                instruction: try c.decode(String.self, forKey: .instruction),
                maxTokens: try c.decode(Int.self, forKey: .maxTokens)
            )
        case "transcribe":
            self = .transcribe(
                pcmBase64: try c.decode(String.self, forKey: .pcmBase64),
                locale: try c.decode(String.self, forKey: .locale)
            )
        case "embedBatch":
            self = .embedBatch(texts: try c.decode([String].self, forKey: .texts))
        case "shutdown":
            self = .shutdown
        case "ensureAssets":
            self = .ensureAssets(which: try c.decode(String.self, forKey: .which))
        default:
            self = .unknown
        }
    }
}

// MARK: - Inbound encoding
//
// Not used on the hot path (the sidecar only RECEIVES requests), but implemented
// so ProtocolTests can round-trip fixtures symmetrically.

extension AppleRequest: Encodable {
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: WireKey.self)
        switch self {
        case .probe:
            try c.encode("probe", forKey: .type)
        case let .summarize(text, instruction, maxTokens):
            try c.encode("summarize", forKey: .type)
            try c.encode(text, forKey: .text)
            try c.encode(instruction, forKey: .instruction)
            try c.encode(maxTokens, forKey: .maxTokens)
        case let .transcribe(pcmBase64, locale):
            try c.encode("transcribe", forKey: .type)
            try c.encode(pcmBase64, forKey: .pcmBase64)
            try c.encode(locale, forKey: .locale)
        case let .embedBatch(texts):
            try c.encode("embedBatch", forKey: .type)
            try c.encode(texts, forKey: .texts)
        case .shutdown:
            try c.encode("shutdown", forKey: .type)
        case let .ensureAssets(which):
            try c.encode("ensureAssets", forKey: .type)
            try c.encode(which, forKey: .which)
        case .unknown:
            try c.encode("unknown", forKey: .type)
        }
    }
}

// MARK: - Outbound encoding (the load-bearing shape)

extension AppleResponse: Encodable {
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: WireKey.self)
        switch self {
        case let .probeResult(speechAvailable, foundationAvailable, osOk, appleIntelligence, speechAssetsInstalled):
            try c.encode("probeResult", forKey: .type)
            try c.encode(speechAvailable, forKey: .speechAvailable)
            try c.encode(foundationAvailable, forKey: .foundationAvailable)
            try c.encode(osOk, forKey: .osOk)
            try c.encode(appleIntelligence, forKey: .appleIntelligence)
            try c.encode(speechAssetsInstalled, forKey: .speechAssetsInstalled)
        case let .summarizeResult(text):
            try c.encode("summarizeResult", forKey: .type)
            try c.encode(text, forKey: .text)
        case let .transcribeResult(text, confidence):
            try c.encode("transcribeResult", forKey: .type)
            try c.encode(text, forKey: .text)
            // Encode confidence as an explicit JSON null when absent (matches the
            // Rust `Option<f32>` shape) — never omit the key, never fabricate.
            if let confidence {
                try c.encode(confidence, forKey: .confidence)
            } else {
                try c.encodeNil(forKey: .confidence)
            }
        case let .embedResult(vectors):
            try c.encode("embedResult", forKey: .type)
            try c.encode(vectors, forKey: .vectors)
        case let .progress(fraction):
            try c.encode("progress", forKey: .type)
            try c.encode(fraction, forKey: .fraction)
        case let .ensureResult(installed):
            try c.encode("ensureResult", forKey: .type)
            try c.encode(installed, forKey: .installed)
        case let .error(message):
            try c.encode("error", forKey: .type)
            try c.encode(message, forKey: .message)
        case .unknown:
            try c.encode("unknown", forKey: .type)
        }
    }
}

// MARK: - Outbound decoding
//
// Implemented so ProtocolTests can decode the outbound fixtures (probe_result,
// error) and assert the expected case. The sidecar itself only SENDS responses,
// so this is test-facing, but it keeps the conformance symmetric.

extension AppleResponse: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        guard let type = try? c.decode(String.self, forKey: .type) else {
            self = .unknown
            return
        }
        switch type {
        case "probeResult":
            self = .probeResult(
                speechAvailable: try c.decode(Bool.self, forKey: .speechAvailable),
                foundationAvailable: try c.decode(Bool.self, forKey: .foundationAvailable),
                osOk: try c.decode(Bool.self, forKey: .osOk),
                appleIntelligence: try c.decode(Bool.self, forKey: .appleIntelligence),
                speechAssetsInstalled: try c.decode(Bool.self, forKey: .speechAssetsInstalled)
            )
        case "summarizeResult":
            self = .summarizeResult(text: try c.decode(String.self, forKey: .text))
        case "transcribeResult":
            // `confidence` may be present-and-numeric, JSON null, or absent — all
            // three degrade to `nil` via decodeIfPresent (null → nil).
            self = .transcribeResult(
                text: try c.decode(String.self, forKey: .text),
                confidence: try c.decodeIfPresent(Double.self, forKey: .confidence)
            )
        case "embedResult":
            self = .embedResult(vectors: try c.decode([[Float]].self, forKey: .vectors))
        case "progress":
            self = .progress(fraction: try c.decode(Double.self, forKey: .fraction))
        case "ensureResult":
            self = .ensureResult(installed: try c.decode(Bool.self, forKey: .installed))
        case "error":
            self = .error(message: try c.decode(String.self, forKey: .message))
        default:
            self = .unknown
        }
    }
}
