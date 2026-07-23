//
//  DiarizationProviderPrepareProgressTests.swift — acceptance test 4 (docs/plans/
//  onboarding-install-flow.md §7): a regression guard for the `prepare(progress:)` signature
//  widening (§2.2) — confirms the historical zero-arg `prepare()` call shape
//  (`DiarizationService.swift:122`) still compiles and behaves identically via the default-arg
//  extension, i.e. `prepare()` really is `prepare(progress: nil)`.
//
import os
import Testing
@testable import AriKit

private actor FakeProgressReportingProvider: DiarizationProvider {
    let providerName = "fake-progress"
    let embeddingModel = "fake-embedding-space"
    private(set) var lastProgressArgumentWasNil: Bool?

    func isAvailable() async -> Bool {
        true
    }

    func prepare(progress: (@Sendable (Double) -> Void)?) async throws {
        lastProgressArgumentWasNil = (progress == nil)
        progress?(1.0)
    }

    func diarize(
        samples _: [Float],
        hint _: SpeakerCountHint,
        progress _: (@Sendable (Double) -> Void)?
    ) async throws -> DiarizationOutput {
        DiarizationOutput(segments: [], clusters: [], embeddingModel: embeddingModel, dim: 0)
    }
}

@Suite("DiarizationProvider.prepare(progress:) widening")
struct DiarizationProviderPrepareProgressTests {
    @Test("the historical zero-arg prepare() call compiles and forwards nil progress")
    func zeroArgPrepareForwardsNilProgress() async throws {
        let provider = FakeProgressReportingProvider()
        try await provider.prepare()
        #expect(await provider.lastProgressArgumentWasNil == true)
    }

    @Test("prepare(progress:) with a real closure receives real progress, never a fabricated value")
    func prepareWithProgressReceivesRealValue() async throws {
        let provider = FakeProgressReportingProvider()
        // `OSAllocatedUnfairLock` (not `@unchecked Sendable`/`nonisolated(unsafe)`): the
        // Synchronization-safe primitive for a `@Sendable` closure that must record a value
        // synchronously, called from the fake provider's own actor-isolated `prepare` body — the
        // callback itself runs synchronously within `prepare`'s `await`, so no `Task`/sleep is
        // needed to observe it.
        let collected = OSAllocatedUnfairLock<[Double]>(initialState: [])
        try await provider.prepare(progress: { value in
            collected.withLock { $0.append(value) }
        })
        #expect(await provider.lastProgressArgumentWasNil == false)
        #expect(collected.withLock { $0 } == [1.0])
    }
}
