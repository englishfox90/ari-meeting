//
//  EmbedBackend.swift — the embedder selector (plan §7, ← embedding.rs:36).
//
//  The Swift app ships a SINGLE local embedder: Apple's on-device `NLContextualEmbedding`
//  (`AppleContextualEmbedder`) — no download, no Ollama, no GGUF model. The persisted
//  `recall_embedder` setting is tolerated for backward compatibility with legacy stored values
//  ("nomic-gguf", "ollama", or unset) but ALWAYS resolves to `.apple` — there is no other case to
//  choose. `modelTag` identifies the vector space so a change of the underlying model (as happened
//  moving from `NLEmbedding` to `NLContextualEmbedding`) forces a clean re-embed.
//
import Foundation

/// The configured recall embedder backend (← `EmbedBackend`). A single-case enum on purpose: this
/// product now ships exactly one on-device embedder.
public enum EmbedBackend: Sendable, Hashable, CaseIterable {
    case apple

    /// Parse the persisted `recall_embedder` value. Any value — including legacy
    /// "nomic-gguf"/"ollama"/`nil` — resolves to `.apple` (← `from_setting`).
    public static func from(setting _: String?) -> EmbedBackend {
        .apple
    }

    /// Canonical setting id (what the frontend selector persists) (← `id`).
    public var id: String {
        "apple"
    }

    /// Stable per-backend tag stored on each chunk so a model change is detected and the meeting
    /// re-embedded (← `model_tag`). Changed from "apple-nl" (the old `NLEmbedding`-backed tag) to
    /// "apple-contextual" when the embedder moved to `NLContextualEmbedding` — this alone forces
    /// every previously-indexed meeting to re-embed on the next reindex.
    public var modelTag: String {
        "apple-contextual"
    }
}
