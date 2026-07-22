//
//  DiarizedSegment.swift — pure diarization seam value types (plan §2.2, §2.3).
//
//  `DiarizedSegment`/`DiarizationCluster` are the input/output shapes for
//  `DiarizationPostProcess` and `SpeakerMatcher` — no DB, no IO, no async. The full provider
//  seam (`DiarizationOutput`, `SpeakerCountHint`, `DiarizationProvider`) lands in D3.
//

/// A within-meeting cluster produced by a diarizer run. `centroid` is L2-normalized f32.
public struct DiarizationCluster: Sendable, Equatable {
    public var key: String
    public var centroid: [Float]
    public var speechSecs: Double

    public init(key: String, centroid: [Float], speechSecs: Double) {
        self.key = key
        self.centroid = centroid
        self.speechSecs = speechSecs
    }
}

/// One diarized span. `startTime`/`endTime` are recording-relative seconds.
public struct DiarizedSegment: Sendable, Equatable {
    public var clusterKey: String
    public var startTime: Double
    public var endTime: Double

    public init(clusterKey: String, startTime: Double, endTime: Double) {
        self.clusterKey = clusterKey
        self.startTime = startTime
        self.endTime = endTime
    }
}
