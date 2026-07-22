//
//  MeetingImportSessionTests.swift — docs/plans/audio-import.md, the import operation.
//
//  Headless: an in-memory `AppDatabase` + `StubTranscriptionProvider` (no Speech framework / device
//  assets / real audio decode). The source "audio" is a temp file of arbitrary bytes — the stub
//  provider never reads it, and `FileManager.copyItem` copies bytes regardless of content — so the
//  tests exercise the full copy → transcribe → persist path deterministically.
//
import Foundation
import Testing
@testable import AriKit
@testable import AriViewModels

@Suite("MeetingImportSession")
@MainActor
struct MeetingImportSessionTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingImportSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A real, copyable temp file with the given audio extension (contents are irrelevant).
    private func makeSourceFile(ext: String = "wav") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-source-\(UUID().uuidString).\(ext)", isDirectory: false)
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: url)
        return url
    }

    private func makeSession(
        database: AppDatabase,
        provider: any TranscriptionProvider,
        clock: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) }
    ) throws -> (MeetingImportSession, URL) {
        let root = try makeRoot()
        let session = MeetingImportSession(
            database: database,
            recordingsRoot: root,
            transcription: provider,
            clock: clock
        )
        return (session, root)
    }

    // MARK: - The feature: user-chosen meeting date/time -> createdAt

    @Test("imported meeting's createdAt is the chosen date, not the import instant")
    func createdAtIsChosenDate() async throws {
        let database = try AppDatabase.makeInMemory()
        let provider = StubTranscriptionProvider(cannedSegments: [
            TranscriptionSegment(text: "hello", startSec: 0, endSec: 1, confidence: 0.9, words: []),
        ])
        let importInstant = Date(timeIntervalSince1970: 1_700_000_000) // "now" at import
        let (session, _) = try makeSession(database: database, provider: provider, clock: { importInstant })
        let source = try makeSourceFile()

        // A meeting that actually happened well in the past.
        let meetingDate = Date(timeIntervalSince1970: 1_600_000_000)
        await session.importFile(at: source, title: "Kickoff", meetingDate: meetingDate)

        guard case let .saved(meetingId) = session.phase else {
            Issue.record("expected .saved, got \(session.phase)")
            return
        }
        let meeting = try #require(try await database.meetings.find(meetingId))
        #expect(abs(meeting.createdAt.timeIntervalSince(meetingDate)) < 0.001) // the feature
        #expect(abs(meeting.updatedAt.timeIntervalSince(importInstant)) < 0.001) // real import instant
        #expect(meeting.title == "Kickoff")
    }

    // MARK: - Transcripts persisted + mapped from segments

    @Test("segments are mapped and persisted as transcript rows")
    func transcriptsPersisted() async throws {
        let database = try AppDatabase.makeInMemory()
        let provider = StubTranscriptionProvider(cannedSegments: [
            TranscriptionSegment(text: "first", startSec: 0, endSec: 2, confidence: 0.9, words: []),
            TranscriptionSegment(text: "second", startSec: 2, endSec: 5, confidence: 0.8, words: []),
        ])
        let (session, _) = try makeSession(database: database, provider: provider)
        let source = try makeSourceFile()

        await session.importFile(at: source, title: "Standup", meetingDate: Date(timeIntervalSince1970: 1_600_000_000))

        guard case let .saved(meetingId) = session.phase else {
            Issue.record("expected .saved, got \(session.phase)")
            return
        }
        let rows = try await database.transcripts.forMeeting(meetingId)
        #expect(rows.count == 2)
        #expect(rows.map(\.transcript) == ["first", "second"])
        #expect(rows.first?.audioStartTime == 0)
        #expect(rows.first?.audioEndTime == 2)
    }

    // MARK: - Audio reference points at the copied file

    @Test("audio is copied into the meeting folder and referenced by full path")
    func audioCopiedAndReferenced() async throws {
        let database = try AppDatabase.makeInMemory()
        let (session, root) = try makeSession(
            database: database,
            provider: StubTranscriptionProvider(cannedSegments: [])
        )
        let source = try makeSourceFile(ext: "mp3")

        await session.importFile(at: source, title: "Note", meetingDate: Date(timeIntervalSince1970: 1_600_000_000))

        guard case let .saved(meetingId) = session.phase else {
            Issue.record("expected .saved, got \(session.phase)")
            return
        }
        let meeting = try #require(try await database.meetings.find(meetingId))
        let ref = try #require(meeting.audioReference)
        let expected = root
            .appendingPathComponent(meetingId.rawValue, isDirectory: true)
            .appendingPathComponent("audio.mp3", isDirectory: false)
        #expect(ref.path == expected.path)
        #expect(FileManager.default.fileExists(atPath: expected.path))
    }

    // MARK: - Silence is a real outcome (No-Fake-State)

    @Test("an all-silence file still creates the meeting with zero transcripts")
    func silentImportStillSaves() async throws {
        let database = try AppDatabase.makeInMemory()
        let (session, _) = try makeSession(
            database: database,
            provider: StubTranscriptionProvider(cannedSegments: [])
        )
        let source = try makeSourceFile()

        await session.importFile(at: source, title: "Quiet", meetingDate: Date(timeIntervalSince1970: 1_600_000_000))

        guard case let .saved(meetingId) = session.phase else {
            Issue.record("expected .saved, got \(session.phase)")
            return
        }
        #expect(try await database.transcripts.forMeeting(meetingId).isEmpty)
        #expect(try await database.meetings.find(meetingId) != nil)
    }

    // MARK: - Honest failure leaves nothing behind

    @Test("a transcription failure fails honestly and persists no meeting")
    func transcriptionFailureLeavesNoMeeting() async throws {
        let database = try AppDatabase.makeInMemory()
        let (session, root) = try makeSession(
            database: database,
            provider: StubTranscriptionProvider(error: .engineFailed("boom"))
        )
        let source = try makeSourceFile()

        await session.importFile(at: source, title: "Doomed", meetingDate: Date(timeIntervalSince1970: 1_600_000_000))

        guard case let .failed(reason) = session.phase else {
            Issue.record("expected .failed, got \(session.phase)")
            return
        }
        #expect(reason.contains("boom"))
        #expect(try await database.meetings.all().isEmpty)
        // The copied-audio folder is cleaned up on failure.
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test("an unsupported extension fails honestly without creating a folder")
    func unsupportedExtensionFails() async throws {
        let database = try AppDatabase.makeInMemory()
        let (session, root) = try makeSession(
            database: database,
            provider: StubTranscriptionProvider(cannedSegments: [])
        )
        let source = try makeSourceFile(ext: "txt")

        await session.importFile(at: source, title: "Nope", meetingDate: Date(timeIntervalSince1970: 1_600_000_000))

        guard case let .failed(reason) = session.phase else {
            Issue.record("expected .failed, got \(session.phase)")
            return
        }
        #expect(reason.contains("Unsupported"))
        #expect(try await database.meetings.all().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    // MARK: - Reentrancy / terminal re-entry

    @Test("a fresh import after a completed one creates a second, distinct meeting")
    func terminalReentryStartsFresh() async throws {
        let database = try AppDatabase.makeInMemory()
        let (session, _) = try makeSession(
            database: database,
            provider: StubTranscriptionProvider(cannedSegments: [
                TranscriptionSegment(text: "x", startSec: 0, endSec: 1, confidence: 1, words: []),
            ])
        )

        await session.importFile(at: try makeSourceFile(), title: "One", meetingDate: Date(timeIntervalSince1970: 1_600_000_000))
        guard case .saved = session.phase else {
            Issue.record("first import did not save: \(session.phase)")
            return
        }
        await session.importFile(at: try makeSourceFile(), title: "Two", meetingDate: Date(timeIntervalSince1970: 1_600_050_000))
        guard case .saved = session.phase else {
            Issue.record("second import did not save: \(session.phase)")
            return
        }

        let titles = try await database.meetings.all().map(\.title).sorted()
        #expect(titles == ["One", "Two"])
    }

    @Test("reset() returns a terminal phase to idle")
    func resetClearsTerminalPhase() async throws {
        let database = try AppDatabase.makeInMemory()
        let (session, _) = try makeSession(
            database: database,
            provider: StubTranscriptionProvider(error: .engineFailed("boom"))
        )
        await session.importFile(at: try makeSourceFile(), title: "X", meetingDate: Date(timeIntervalSince1970: 1_600_000_000))
        guard case .failed = session.phase else {
            Issue.record("expected .failed, got \(session.phase)")
            return
        }
        session.reset()
        #expect(session.phase == .idle)
    }
}
