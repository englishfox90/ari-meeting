//
//  SpeakerSamples.swift — speaker sample selection (F1 identification evidence).
//
//  Port of the frozen Rust/React app's `frontend/src/lib/speaker-samples.ts`. Groups a
//  meeting's transcript segments by their diarized `speakerId` and picks a few representative
//  lines per speaker, so the user has something to READ and HEAR when deciding who a
//  "Speaker N" actually is. Pure functions over the transcript rows already loaded by
//  `MeetingDetailViewModel` — no backend call needed.
//
//  No-Fake-State: samples are the real transcribed text at real timestamps. When a speaker has
//  no attributed, timed lines, the result is simply empty.
//
import AriKit
import Foundation

public enum SpeakerSamples {
    /// One representative transcript line, selected as evidence for a speaker's identity.
    public struct SpeakerSample: Identifiable, Equatable, Sendable {
        /// The transcript segment id (stable key).
        public let id: TranscriptID
        /// The trimmed transcribed text of the line.
        public let text: String
        /// Recording-relative start time in seconds (drives clip playback).
        public let startSeconds: Double
        /// Recording-relative end time in seconds, sourced from `Transcript.audioEndTime` —
        /// `nil` when the row has no known end (clip playback then plays to the end of the
        /// recording rather than stopping early; see `AudioPlayerController.playClip`).
        public let endSeconds: Double?

        public init(id: TranscriptID, text: String, startSeconds: Double, endSeconds: Double? = nil) {
            self.id = id
            self.text = text
            self.startSeconds = startSeconds
            self.endSeconds = endSeconds
        }
    }

    /// Picks up to `max` representative lines a speaker said. Prefers the most substantive
    /// (longest) lines — the best voiceprint evidence — then presents them in chronological
    /// order so the timestamps read naturally. Only rows with a matching `speakerId`,
    /// non-empty trimmed text, AND a known `audioStartTime` (needed to play a clip) qualify.
    public static func select(from transcripts: [Transcript], speakerId: SpeakerID, max: Int = 5) -> [SpeakerSample] {
        let mine = transcripts.filter { row in
            guard row.speakerId == speakerId, row.audioStartTime != nil else { return false }
            return !row.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let longestFirst = mine.sorted { lhs, rhs in
            let lhsLength = lhs.transcript.trimmingCharacters(in: .whitespacesAndNewlines).count
            let rhsLength = rhs.transcript.trimmingCharacters(in: .whitespacesAndNewlines).count
            return lhsLength > rhsLength
        }
        let picked = longestFirst.prefix(max)
        let chronological = picked.sorted { lhs, rhs in
            (lhs.audioStartTime ?? 0) < (rhs.audioStartTime ?? 0)
        }
        return chronological.map { row in
            SpeakerSample(
                id: row.id,
                text: row.transcript.trimmingCharacters(in: .whitespacesAndNewlines),
                startSeconds: row.audioStartTime ?? 0,
                endSeconds: row.audioEndTime
            )
        }
    }

    /// Builds a speakerId → representative-samples map for every diarized speaker present in
    /// `transcripts`. Rows with no `speakerId` are ignored (not yet diarized).
    public static func group(from transcripts: [Transcript], max: Int = 5) -> [SpeakerID: [SpeakerSample]] {
        var ids: Set<SpeakerID> = []
        for row in transcripts {
            if let speakerId = row.speakerId {
                ids.insert(speakerId)
            }
        }
        var result: [SpeakerID: [SpeakerSample]] = [:]
        for id in ids {
            result[id] = select(from: transcripts, speakerId: id, max: max)
        }
        return result
    }
}
