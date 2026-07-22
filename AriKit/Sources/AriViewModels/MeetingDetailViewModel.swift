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
    public private(set) var audio: AudioAvailability = .unresolved
    /// Recording-relative seconds of every citation marker in the summary, sorted and unique
    /// (empty when there is no summary or it carries no markers — never fabricated).
    public private(set) var referencedMoments: [Double] = []

    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
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
            speakerNames = try await Self.resolveSpeakerNames(
                meetingId: id,
                participants: participants,
                database: database
            )
            audio = Self.resolveAudioAvailability(
                for: resolved,
                fileExists: { FileManager.default.fileExists(atPath: $0.path) }
            )
        } catch {
            meeting = .failed(String(describing: error))
        }
    }

    /// The resolved display name for a transcript segment's speaker, or `nil` if none could
    /// be resolved (honest — never a fabricated placeholder).
    public func displayName(for speakerId: SpeakerID?) -> String? {
        guard let speakerId else { return nil }
        return speakerNames[speakerId]
    }

    private static func resolveSpeakerNames(
        meetingId: MeetingID,
        participants: [Person],
        database: AppDatabase
    ) async throws -> [SpeakerID: String] {
        let speakers = try await database.speakers.forMeeting(meetingId)
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

    private static func resolveAudioAvailability(
        for meeting: Meeting,
        fileExists: (URL) -> Bool
    ) -> AudioAvailability {
        AudioAvailabilityResolver.resolve(audioReference: meeting.audioReference, fileExists: fileExists)
    }
}
