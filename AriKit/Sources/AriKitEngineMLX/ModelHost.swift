//
//  ModelHost.swift — load-once `ModelContainer` cache, keyed by HF repo id
//  (plan §1.3, docs/plans/arikit-engine-extras.md, Track E).
//
//  ← the S1 spike's per-run `loadModelContainer(...)` call (`Entry.swift:103-113`), lifted into a
//  cache so a long-lived process (the app) never re-downloads/re-loads the same model per
//  request — S1 measured a ~2.6s warm-load (`swift-migration-plan.md:98`), which is fine once,
//  ruinous per summary.
//
//  `actor` isolation gives the cache dictionary safe concurrent access for free — no
//  `@unchecked Sendable`/manual locking needed. `ModelContainer` itself is a `Sendable` final
//  class (mlx-swift-lm `ModelContainer.swift:32`), so it crosses the actor boundary cleanly once
//  loaded.
//
import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Tokenizers

/// Caches one `ModelContainer` per HF repo id for the lifetime of the process. Never reloads a
/// repo id it has already loaded — callers that want a fresh copy should use a distinct
/// `ModelHost` instance (tests do this via `init()`; production uses `.shared`).
public actor ModelHost {
    /// Production singleton — one warm model set shared by every `MLXClient` in the process.
    public static let shared = ModelHost()

    private var containers: [String: ModelContainer] = [:]

    public init() {}

    /// Returns the cached `ModelContainer` for `repoId`, loading (and downloading, if needed) it
    /// exactly once. Concurrent callers requesting the same `repoId` before the first load
    /// completes will each await the same in-flight load (actor-serialized), not race a second
    /// download.
    public func container(
        forRepoId repoId: String,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> ModelContainer {
        if let cached = containers[repoId] {
            return cached
        }

        // ← the S1 spike's downloader/tokenizer-loader macros (`Entry.swift:99-100`).
        let downloader = #hubDownloader()
        let tokenizerLoader = #huggingFaceTokenizerLoader()

        let container = try await loadModelContainer(
            from: downloader,
            using: tokenizerLoader,
            id: repoId,
            progressHandler: progressHandler
        )
        containers[repoId] = container
        return container
    }

    /// Test/debug seam — drops a cached container so a subsequent `container(forRepoId:)` call
    /// reloads it. Not used by production code paths.
    public func evict(repoId: String) {
        containers.removeValue(forKey: repoId)
    }
}
