//
//  IncrementalSaverTests.swift — Lane 1 (arikit-native-shell.md §7): checkpoint counting at
//  30 s boundaries (using a scaled-down interval so tests don't encode minutes of fixture
//  audio), per-track stem naming, orphaned-checkpoint detection, and remux concatenation
//  (one final file whose duration ≈ sum of segments).
//
#if os(macOS)
    import AVFoundation
    import Foundation
    import Testing
    @testable import AriCapture

    @Suite("IncrementalSaver")
    struct IncrementalSaverTests {
        private func makeMeetingFolder() throws -> URL {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("ari-capture-saver-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent(".checkpoints"),
                withIntermediateDirectories: true
            )
            return folder
        }

        private func sineChunk(count: Int, sampleRate: Double = 48000) -> [Float] {
            (0 ..< count).map { index in
                let phase = 2.0 * Double.pi * 220 * Double(index) / sampleRate
                let amplitude = 0.5
                return Float(sin(phase) * amplitude)
            }
        }

        @Test("init fails honestly when .checkpoints/ doesn't already exist")
        func missingCheckpointsDirThrows() throws {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("ari-capture-no-checkpoints-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            #expect(throws: IncrementalSaverError.checkpointsDirectoryMissing) {
                _ = try IncrementalSaver(meetingFolder: folder, config: IncrementalSaverConfig())
            }
        }

        @Test("checkpoints are counted at the configured interval boundary")
        func checkpointsCountAtIntervalBoundary() async throws {
            let folder = try makeMeetingFolder()
            defer { try? FileManager.default.removeItem(at: folder) }

            // Small interval (4,800 samples = 0.1s @ 48kHz) so this test encodes a fraction of a
            // second of audio rather than 30s of real checkpoints.
            let config = IncrementalSaverConfig(sampleRate: 48000, track: .audio, checkpointIntervalSamples: 4800)
            let saver = try IncrementalSaver(meetingFolder: folder, config: config)

            try await saver.addSamples(sineChunk(count: 4800))
            #expect(await saver.currentCheckpointCount == 1)

            try await saver.addSamples(sineChunk(count: 4800))
            #expect(await saver.currentCheckpointCount == 2)
        }

        @Test("checkpoint files use the track's stem, avoiding collisions in a shared .checkpoints/ dir")
        func checkpointFilesUseTrackStem() async throws {
            let folder = try makeMeetingFolder()
            defer { try? FileManager.default.removeItem(at: folder) }

            let config = IncrementalSaverConfig(sampleRate: 48000, track: .mic, checkpointIntervalSamples: 4800)
            let saver = try IncrementalSaver(meetingFolder: folder, config: config)
            try await saver.addSamples(sineChunk(count: 4800))

            let checkpointsDir = folder.appendingPathComponent(".checkpoints")
            let entries = try FileManager.default.contentsOfDirectory(atPath: checkpointsDir.path)
            #expect(entries.contains("mic_chunk_000.m4a"))
        }

        @Test("orphaned-checkpoint detection sees an unfinalized recording, and not a clean one")
        func detectsOrphanedCheckpoints() async throws {
            let folder = try makeMeetingFolder()
            defer { try? FileManager.default.removeItem(at: folder) }

            #expect(IncrementalSaver.hasOrphanedCheckpoints(in: folder) == false)

            let config = IncrementalSaverConfig(sampleRate: 48000, track: .audio, checkpointIntervalSamples: 4800)
            let saver = try IncrementalSaver(meetingFolder: folder, config: config)
            try await saver.addSamples(sineChunk(count: 4800))

            #expect(IncrementalSaver.hasOrphanedCheckpoints(in: folder) == true)

            _ = try await saver.finalize(outputFilename: "audio.m4a")

            // After a clean finalize, this track's checkpoints are gone.
            #expect(IncrementalSaver.hasOrphanedCheckpoints(in: folder) == false)
        }

        @Test("finalize remuxes all checkpoints into one file with duration ≈ sum of segments")
        func finalizeRemuxesIntoOneFile() async throws {
            let folder = try makeMeetingFolder()
            defer { try? FileManager.default.removeItem(at: folder) }

            let config = IncrementalSaverConfig(sampleRate: 48000, track: .audio, checkpointIntervalSamples: 4800)
            let saver = try IncrementalSaver(meetingFolder: folder, config: config)

            // Two full checkpoints + a partial final buffer flushed by `finalize`.
            try await saver.addSamples(sineChunk(count: 4800))
            try await saver.addSamples(sineChunk(count: 4800))
            try await saver.addSamples(sineChunk(count: 2400))
            #expect(await saver.currentCheckpointCount == 2)

            let output = try await saver.finalize(outputFilename: "audio.m4a")
            #expect(FileManager.default.fileExists(atPath: output.path))
            #expect(await saver.currentCheckpointCount == 3)

            let asset = AVURLAsset(url: output)
            let duration = try await asset.load(.duration)
            let expectedSeconds = Double(4800 + 4800 + 2400) / 48000.0
            #expect(abs(duration.seconds - expectedSeconds) < 0.3)

            // Own checkpoint files + the shared dir are cleaned up.
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".checkpoints").path))
        }

        @Test("finalizing with nothing ever buffered fails honestly, not a fabricated empty output")
        func finalizeWithNoCheckpointsThrows() async throws {
            let folder = try makeMeetingFolder()
            defer { try? FileManager.default.removeItem(at: folder) }

            let saver = try IncrementalSaver(meetingFolder: folder, config: IncrementalSaverConfig())

            await #expect(throws: IncrementalSaverError.noCheckpoints) {
                _ = try await saver.finalize(outputFilename: "audio.m4a")
            }
        }
    }
#endif
