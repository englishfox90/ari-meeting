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
