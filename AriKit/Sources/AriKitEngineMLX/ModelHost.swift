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

    /// Cache of the *in-flight or completed load Task* per repo id — NOT the resolved value.
    /// Caching the `Task` (inserted synchronously, before the first `await`) is what makes the
    /// cache single-flight under actor reentrancy: a value cache would let a second caller observe
    /// an empty dict while the first load is suspended at its `await` and start a duplicate
    /// multi-GB download. Every concurrent caller for the same repo id awaits the same `Task`.
    private var loads: [String: Task<ModelContainer, Error>] = [:]

    public init() {}

    /// Returns the cached `ModelContainer` for `repoId`, loading (and downloading, if needed) it
    /// exactly once. Concurrent callers requesting the same `repoId` before the first load
    /// completes all await the same in-flight load `Task` — never a second download. A *failed*
    /// load is not cached (the `Task` is dropped), so a later call can retry after a transient
    /// download/network failure.
    ///
    /// Note: only the first caller's `progressHandler` is wired to the underlying load; concurrent
    /// callers awaiting the same in-flight `Task` do not receive progress callbacks (progress is a
    /// best-effort side channel, not part of the result contract).
    public func container(
        forRepoId repoId: String,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> ModelContainer {
        if let existing = loads[repoId] {
            return try await existing.value
        }

        let load = Task<ModelContainer, Error> {
            // ← the S1 spike's downloader/tokenizer-loader macros (`Entry.swift:99-100`).
            let downloader = #hubDownloader()
            let tokenizerLoader = #huggingFaceTokenizerLoader()
            return try await loadModelContainer(
                from: downloader,
                using: tokenizerLoader,
                id: repoId,
                progressHandler: progressHandler
            )
        }
        // Insert synchronously — before any suspension — so a reentrant caller sees this Task.
        loads[repoId] = load

        do {
            return try await load.value
        } catch {
            // Don't cache failures — allow a retry to re-attempt the load.
            loads[repoId] = nil
            throw error
        }
    }

    /// Test/debug seam — drops a cached load so a subsequent `container(forRepoId:)` call
    /// reloads it. Not used by production code paths.
    public func evict(repoId: String) {
        loads[repoId] = nil
    }
}
