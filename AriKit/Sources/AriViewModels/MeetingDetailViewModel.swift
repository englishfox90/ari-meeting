//
//  MeetingDetailViewModel.swift — the Meeting detail screen's view model
//  (docs/plans/arikit-native-read-ui.md §2.3).
//
//  One-shot reads (no live observation — plan §2.3's "detail VMs do one-shot find/forMeeting
//  reads"). A thrown error maps to `.failed(String)`. Missing summary/notes are represented
//  as honest `nil`, never fabricated content (No-Fake-State).
//
//  Speaker-name resolution (`speakerNames`/`displayName(for:)`): reads
//  `SpeakerRepository.forMeeting(_:)` (docs/plans/arikit-diarization.md D9a — closes the
//  TODO(S6) workaround that used to narrow `SpeakerRepository.all()` by hand). A speaker's
//  display name prefers its linked `Person`'s `displayName` (looked up first among this
//  meeting's participants, then via `PersonRepository.find(_:)` as a fallback for a speaker
//  whose person isn't a linked participant), then falls back to the speaker's own `label`, else
//  `nil` (honest — never a fabricated "Speaker 1"-style placeholder).
//
import AriKit
import Foundation
import Observation

@MainActor
@Observable
public final class MeetingDetailViewModel {
    public private(set) var meeting: LoadState<Meeting> = .loading
    public private(set) var transcript: [Transcript] = []
    public private(set) var summary: Summary?
    public private(set) var notes: MeetingNote?
    public private(set) var participants: [Person] = []
    public private(set) var speakerNames: [SpeakerID: String] = [:]
    /// Render-ready voiceprint signature per speaker, derived from the speaker's real centroid
    /// (`Voiceprint.signature(fromCentroid:)`). A speaker with no usable centroid is simply
    /// absent — the glyph then renders its honest placeholder, never a fabricated ring.
    public private(set) var speakerSignatures: [SpeakerID: [Float]] = [:]
    public private(set) var audio: AudioAvailability = .unresolved
    /// Recording-relative seconds of every citation marker in the summary, sorted and unique
    /// (empty when there is no summary or it carries no markers — never fabricated).
    public private(set) var referencedMoments: [Double] = []

    private let database: AppDatabase
    /// Fires the recall-index purge on delete (docs/plans/ask-meetings-tools-and-cards.md §3.1.1)
    /// — `nil` in contexts that don't wire recall indexing (e.g. narrower tests), in which case a
    /// delete simply doesn't purge anything (the meeting is still tombstoned either way).
    private let recallIndexTrigger: RecallIndexTrigger?

    public init(database: AppDatabase, recallIndexTrigger: RecallIndexTrigger? = nil) {
        self.database = database
        self.recallIndexTrigger = recallIndexTrigger
    }

    public func load(_ id: MeetingID) async {
        do {
            guard let resolved = try await database.meetings.find(id) else {
                meeting = .failed("Meeting not found.")
                return
            }
            meeting = .loaded(resolved)

            transcript = try await database.transcripts.forMeeting(id)
            summary = try await database.summaries.forMeeting(id)
            referencedMoments = ReferencedMoments.parse(from: summary?.bodyMarkdown ?? "")
            notes = try await database.meetingNotes.find(id)
            participants = try await database.persons.participants(inMeeting: id)
            let speakers = try await database.speakers.forMeeting(id)
            speakerNames = try await Self.resolveSpeakerNames(
                speakers: speakers,
                participants: participants,
                database: database
            )
            speakerSignatures = Self.resolveSpeakerSignatures(speakers: speakers)
            audio = Self.resolveAudioAvailability(
                for: resolved,
                fileExists: { FileManager.default.fileExists(atPath: $0.path) }
            )
        } catch {
            meeting = .failed(String(describing: error))
        }
    }

    /// Renames the meeting and reflects the new title locally. The detail screen does one-shot
    /// reads (no live observation), so we patch the loaded `meeting` in place — otherwise the
    /// header/navigation title would keep the stale title until the next `load`. A blank title, or
    /// a call before the meeting has loaded, is a no-op. Throws on a real write failure.
    public func rename(_ id: MeetingID, to newTitle: String) async throws {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case let .loaded(current) = meeting, !trimmed.isEmpty, trimmed != current.title else { return }
        try await database.meetings.rename(id, to: trimmed, at: Date())
        var updated = current
        updated.title = trimmed
        meeting = .loaded(updated)
    }

    /// Soft-deletes (tombstones) the meeting. The caller is responsible for dismissing the detail
    /// screen afterward (the list refreshes itself via its own observation). Throws on a real
    /// write failure.
    public func delete(_ id: MeetingID) async throws {
        try await database.meetings.softDelete(id, at: Date())
        // Fire-and-forget purge of any indexed recall chunks (§3.1.1) — never blocks the delete,
        // never surfaces its own failure to the caller.
        recallIndexTrigger?.purgeOnDelete(id)
    }

    /// The resolved display name for a transcript segment's speaker, or `nil` if none could
    /// be resolved (honest — never a fabricated placeholder).
    public func displayName(for speakerId: SpeakerID?) -> String? {
        guard let speakerId else { return nil }
        return speakerNames[speakerId]
    }

    /// The render-ready voiceprint signature for a transcript segment's speaker, or `nil` when
    /// none is enrolled yet (the glyph then shows its honest placeholder, never a fake ring).
    public func signature(for speakerId: SpeakerID?) -> [Float]? {
        guard let speakerId else { return nil }
        return speakerSignatures[speakerId]
    }

    private static func resolveSpeakerNames(
        speakers: [Speaker],
        participants: [Person],
        database: AppDatabase
    ) async throws -> [SpeakerID: String] {
        let participantsById = Dictionary(uniqueKeysWithValues: participants.map { ($0.id, $0) })

        var names: [SpeakerID: String] = [:]
        for speaker in speakers {
            if let personId = speaker.personId {
                if let name = participantsById[personId]?.displayName {
                    names[speaker.id] = name
                    continue
                }
                if let person = try await database.persons.find(personId) {
                    names[speaker.id] = person.displayName
                    continue
                }
            }
            if let label = speaker.label {
                names[speaker.id] = label
            }
        }
        return names
    }

    private static func resolveSpeakerSignatures(speakers: [Speaker]) -> [SpeakerID: [Float]] {
        var signatures: [SpeakerID: [Float]] = [:]
        for speaker in speakers {
            if let signature = Voiceprint.signature(fromCentroid: speaker.centroid) {
                signatures[speaker.id] = signature
            }
        }
        return signatures
    }

    private static func resolveAudioAvailability(
        for meeting: Meeting,
        fileExists: (URL) -> Bool
    ) -> AudioAvailability {
        AudioAvailabilityResolver.resolve(audioReference: meeting.audioReference, fileExists: fileExists)
    }
}
