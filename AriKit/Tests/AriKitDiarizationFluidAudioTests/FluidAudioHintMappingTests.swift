//
//  FluidAudioHintMappingTests.swift — D7 (docs/plans/arikit-diarization.md §5): pure
//  `SpeakerCountHint` → FluidAudio clustering-constraint mapping. No model download.
//
#if os(macOS)
    @testable import AriKitDiarizationFluidAudio
    import AriKit
    import Testing

    @Suite("FluidAudioHintMapping")
    struct FluidAudioHintMappingTests {
        @Test("exact(n) maps to numSpeakers = n, no min/max")
        func exactMapsToNumSpeakers() {
            let constraints = FluidAudioHintMapping.clusteringConstraints(for: .exact(3))
            #expect(constraints.numSpeakers == 3)
            #expect(constraints.minSpeakers == nil)
            #expect(constraints.maxSpeakers == nil)
        }

        @Test("upperBound(n) maps to min = 1, max = n, no numSpeakers (H3)")
        func upperBoundMapsToMinOneMaxN() {
            let constraints = FluidAudioHintMapping.clusteringConstraints(for: .upperBound(6))
            #expect(constraints.numSpeakers == nil)
            #expect(constraints.minSpeakers == 1)
            #expect(constraints.maxSpeakers == 6)
        }

        @Test("automatic maps to no constraint (rig-only)")
        func automaticMapsToNoConstraint() {
            let constraints = FluidAudioHintMapping.clusteringConstraints(for: .automatic)
            #expect(constraints.numSpeakers == nil)
            #expect(constraints.minSpeakers == nil)
            #expect(constraints.maxSpeakers == nil)
        }
    }
#endif
