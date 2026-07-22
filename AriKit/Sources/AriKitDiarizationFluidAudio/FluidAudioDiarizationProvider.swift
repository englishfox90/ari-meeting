//
//  FluidAudioDiarizationProvider.swift — the sole real `DiarizationProvider` conformer (plan
//  §2.2, D7). Wraps FluidAudio's offline (pyannote community-1) CoreML pipeline
//  (`OfflineDiarizerManager`) behind the seam so core `AriKit` never imports FluidAudio.
//
//  Actor, not struct (swift-H1): `OfflineDiarizerManager` and `OfflineDiarizerModels` load
//  CoreML models that are not cheap to reload; an actor gives this provider a legitimate place
//  to cache prepared state across `prepare()`/`diarize()` calls without reaching for
//  `@unchecked Sendable` (forbidden) or reloading models on every call.
//
#if os(macOS)
    import AriKit
    import FluidAudio

    public actor FluidAudioDiarizationProvider: DiarizationProvider {
        public let providerName = "fluidaudio-offline"
        public let embeddingModel = "fluidaudio-community-1"

        /// Cached once `prepare()` (explicit or lazy) succeeds. `OfflineDiarizerManager`'s own
        /// config is immutable per instance (the hint-derived clustering constraints are set at
        /// construction, §2.2), so `diarize()` builds a fresh manager per hint and hands it
        /// these already-loaded models via `initialize(models:)` — never re-downloading or
        /// re-compiling CoreML models on a call that already has them.
        private var loadedModels: OfflineDiarizerModels?

        public init() {}

        public func isAvailable() async -> Bool {
            true
        }

        /// Idempotent: a second call, whether or not the first succeeded synchronously before
        /// this one started, resolves to the same cached models rather than reloading them.
        public func prepare() async throws {
            _ = try await preparedModels()
        }

        public func diarize(
            samples: [Float],
            hint: SpeakerCountHint,
            progress: (@Sendable (Double) -> Void)?
        ) async throws -> DiarizationOutput {
            let models = try await preparedModels()

            var config = OfflineDiarizerConfig.default
            let constraints = FluidAudioHintMapping.clusteringConstraints(for: hint)
            config.clustering.numSpeakers = constraints.numSpeakers
            config.clustering.minSpeakers = constraints.minSpeakers
            config.clustering.maxSpeakers = constraints.maxSpeakers

            let manager = OfflineDiarizerManager(config: config)
            manager.initialize(models: models)

            let result: DiarizationResult
            do {
                result = try await manager.process(audio: samples) { chunksProcessed, totalChunks in
                    guard totalChunks > 0 else { return }
                    progress?(Double(chunksProcessed) / Double(totalChunks))
                }
            } catch {
                throw DiarizationError.providerFailed(String(describing: error))
            }

            let clusters = FluidAudioCentroidBuilder.buildClusters(from: result.segments)
            let segments = result.segments.map {
                DiarizedSegment(
                    clusterKey: $0.speakerId,
                    startTime: Double($0.startTimeSeconds),
                    endTime: Double($0.endTimeSeconds)
                )
            }
            let dim = clusters.first?.centroid.count ?? 0
            return DiarizationOutput(segments: segments, clusters: clusters, embeddingModel: embeddingModel, dim: dim)
        }

        @discardableResult
        private func preparedModels() async throws -> OfflineDiarizerModels {
            if let loadedModels {
                return loadedModels
            }
            do {
                let models = try await OfflineDiarizerModels.load()
                loadedModels = models
                return models
            } catch {
                throw DiarizationError.modelsUnavailable(String(describing: error))
            }
        }
    }

    /// Pure hint → FluidAudio clustering-constraint mapping (plan §2.2), extracted so it is
    /// testable without a model download.
    enum FluidAudioHintMapping {
        static func clusteringConstraints(
            for hint: SpeakerCountHint
        ) -> (numSpeakers: Int?, minSpeakers: Int?, maxSpeakers: Int?) {
            switch hint {
            case let .exact(n):
                (n, nil, nil)
            case let .upperBound(n):
                (nil, 1, n)
            case .automatic:
                (nil, nil, nil)
            }
        }
    }

    /// Builds one `DiarizationCluster` per distinct `speakerId` in a FluidAudio result: a
    /// duration-weighted mean of that speaker's segment embeddings, re-L2-normalized (the same
    /// `weightedMean` + `l2Normalized` recipe `DiarizationPostProcess` uses, §2.3). Pure,
    /// testable without a model download.
    enum FluidAudioCentroidBuilder {
        static func buildClusters(from segments: [TimedSpeakerSegment]) -> [DiarizationCluster] {
            var accumulated: [String: (centroid: [Float], totalSecs: Double)] = [:]

            for segment in segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) {
                let duration = Double(segment.durationSeconds)
                guard duration > 0, !segment.embedding.isEmpty else { continue }

                if let existing = accumulated[segment.speakerId] {
                    let merged = SpeakerMath.weightedMean(
                        existing.centroid, existing.totalSecs,
                        segment.embedding, duration
                    )
                    accumulated[segment.speakerId] = (merged, existing.totalSecs + duration)
                } else {
                    accumulated[segment.speakerId] = (segment.embedding, duration)
                }
            }

            return accumulated
                .map { key, value in
                    DiarizationCluster(key: key, centroid: SpeakerMath.l2Normalized(value.centroid), speechSecs: value.totalSecs)
                }
                .sorted { $0.key < $1.key }
        }
    }
#endif
