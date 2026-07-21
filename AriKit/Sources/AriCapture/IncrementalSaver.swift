//
//  IncrementalSaver.swift — 30 s checkpoint + crash-recovery remux state machine
//  (arikit-native-shell.md §4.6, ← `frontend/src-tauri/src/audio/incremental_saver.rs`
//  `IncrementalAudioSaver`, :19-309).
//
//  Port notes / deviations:
//  - The Rust saver shells out to ffmpeg for both per-checkpoint AAC encode and the final
//    concat-demuxer merge. Here, `AACRecorder` encodes each checkpoint in-process, and the
//    final merge is `AVMutableComposition` + the modern async `AVAssetExportSession.export(to:
//    as:)` (§4.4) — no external process, no ffmpeg dependency.
//  - `cleanup`'s "remove the shared `.checkpoints/` dir only if now empty" semantics are
//    replicated exactly (← `cleanup_own_checkpoint_files`, `incremental_saver.rs:190-226`):
//    `FileManager.removeItem` on a non-empty directory would recursively delete it (unlike
//    Rust's `remove_dir`, which fails harmlessly on non-empty), so emptiness is checked first.
//  - This is pure state + file I/O (no device capture), headless-testable (Lane 1, plan §7
//    `IncrementalSaverTests`). `#if os(macOS)`-gated per plan §2.2.
//
#if os(macOS)
    import AVFoundation
    import Foundation

    /// Which per-track stem a saver owns, so three savers (mixed "audio", "mic", "system") can
    /// share one `.checkpoints/` dir without colliding (← `output_stem`, `incremental_saver.rs:26-32`).
    public enum CaptureTrack: String, Sendable, CaseIterable {
        case audio
        case mic
        case system
    }

    public struct IncrementalSaverConfig: Sendable, Equatable {
        public var sampleRate: Double
        public var track: CaptureTrack
        /// Checkpoint interval, in samples at `sampleRate`. Defaults to 30 s @ `sampleRate`
        /// (← `checkpoint_interval_samples`, `incremental_saver.rs:75`: "sample_rate as usize * 30").
        /// Tests may override this to a small value to avoid encoding minutes of fixture audio.
        public var checkpointIntervalSamples: Int

        public init(sampleRate: Double = 48000, track: CaptureTrack = .audio, checkpointIntervalSamples: Int? = nil) {
            self.sampleRate = sampleRate
            self.track = track
            self.checkpointIntervalSamples = checkpointIntervalSamples ?? Int(sampleRate * 30)
        }
    }

    public enum IncrementalSaverError: Error, Equatable, Sendable {
        case checkpointsDirectoryMissing
        case noCheckpoints
        case compositionFailed
        case checkpointMissing(index: Int)
    }

    /// Buffers PCM and flushes 30 s AAC checkpoints to a shared `.checkpoints/` dir, then remuxes
    /// them into one final file on `finalize` (← `IncrementalAudioSaver`, `incremental_saver.rs:19-309`).
    ///
    /// An `actor` (not a plain class): checkpoint save + the final remux both do file I/O that
    /// callers may await concurrently with `addSamples` calls from the capture hot path — actor
    /// isolation gives that safety for free without a caller-managed lock.
    public actor IncrementalSaver {
        private let config: IncrementalSaverConfig
        private let meetingFolder: URL
        private let checkpointsDir: URL
        private let recorder = AACRecorder()

        private var buffer: [Float] = []
        private var checkpointCount = 0

        /// - Throws: `IncrementalSaverError.checkpointsDirectoryMissing` if `meetingFolder/.checkpoints`
        ///   doesn't already exist (← the Rust constructor's existence check, `incremental_saver.rs:62-64`
        ///   — the caller is responsible for creating it, mirroring the recording-start lifecycle).
        public init(meetingFolder: URL, config: IncrementalSaverConfig) throws {
            self.meetingFolder = meetingFolder
            self.config = config
            checkpointsDir = meetingFolder.appendingPathComponent(".checkpoints")
            guard FileManager.default.fileExists(atPath: checkpointsDir.path) else {
                throw IncrementalSaverError.checkpointsDirectoryMissing
            }
        }

        private var stem: String {
            config.track.rawValue
        }

        public var currentCheckpointCount: Int {
            checkpointCount
        }

        /// Append samples to the in-memory buffer, flushing a checkpoint whenever the buffer reaches
        /// `checkpointIntervalSamples` (← `add_chunk`, `incremental_saver.rs:87-108`).
        public func addSamples(_ samples: [Float]) throws {
            buffer.append(contentsOf: samples)
            if buffer.count >= config.checkpointIntervalSamples {
                try saveCheckpoint()
            }
        }

        private func saveCheckpoint() throws {
            guard !buffer.isEmpty else { return }
            let path = checkpointPath(index: checkpointCount)
            try recorder.encode(samples: buffer, to: path)
            buffer.removeAll()
            checkpointCount += 1
        }

        private func checkpointPath(index: Int) -> URL {
            checkpointsDir.appendingPathComponent("\(stem)_chunk_\(String(format: "%03d", index)).m4a")
        }

        /// Finalize: flush any remaining buffer as a last checkpoint, remux all checkpoints into
        /// `outputFilename` inside `meetingFolder`, then delete only this track's own checkpoint
        /// files (← `finalize`, `incremental_saver.rs:150-183`).
        ///
        /// - Throws: `IncrementalSaverError.noCheckpoints` if nothing was ever buffered — an honest
        ///   failure, not a fabricated empty output file (← "No audio checkpoints to merge",
        ///   `incremental_saver.rs:161`).
        public func finalize(outputFilename: String) async throws -> URL {
            if !buffer.isEmpty {
                try saveCheckpoint()
            }
            guard checkpointCount > 0 else { throw IncrementalSaverError.noCheckpoints }

            let outputURL = meetingFolder.appendingPathComponent(outputFilename)
            try await remux(into: outputURL)
            cleanupOwnCheckpointFiles()
            return outputURL
        }

        private func remux(into output: URL) async throws {
            let composition = AVMutableComposition()
            guard let track = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw IncrementalSaverError.compositionFailed
            }

            var cursor = CMTime.zero
            for index in 0 ..< checkpointCount {
                let segmentURL = checkpointPath(index: index)
                guard FileManager.default.fileExists(atPath: segmentURL.path) else {
                    throw IncrementalSaverError.checkpointMissing(index: index)
                }
                let asset = AVURLAsset(url: segmentURL)
                let duration = try await asset.load(.duration)
                guard let assetTrack = try await asset.loadTracks(withMediaType: .audio).first else {
                    throw IncrementalSaverError.compositionFailed
                }
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: assetTrack, at: cursor)
                cursor = CMTimeAdd(cursor, duration)
            }

            if FileManager.default.fileExists(atPath: output.path) {
                try FileManager.default.removeItem(at: output)
            }

            guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A)
            else {
                throw IncrementalSaverError.compositionFailed
            }
            try await exportSession.export(to: output, as: .m4a)
        }

        /// Remove only THIS track's `{stem}_chunk_*` checkpoint files, then remove the shared
        /// `.checkpoints/` dir only if it's now empty — other tracks (mixed/mic/system) may still
        /// own files in it (← `cleanup_own_checkpoint_files`, `incremental_saver.rs:190-226`).
        private func cleanupOwnCheckpointFiles() {
            let fm = FileManager.default
            let prefix = "\(stem)_chunk_"

            if let entries = try? fm.contentsOfDirectory(at: checkpointsDir, includingPropertiesForKeys: nil) {
                for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
                    try? fm.removeItem(at: entry)
                }
            }

            // Best-effort: only remove the shared dir if it is now empty. `removeItem` on a
            // non-empty directory deletes recursively (unlike Rust's `remove_dir`), so emptiness
            // must be checked first — another track's saver may still have files in it, which is
            // fine; whichever saver finishes last does the actual removal.
            if let remaining = try? fm.contentsOfDirectory(atPath: checkpointsDir.path), remaining.isEmpty {
                try? fm.removeItem(at: checkpointsDir)
            }
        }

        /// Crash-recovery detection: does `meetingFolder/.checkpoints` exist and contain at least
        /// one `.m4a` checkpoint from an unfinished recording? (← `has_audio_checkpoints`,
        /// `incremental_saver.rs:487-506`.) A static/free check — no saver instance (and therefore
        /// no live recording) needs to exist to answer this on app launch.
        public static func hasOrphanedCheckpoints(in meetingFolder: URL) -> Bool {
            let checkpointsDir = meetingFolder.appendingPathComponent(".checkpoints")
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: checkpointsDir,
                includingPropertiesForKeys: nil
            ) else {
                return false
            }
            return entries.contains { $0.pathExtension == "m4a" }
        }
    }
#endif
