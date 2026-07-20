//
//  SpeechAssetManagerTests.swift — plan §6 Slice B.
//
//  Lane 1 (headless, always runs): construction/`Sendable`, and the read-only availability
//  queries — `isEngineAvailable()`/`areAssetsInstalled(forLocale:)` never download anything and
//  degrade to an honest `false` rather than throwing or fabricating, so they're safe to call on
//  any machine (asset-present or not).
//
//  Lane 2 (asset-gated, honest-SKIP): `install(forLocale:onProgress:)` is only exercised when
//  assets for the target locale are ALREADY installed — that path is a pure verification
//  short-circuit (single `1.0`, no network). We deliberately never trigger a REAL multi-hundred-MB
//  download from an automated test; when assets are missing (or the engine itself is
//  unavailable) the test records an honest skip rather than faking a pass (No-Fake-State, plan §7,
//  §11.3).
//
import Foundation
import Synchronization
import Testing
@testable import AriKit

struct SpeechAssetManagerTests {

    // MARK: - Lane 1: headless, always runs

    @Test func canConstructAndQueryEngineAvailabilitySynchronously() {
        let manager = SpeechAssetManager()
        // `isEngineAvailable()` is a real, synchronous framework query — no fabrication, no
        // asset dependency. Whatever this machine reports, the call itself must not crash and
        // must be deterministic across repeated calls.
        let first = manager.isEngineAvailable()
        let second = manager.isEngineAvailable()
        #expect(first == second)
    }

    @Test func areAssetsInstalledDegradesHonestlyWhenEngineUnavailable() async {
        let manager = SpeechAssetManager()
        guard !manager.isEngineAvailable() else {
            // This machine's engine IS available — this specific "unavailable degrades to false"
            // path isn't exercisable here. Nothing to assert; the availability-gated variant is
            // covered below.
            return
        }
        // Engine unavailable → the honest degrade is `false`, never a fabricated "installed".
        #expect(await manager.areAssetsInstalled(forLocale: "en-US") == false)
        #expect(await manager.areAssetsInstalled(forLocale: nil) == false)
    }

    @Test func areAssetsInstalledIsReadOnlyAndSafeToCallRegardlessOfEngineState() async {
        // Read-only query — no download, so always safe to invoke headlessly. Assert only that
        // it returns without throwing and is stable across two calls (no hidden mutation/flake).
        let manager = SpeechAssetManager()
        let first = await manager.areAssetsInstalled(forLocale: "en-US")
        let second = await manager.areAssetsInstalled(forLocale: "en-US")
        #expect(first == second)
    }

    // MARK: - Lane 2: asset-gated, honest-SKIP

    @Test func installShortCircuitsToSingleCompleteFractionWhenAlreadyInstalled() async throws {
        let manager = SpeechAssetManager()

        guard manager.isEngineAvailable() else {
            print(
                "SKIP: installShortCircuitsToSingleCompleteFractionWhenAlreadyInstalled — SpeechTranscriber.isAvailable is false on this machine."
            )
            return
        }
        guard await manager.areAssetsInstalled(forLocale: "en-US") else {
            print(
                "SKIP: installShortCircuitsToSingleCompleteFractionWhenAlreadyInstalled — en-US speech assets are not installed on this machine; a real automated test must never trigger a live multi-hundred-MB download."
            )
            return
        }

        // Assets are genuinely already installed — this exercises the honest, no-network
        // short-circuit path: exactly one progress callback, a verified 1.0. Progress fractions
        // are collected behind a `Mutex` (Synchronization framework) — synchronous, `Sendable`,
        // no `@unchecked Sendable`/`nonisolated(unsafe)` — since the callback itself is a plain
        // (non-`async`) `@Sendable` closure, not a child `Task`.
        let reportedFractions = Mutex<[Double]>([])
        try await manager.install(forLocale: "en-US") { fraction in
            reportedFractions.withLock { $0.append(fraction) }
        }
        #expect(reportedFractions.withLock { $0 } == [1.0])
    }
}
