//
//  AppEnvironment.swift — the @Observable root (plan §2.1). Owns the single `AppDatabase`
//  (single-DB-owner, principle 3) and hands its repositories down the view tree. View models
//  read from here; no view constructs its own database connection.
//
//  S0 scope: resolve the app-data dir, open (creating + migrating) the Store DB, and surface an
//  HONEST launch status (No-Fake-State — a failed open shows the real error, never a fake ready).
//  S8-lite (here): on the FIRST launch (new DB empty), import the existing library read-only from
//  the frozen Tauri app's data dir (`com.meetily.ai`). The repository-backed screens (S6) then
//  render real meetings. The legacy dir is only ever read — never written, never deleted.
//
import AriKit
import AriViewModels
import Foundation
import Observation

@MainActor
@Observable
final class AppEnvironment {
    enum Status: Equatable {
        case launching
        case importing
        case ready
        case failed(String)
    }

    private(set) var status: Status = .launching

    /// The single owner of the SQLite file. `nil` until `bootstrap()` succeeds.
    private(set) var database: AppDatabase?

    /// S0 sanity readout: the real row count from the opened DB (honest; empty on a fresh dir).
    private(set) var meetingCount: Int?

    /// The reconciliation report from the first-run legacy import, if one ran this launch. Honest
    /// counts (No-Fake-State) — `nil` when nothing was imported (already-populated DB, or no
    /// legacy library present).
    private(set) var importReport: ImportReport?

    /// The single app-wide recording session (docs/plans/ari-recording-page.md §4.1). Constructed
    /// once `database` exists (`status == .ready`) so it survives navigation — the recording
    /// page only ever renders it, never owns capture state itself.
    private(set) var recordingSession: RecordingSession?

    /// The one Keychain-backed secrets store (docs/plans/settings-ui.md §2.3) — backs
    /// `SecretsReading`/`RecallSecretsReading`/`SecretsStoring` all at once. Stateless, so it
    /// needs no `bootstrap()` gating; available from construction.
    let secrets: SecretsStoring = KeychainSecretStore()

    /// Bundle identifier decided 2026-07-20 (arikit-native-shell.md §9): the fresh Swift app.
    static let bundleIdentifier = "com.arivo.ari"

    /// The frozen Tauri app's bundle id — the read-only import source (arikit-native-shell.md §6.2).
    static let legacyBundleIdentifier = "com.meetily.ai"

    /// Opens the Store DB once, at launch. Idempotent-guarded so a re-entrant `.task` is a no-op.
    func bootstrap() async {
        guard database == nil else { return }
        do {
            let url = try Self.databaseURL()
            let db = try AppDatabase.makeShared(at: url)
            database = db

            // First-run import: gated on a persisted completion MARKER, not on row count. A
            // row-count guard (`count == 0`) can't tell "never imported" from "import was
            // interrupted" — an interrupted import would leave a partial library that a count
            // guard then freezes as if complete (a No-Fake-State violation at the data layer).
            // The importer is idempotent, so a marker-absent re-run safely finishes a partial
            // import; the marker is written only AFTER a clean run (no `sourceError`).
            if !Self.legacyImportCompleted(),
               let legacy = Self.legacyDatabaseURL(),
               FileManager.default.fileExists(atPath: legacy.path) {
                status = .importing
                let report = await LegacyDatabaseImporter.run(sourceURL: legacy, into: db)
                importReport = report
                if report.sourceError == nil {
                    Self.markLegacyImportCompleted()
                }
            }

            meetingCount = try await db.meetings.all().count

            // The real recording vertical (R5 capture + R6 live SpeechTranscriber).
            recordingSession = try RecordingSession(
                database: db,
                recordingsRoot: Self.recordingsRootURL(),
                makeCaptureService: { folder in LiveCaptureService(meetingFolder: folder) },
                transcription: SpeechLiveTranscriptionService()
            )

            status = .ready
        } catch {
            status = .failed(String(describing: error))
        }
    }

    /// `~/Library/Application Support/com.arivo.ari/ari.sqlite`, creating the directory if needed.
    /// The app resolves the path; the Store never touches FileManager (arikit-store.md §2.2).
    private static func databaseURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support.appendingPathComponent(bundleIdentifier, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ari.sqlite", isDirectory: false)
    }

    /// `~/Library/Application Support/com.arivo.ari/recordings`, creating the directory if
    /// needed (plan §5: "the app resolves the path; the Store never touches FileManager"). Each
    /// recording gets its own `<meetingID>/` subfolder, created by `RecordingSession` per-recording.
    private static func recordingsRootURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Sentinel marking that a legacy import ran to completion. Its presence — not the meeting
    /// row count — is the guard, so an interrupted import re-runs (the importer is idempotent)
    /// instead of freezing a partial library as if it were whole.
    private static func legacyImportMarkerURL() -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else {
            return nil
        }
        return support
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent(".legacy-import-complete", isDirectory: false)
    }

    private static func legacyImportCompleted() -> Bool {
        guard let marker = legacyImportMarkerURL() else { return false }
        return FileManager.default.fileExists(atPath: marker.path)
    }

    private static func markLegacyImportCompleted() {
        guard let marker = legacyImportMarkerURL() else { return }
        try? Data().write(to: marker)
    }

    /// The frozen Tauri app's SQLite file: `…/com.meetily.ai/meeting_minutes.sqlite`. Returns
    /// `nil` if Application Support can't be resolved; never creates the directory (read-only
    /// source). Existence is checked by the caller before opening.
    private static func legacyDatabaseURL() -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else {
            return nil
        }
        return support
            .appendingPathComponent(legacyBundleIdentifier, isDirectory: true)
            .appendingPathComponent("meeting_minutes.sqlite", isDirectory: false)
    }
}
