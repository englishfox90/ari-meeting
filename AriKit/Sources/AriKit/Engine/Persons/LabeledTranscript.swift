//
//  LabeledTranscript.swift — speaker-labeled transcript text for the Persons prompts (Phase 3.4
//  Track H §2.5, ← `ari-engine/src/diarization/labeling.rs::build_labeled_transcript_text` +
//  `ari-engine/src/persons/extraction.rs::load_transcript_text`).
//
//  Both engines prefer a speaker-labeled transcript ("Sarah: …") so the LLM's person_name/
//  person_email tags are grounded in the REAL names present, making `PersonResolve.resolvePerson`
//  match accurately. Falls back to a plain concatenation when no speaker resolves to a name — a
//  small additive read-only helper joining `transcript` ⊕ `speaker` ⊕ `person`, NOT a diarization
//  port. Never fabricates a name: a speaker that resolves to none is omitted, never given a
//  placeholder label (No-Fake-State).
//
import Foundation

public enum LabeledTranscript {
    /// Builds the meeting's transcript as newline-joined lines, prefixing each line with the
    /// resolved speaker name when known: `"{Name}: {text}"`. Lines whose speaker is unknown are
    /// emitted bare. Returns `nil` when the meeting has zero resolved speakers, so callers fall
    /// back to `loadTranscriptText`. Resolution: linked person's `displayName`, else the
    /// speaker's own `label`, else (for the `owner`-enrolled voiceprint) the configured owner's
    /// name / "You", else the speaker is omitted.
    public static func buildLabeledTranscriptText(db: AppDatabase, meetingId: MeetingID) async throws -> String? {
        let transcripts = try await db.transcripts.forMeeting(meetingId)
        guard !transcripts.isEmpty else { return nil }

        let speakerIds = Set(transcripts.compactMap(\.speakerId))
        guard !speakerIds.isEmpty else { return nil }

        let names = try await resolveSpeakerNames(db: db, speakerIds: speakerIds)
        guard !names.isEmpty else { return nil }

        var lines: [String] = []
        for transcript in transcripts {
            let text = transcript.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let speakerId = transcript.speakerId, let name = names[speakerId] {
                lines.append("\(name): \(text)")
            } else {
                lines.append(text)
            }
        }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    /// Builds the meeting's transcript for the SUMMARY prompt: every line prefixed with its real
    /// `[MM:SS]` recording-relative marker, and the resolved speaker name when known —
    /// `"[MM:SS] {Name}: {text}"`, or bare `"[MM:SS] {text}"` when the speaker is unknown
    /// (← `frontend/src/lib/summary/summaryCore.ts::buildSummaryTranscriptPayload`).
    ///
    /// The `[MM:SS]` prefix is load-bearing and NON-optional here: the summary prompt tells the
    /// model each line carries one, and `SummaryCitations` verifies/snaps/back-fills `@ref(MM:SS)`
    /// tokens against these exact markers. Unlike `buildLabeledTranscriptText` (the persons path,
    /// which drops timestamps to match its Rust origin and returns `nil` with no resolved
    /// speakers), this ALWAYS emits markers, even for a meeting with zero resolved speakers —
    /// otherwise the timestamp-citation feature has nothing to cite. Returns `""` only when the
    /// meeting genuinely has no transcript text (honest — nothing to summarize).
    ///
    /// The marker is computed from `audioStartTime` when present, falling back to the row's stored
    /// `timestamp` string (already `MM:SS`) — never fabricated (No-Fake-State).
    public static func buildSummaryTranscriptText(db: AppDatabase, meetingId: MeetingID) async throws -> String {
        let transcripts = try await db.transcripts.forMeeting(meetingId)
        guard !transcripts.isEmpty else { return "" }

        let speakerIds = Set(transcripts.compactMap(\.speakerId))
        let names = speakerIds.isEmpty
            ? [:]
            : try await resolveSpeakerNames(db: db, speakerIds: speakerIds)

        var lines: [String] = []
        for transcript in transcripts {
            let text = transcript.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let marker = summaryMarker(for: transcript)
            if let speakerId = transcript.speakerId, let name = names[speakerId] {
                lines.append("\(marker) \(name): \(text)")
            } else {
                lines.append("\(marker) \(text)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The `[MM:SS]` marker for a summary transcript line: from `audioStartTime` when present, else
    /// the row's stored `timestamp` string (wrapped in brackets). Never invents a time.
    private static func summaryMarker(for transcript: Transcript) -> String {
        if let start = transcript.audioStartTime {
            let total = max(0, Int(start.rounded(.down)))
            return String(format: "[%02d:%02d]", total / 60, total % 60)
        }
        return "[\(transcript.timestamp)]"
    }

    /// Resolves each speaker id to a display name: linked person's `displayName`, else the
    /// speaker's own `label`, else (for the `owner`-enrolled voiceprint) the configured owner's
    /// name / "You". Speakers that resolve to none are omitted (never given a placeholder label —
    /// No-Fake-State). Shared by both the persons and summary transcript builders.
    private static func resolveSpeakerNames(
        db: AppDatabase,
        speakerIds: Set<SpeakerID>
    ) async throws -> [SpeakerID: String] {
        var names: [SpeakerID: String] = [:]
        for speakerId in speakerIds {
            guard let speaker = try await db.speakers.find(speakerId) else { continue }

            var resolved: String?
            if let personId = speaker.personId, let person = try await db.persons.find(personId) {
                resolved = person.displayName
            }
            if resolved == nil {
                let trimmedLabel = speaker.label?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let trimmedLabel, !trimmedLabel.isEmpty {
                    resolved = trimmedLabel
                }
            }
            if resolved == nil, speaker.enrollmentState == .owner {
                resolved = try await db.persons.owner()?.displayName ?? "You"
            }
            if let resolved {
                names[speakerId] = resolved
            }
        }
        return names
    }

    /// The unlabeled fallback (← `load_transcript_text`, `extraction.rs:290`): every non-empty
    /// transcript segment for the meeting, space-joined in recording order. Returns `""` when the
    /// meeting has no transcript text at all.
    public static func loadTranscriptText(db: AppDatabase, meetingId: MeetingID) async throws -> String {
        let transcripts = try await db.transcripts.forMeeting(meetingId)
        var text = ""
        for transcript in transcripts {
            let trimmed = transcript.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !text.isEmpty {
                text += " "
            }
            text += trimmed
        }
        return text
    }
}
