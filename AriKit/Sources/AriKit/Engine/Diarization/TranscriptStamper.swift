//
//  TranscriptStamper.swift — max-overlap transcript stamping (pure)
//  (← Rust `stamp_transcripts`, `ari-engine/src/diarization/commands.rs:885-955` — untested in
//  Rust; this port carries the unit suite the Rust never had, plan §2.5/§5 D4).
//
//  Stamp each transcript row with the resolved speaker whose segment it most overlaps in time.
//  We prefer a system-source match: when a row overlaps both a system and a microphone/other
//  segment, the system (remote-cluster) attribution wins. Only when there is zero system overlap
//  do we fall back to the best-overlapping segment from the fallback pool. Within a pool, the
//  larger overlap wins; near-equal overlaps (epsilon 1e-6) prefer the shorter segment (the more
//  specific span). Rows with no overlap, or missing audio times, are left unstamped — never
//  guessed.
//

public enum TranscriptStamper {
    private static let epsilon = 1e-6

    /// Stamp `transcripts` against `segments`. Segments with a `nil` speakerId are skipped
    /// entirely (reachable via `.setNull` on speaker delete — `commands.rs:919-921`). Rows with
    /// missing audio times, or with no overlapping segment at all, are returned in `unstamped`.
    public static func stamp(
        transcripts: [Transcript],
        segments: [SpeakerSegment]
    ) -> (stamps: [(transcriptId: TranscriptID, speakerId: SpeakerID)], unstamped: [TranscriptID]) {
        var stamps: [(transcriptId: TranscriptID, speakerId: SpeakerID)] = []
        var unstamped: [TranscriptID] = []

        for t in transcripts {
            guard let ts = t.audioStartTime, let te = t.audioEndTime else {
                unstamped.append(t.id)
                continue
            }

            var bestSystem: (speakerId: SpeakerID, overlap: Double, segDur: Double)?
            var bestFallback: (speakerId: SpeakerID, overlap: Double, segDur: Double)?

            for seg in segments {
                guard let sid = seg.speakerId else { continue }
                let overlap = min(te, seg.endTime) - max(ts, seg.startTime)
                guard overlap > 0.0 else { continue }
                let segDur = max(seg.endTime - seg.startTime, 0.0)

                let isSystem = seg.source == .system
                let current = isSystem ? bestSystem : bestFallback
                let take: Bool
                switch current {
                case nil:
                    take = true
                case let .some((_, bestOverlap, bestDur)):
                    take = overlap > bestOverlap || (approxEqual(overlap, bestOverlap) && segDur < bestDur)
                }
                if take {
                    let candidate = (speakerId: sid, overlap: overlap, segDur: segDur)
                    if isSystem {
                        bestSystem = candidate
                    } else {
                        bestFallback = candidate
                    }
                }
            }

            if let winner = bestSystem ?? bestFallback {
                stamps.append((transcriptId: t.id, speakerId: winner.speakerId))
            } else {
                unstamped.append(t.id)
            }
        }

        return (stamps, unstamped)
    }

    private static func approxEqual(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) < epsilon
    }
}
