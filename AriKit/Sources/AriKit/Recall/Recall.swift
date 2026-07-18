//
//  Recall.swift — the recall subsystem namespace + shared Unicode-scalar helpers.
//
//  Swift port of the Rust `ari_engine::recall` subsystem — the "Ask Meetings" hybrid-retrieval
//  engine and its LOAD-BEARING safety shell (loopback-only local model, bounded context,
//  never-invents-citations, sources computed separately from the answer text). Slice 1 (this
//  and the sibling `Shell/`, `Citations/`, `Chunking/`, `Embedding/` files) is the pure domain
//  layer: deterministic value transforms over `Sendable` value types with zero Store schema,
//  zero sidecar, and zero LLM — a bit-for-bit behavioral port of the frozen Rust source
//  (docs/plans/arikit-recall.md §5, Slice 1). Later slices (index, search, indexer, ask store,
//  people context, orchestrator) attach behind this shell as their subsystems land.
//
//  The invariants preserved here (plan principle 6): loopback-only (`isLoopbackOllamaEndpoint`),
//  bounded context (`boundedMiddleExcerpt` + the `RecallBounds` caps), never-invents-citations
//  (`verifySourceCitations`), and out-of-scope refusal (`isUnsupportedRecallQuestion`).
//
import Foundation

/// The recall subsystem namespace. Slice-1 pure functions hang off this as `static` methods; the
/// wire value types (`RecallSource`, `RecallResponse`, …) and `EmbedBackend` are top-level types.
public enum Recall {}

// MARK: - Unicode-scalar text helpers (Rust `char` == Unicode scalar)

extension Recall {
    /// Rust `str::chars()` iterates Unicode scalar values, so every char-counting / char-indexing
    /// helper in this subsystem measures in scalars (not `Character` grapheme clusters) to
    /// reproduce the Rust arithmetic exactly.
    static func scalars(_ text: String) -> [Unicode.Scalar] {
        Array(text.unicodeScalars)
    }

    /// Reassemble a `String` from a sequence of Unicode scalars.
    static func string(fromScalars scalars: some Sequence<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    /// Rust `char::is_ascii_digit` — strictly `0`…`9`, never other Unicode digit forms.
    static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x30 && scalar.value <= 0x39
    }
}

/// Errors surfaced by the pure recall shell. Mirrors the `Err(String)` returns of the Rust
/// `build_local_recall_history` / `api_answer_meetings_locally_impl` boundary.
public enum RecallError: Error, Equatable, Sendable {
    /// A chat-history turn carried a role other than `user`/`assistant` (never trusted).
    case unsupportedHistoryRole
}

extension RecallError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedHistoryRole:
            "Meeting chat history contains an unsupported role."
        }
    }
}
