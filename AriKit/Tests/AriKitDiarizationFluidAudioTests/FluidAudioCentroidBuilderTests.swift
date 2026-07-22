//
//  FluidAudioCentroidBuilderTests.swift — D7 (docs/plans/arikit-diarization.md §5):
//  `centroidBuildIsDurationWeightedAndUnit` — the centroid a FluidAudio result builds per
//  speaker is a duration-weighted mean of that speaker's segment embeddings, re-L2-normalized.
//  Pure, no model download.
//
#if os(macOS)
    @testable import AriKitDiarizationFluidAudio
    import AriKit
    import FluidAudio
    import Testing

    @Suite("FluidAudioCentroidBuilder")
    struct FluidAudioCentroidBuilderTests {
        @Test("a lone segment's centroid is its own L2-normalized embedding")
        func singleSegmentCentroidIsNormalizedEmbedding() {
            let segments = [
                TimedSpeakerSegment(
                    speakerId: "S1", embedding: [3, 4], startTimeSeconds: 0, endTimeSeconds: 2, qualityScore: 1
                )
            ]

            let clusters = FluidAudioCentroidBuilder.buildClusters(from: segments)

            #expect(clusters.count == 1)
            let cluster = try! #require(clusters.first)
            #expect(cluster.key == "S1")
            #expect(cluster.speechSecs == 2.0)
            #expect(abs(cluster.centroid[0] - 0.6) < 0.0001)
            #expect(abs(cluster.centroid[1] - 0.8) < 0.0001)
        }

        @Test("centroidBuildIsDurationWeightedAndUnit")
        func centroidBuildIsDurationWeightedAndUnit() {
            // S1: a 2s segment along +x and a 1s segment along +y — the 2s segment should
            // dominate the resulting direction (duration-weighted, not a plain average).
            let segments = [
                TimedSpeakerSegment(
                    speakerId: "S1", embedding: [1, 0], startTimeSeconds: 0, endTimeSeconds: 2, qualityScore: 1
                ),
                TimedSpeakerSegment(
                    speakerId: "S1", embedding: [0, 1], startTimeSeconds: 2, endTimeSeconds: 3, qualityScore: 1
                ),
                TimedSpeakerSegment(
                    speakerId: "S2", embedding: [0, -1], startTimeSeconds: 0, endTimeSeconds: 5, qualityScore: 1
                )
            ]

            let clusters = FluidAudioCentroidBuilder.buildClusters(from: segments)

            #expect(clusters.count == 2)
            let s1 = try! #require(clusters.first { $0.key == "S1" })
            let s2 = try! #require(clusters.first { $0.key == "S2" })

            #expect(s1.speechSecs == 3.0)
            #expect(s2.speechSecs == 5.0)

            // Duration-weighted mean of ([1,0], w=2) and ([0,1], w=1) is [2/3, 1/3], normalized.
            let expectedNorm = (2.0 / 3.0 * 2.0 / 3.0 + 1.0 / 3.0 * 1.0 / 3.0).squareRoot()
            let expectedX = Float((2.0 / 3.0) / expectedNorm)
            let expectedY = Float((1.0 / 3.0) / expectedNorm)
            #expect(abs(s1.centroid[0] - expectedX) < 0.0001)
            #expect(abs(s1.centroid[1] - expectedY) < 0.0001)

            // Every centroid is unit-length (L2-normalized).
            for cluster in clusters {
                let magnitude = cluster.centroid.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
                #expect(abs(magnitude - 1.0) < 0.0001)
            }

            #expect(s2.centroid[0] == 0)
            #expect(s2.centroid[1] == -1)
        }

        @Test("zero-duration and empty-embedding segments are excluded, never fabricated into a cluster")
        func degenerateSegmentsAreExcluded() {
            let segments = [
                TimedSpeakerSegment(
                    speakerId: "S1", embedding: [], startTimeSeconds: 0, endTimeSeconds: 2, qualityScore: 1
                ),
                TimedSpeakerSegment(
                    speakerId: "S2", embedding: [1, 0], startTimeSeconds: 0, endTimeSeconds: 0, qualityScore: 1
                )
            ]

            let clusters = FluidAudioCentroidBuilder.buildClusters(from: segments)

            #expect(clusters.isEmpty)
        }

        @Test("clusters are returned in stable key-sorted order")
        func clustersAreKeySorted() {
            let segments = [
                TimedSpeakerSegment(
                    speakerId: "S2", embedding: [1, 0], startTimeSeconds: 0, endTimeSeconds: 1, qualityScore: 1
                ),
                TimedSpeakerSegment(
                    speakerId: "S1", embedding: [0, 1], startTimeSeconds: 1, endTimeSeconds: 2, qualityScore: 1
                )
            ]

            let clusters = FluidAudioCentroidBuilder.buildClusters(from: segments)

            #expect(clusters.map(\.key) == ["S1", "S2"])
        }
    }
#endif
