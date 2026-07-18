//
//  EmbedBackend.swift — the embedder selector (plan §7, ← embedding.rs:36).
//
//  Which local embedder produces vectors for semantic search. Chosen by the persisted
//  `recall_embedder` setting; unknown/unset → `.apple` (the default, no download). Each backend's
//  `modelTag` identifies its (incomparable) vector space so switching embedders forces a clean
//  re-embed. The Slice-1 port is pure enum + string mapping; the async embedders that consume this
//  land in Slice 3.
//
import Foundation

/// The configured recall embedder backend (← `EmbedBackend`).
public enum EmbedBackend: Sendable, Hashable, CaseIterable {
    case apple
    case nomicGguf
    case ollama

    /// Parse the persisted `recall_embedder` value; unknown / unset → `.apple` (← `from_setting`).
    public static func from(setting value: String?) -> EmbedBackend {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "nomic-gguf", "nomic":
            .nomicGguf
        case "ollama":
            .ollama
        default:
            .apple
        }
    }

    /// Canonical setting id (what the frontend selector persists) (← `id`).
    public var id: String {
        switch self {
        case .apple: "apple"
        case .nomicGguf: "nomic-gguf"
        case .ollama: "ollama"
        }
    }

    /// Stable per-backend tag stored on each chunk so an embedder change is detected and the
    /// meeting re-embedded (← `model_tag`).
    public var modelTag: String {
        switch self {
        case .apple: "apple-nl"
        case .nomicGguf: "nomic-embed-text-v1.5"
        case .ollama: "ollama:nomic-embed-text"
        }
    }
}
