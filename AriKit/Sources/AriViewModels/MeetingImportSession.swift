//
//  MeetingImportSession.swift — import an existing audio file as a meeting
//  (docs/plans/audio-import.md). The Swift port of the frozen Rust importer
//  (`frontend/src-tauri/src/audio/import.rs`), with ONE deliberate addition: the meeting's
//  date/time is user-chosen, so an imported old recording no longer shows *today* as its date.
//
//  Mount-independent @Observable operation coordinator, mirroring `RecordingSession`'s shape and
//  owned by `AppEnvironment` (survives sheet dismiss). The heavy pipeline the Rust importer
//  hand-rolls (decode → resample → VAD → per-segment STT) is subsumed by
//  `SpeechTranscriberProvider.transcribe(fileURL:)` (SpeechAnalyzer segments the whole file
//  itself), so this is thin: copy the file into a per-meeting folder, transcribe, map segments
//  via `TranscriptMapping` (the SAME mapping the live recording path uses), persist a `Meeting`
//  (with `createdAt` = the chosen date) + its transcripts, then hand off to the existing
//  post-recording pipeline (`MeetingProcessingCoordinator.begin`, wired by `RootSplitView`).
//
//  No-Fake-State (§7): every failure surfaces the real reason; the progress `Stage`s are real
//  (never a fabricated percentage — SpeechAnalyzer's whole-file driver exposes no incremental
//  progress); an all-silence file still creates the meeting honestly with zero transcripts,
//  matching the Rust importer. `createdAt` is user-supplied truth; `updatedAt` is the real import
//  instant.
//
import AriKit
import Foundation
import Observation

@MainActor
@Observable
public final class MeetingImportSession {
    /// Honest operation phase. `.importing` carries the real current stage — no fabricated %.
    public enum Phase: Equatable, Sendable {
        case idle
        case importing(Stage)
        case saved(MeetingID)
        case failed(String)
    }

    /// The three real stages of an import, in order. No percentage is invented between them
    /// because SpeechAnalyzer's whole-file transcription reports no incremental progress.
    public enum Stage: Equatable, Sendable {
        /// Creating the meeting folder + copying the audio into the library.
        case preparing
        /// On-device transcription of the whole file.
        case transcribing
        /// Persisting the meeting + transcript rows.
        case saving
    }

    public private(set) var phase: Phase = .idle

    /// `true` while an import is actively running — the UI disables re-entry / dismiss on this.
    public var isImporting: Bool {
        if case .importing = phase { true } else { false }
    }

    /// The container extensions accepted for import. Covers the audio formats `AVAudioFile` (and
    /// thus SpeechAnalyzer) opens reliably, including the MPEG-4/QuickTime containers the app
    /// records into and the old Rust importer accepted (`mp4`/`m4a`/`mov`): `AVAudioFile` reads
    /// their audio track. A file that can't actually be decoded is still rejected honestly by the
    /// pick-time `AudioFileProbe` and, at import, by `audioDecodeFailed` — not silently dropped.
    public static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "mp4", "mov", "wav", "aac", "aiff", "aif", "caf", "flac",
    ]

    /// Human-readable list of `supportedExtensions` for error copy (e.g. "AAC, AIFF, …").
    public static var supportedExtensionsDisplay: String {
        supportedExtensions.map { $0.uppercased() }.sorted().joined(separator: ", ")
    }

    private let database: AppDatabase
    /// Root under which each import gets its own `<meetingID>/` folder (same root the recorder
    /// uses — `AppEnvironment.recordingsRootURL()`).
    private let recordingsRoot: URL
    /// The file-transcription engine (`SpeechTranscriberProvider` in the app; a stub in tests).
    private let transcription: any TranscriptionProvider
    /// Injectable "now", for the `updatedAt` stamp — the meeting's `createdAt` is the user's
    /// chosen date, never the clock.
    private let clock: @Sendable () -> Date

    public init(
        database: AppDatabase,
        recordingsRoot: URL,
        transcription: any TranscriptionProvider,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.recordingsRoot = recordingsRoot
        self.transcription = transcription
        self.clock = clock
    }

    // MARK: - Intents

    /// Import `sourceURL` as a new meeting titled `title`, dated `meetingDate`
    /// (→ `Meeting.createdAt`). A no-op while an import is already running (one at a time, mirroring
    /// `RecordingSession`'s single-session guard); proceeds from `.idle` or either terminal state.
    /// Drives `phase` through `.importing(.preparing/.transcribing/.saving)` to `.saved` | `.failed`.
    public func importFile(at sourceURL: URL, title: String, meetingDate: Date) async {
        switch phase {
        case .importing:
            return // one import at a time
        case .idle, .saved, .failed:
            break
        }

        // Validate BEFORE flipping to `.importing`, so a rejected file shows an inline error rather
        // than a flash of the progress view.
        let ext = sourceURL.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else {
            phase = .failed(
                "Unsupported audio format “.\(ext)”. Supported: \(Self.supportedExtensionsDisplay)."
            )
            return
        }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            phase = .failed("The selected file could not be found.")
            return
        }

        phase = .importing(.preparing)

        let meetingId = MeetingID(UUID().uuidString)
        let folder = recordingsRoot.appendingPathComponent(meetingId.rawValue, isDirectory: true)
        // FULL-FILE-PATH audio reference (`…/audio.<ext>`): `AudioAvailabilityResolver` resolves a
        // reference-with-extension directly, so any container works with no transcode and no
        // resolver change (the legacy-import shape).
        let destURL = folder.appendingPathComponent("audio.\(ext)", isDirectory: false)

        // Create the folder + copy the (possibly large) file OFF the main actor so the UI stays
        // responsive. URLs are Sendable; nothing main-actor-isolated is captured.
        do {
            try await Self.prepareAudio(source: sourceURL, folder: folder, destination: destURL)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            phase = .failed("Could not copy the audio into the library: \(String(describing: error))")
            return
        }

        // Transcribe the copied file. Language follows the same Settings key the recorder reads
        // (the "auto" sentinel = system language, resolved by the provider).
        phase = .importing(.transcribing)
        let language = await (try? database.settings.string(forKey: .transcriptionLanguage)) ?? nil
        let result: TranscriptionResult
        do {
            result = try await transcription.transcribe(fileURL: destURL, language: language)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            phase = .failed(Self.describeTranscriptionFailure(error))
            return
        }

        // Persist. `createdAt` is the user's chosen meeting date (the feature); `updatedAt` is the
        // real import instant.
        phase = .importing(.saving)
        let now = clock()
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let meeting = Meeting(
            id: meetingId,
            title: trimmedTitle.isEmpty ? Self.defaultTitle(for: sourceURL) : trimmedTitle,
            createdAt: meetingDate,
            updatedAt: now,
            audioReference: LocalAudioReference(path: destURL.path),
            transcriptionProvider: transcription.providerName
        )
        let transcripts = TranscriptMapping.transcripts(from: result.segments, meetingId: meetingId)

        do {
            try await database.meetings.upsert(meeting)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            phase = .failed("Could not save the imported meeting: \(String(describing: error))")
            return
        }
        // An all-silence file yields no segments — that's a real outcome; the meeting is still
        // created, honestly, with zero transcripts (matching the Rust importer).
        if !transcripts.isEmpty {
            do {
                try await database.transcripts.upsert(transcripts)
            } catch {
                // Roll the just-created meeting back to a tombstone and remove the folder so a
                // failed import leaves no half-saved, audio-less meeting behind.
                try? await database.meetings.softDelete(meetingId, at: now)
                try? FileManager.default.removeItem(at: folder)
                phase = .failed("Could not save the imported transcript: \(String(describing: error))")
                return
            }
        }

        phase = .saved(meetingId)
    }

    /// `saved | failed -> idle`, so the sheet reopens clean. A no-op mid-import or from idle.
    public func reset() {
        switch phase {
        case .saved, .failed:
            phase = .idle
        case .idle, .importing:
            break
        }
    }

    // MARK: - Helpers

    /// Creates the meeting folder and copies the source audio into it, off the main actor. A
    /// pre-existing destination (a retried import into the same reused id — never happens with a
    /// fresh UUID, but defensive) is replaced rather than allowed to fail the copy.
    private static func prepareAudio(source: URL, folder: URL, destination: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        }.value
    }

    /// The file's own name (sans extension) as the default meeting title; a non-empty fallback so a
    /// pathological name never yields a blank title.
    private static func defaultTitle(for sourceURL: URL) -> String {
        let stem = sourceURL.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stem.isEmpty ? "Imported recording" : stem
    }

    /// Maps a transcription failure to honest, user-facing copy (No-Fake-State — the real reason,
    /// never a generic swallow).
    private static func describeTranscriptionFailure(_ error: any Error) -> String {
        guard let error = error as? TranscriptionError else {
            return "Transcription failed: \(String(describing: error))"
        }
        switch error {
        case let .providerUnavailable(reason):
            return "On-device transcription isn’t available on this device: \(reason)"
        case let .assetsNotInstalled(locale):
            return "The speech model for \(locale) isn’t installed yet. Record a short meeting once "
                + "to install it, then try importing again."
        case let .unsupportedLanguage(language):
            return "The transcription language “\(language)” isn’t supported."
        case let .audioDecodeFailed(reason):
            return "That file couldn’t be read as audio: \(reason)"
        case let .engineFailed(reason):
            return "Transcription failed: \(reason)"
        case let .audioTooShort(samples, minimum):
            return "The recording is too short to transcribe (\(samples) samples, need \(minimum))."
        case .modelNotLoaded:
            return "The transcription model isn’t loaded."
        }
    }
}
