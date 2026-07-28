//
//  OwnerDuplicateRepairTool.swift — the ONE-SHOT, deliberate invocation of
//  `PersonDuplicateMergeTool` against a REAL (never the live) `ari.sqlite` file
//  (docs/plans/duplicate-person-merge.md).
//
//  This is not exercised by a normal `swift test` run — it is gated on an env var that is unset
//  by default, so CI and routine local test runs record an honest SKIP (mirrors
//  `SpeechTranscriberSmokeTest`/`FluidAudioDiarizationProviderTests`'s env-gated-integration-test
//  discipline). It NEVER runs automatically from the app.
//
//  ============================== HOW TO INVOKE ==============================
//  1. Work on a COPY, never the live DB. A verified pre-merge snapshot already exists at
//     `~/Library/Application Support/com.arivo.ari/backups/ari-premerge-20260728-manual.sqlite`
//     (that directory is where `AppEnvironment`'s rolling pre-migration backups actually land —
//     NOT a repo-root `backups/`) — copy it somewhere scratch:
//       cp "~/Library/Application Support/com.arivo.ari/backups/ari-premerge-20260728-manual.sqlite" \
//         /tmp/ari-repair-scratch.sqlite
//
//  2. DRY RUN (default — reports what WOULD move, writes nothing):
//       ARIKIT_OWNER_DUPLICATE_DB_PATH=/tmp/ari-repair-scratch.sqlite \
//         swift test --package-path AriKit --filter OwnerDuplicateRepairTool
//     Read the printed report. Opening the DB itself is safe: `AppDatabase.makeShared` runs the
//     (already-applied, additive-only) migrator with `eraseDatabaseOnSchemaChange: false` and
//     performs no other writes; `planOwnerDuplicateMerge()` performs zero writes of its own.
//
//  3. COMMIT (only once the dry-run report above looks right — run against the SAME scratch copy
//     first; only point this at the real `~/Library/Application Support/com.arivo.ari/ari.sqlite`
//     once you've reviewed a dry run against a copy of THAT exact file):
//       ARIKIT_OWNER_DUPLICATE_DB_PATH=/tmp/ari-repair-scratch.sqlite \
//       ARIKIT_OWNER_DUPLICATE_COMMIT=1 \
//         swift test --package-path AriKit --filter OwnerDuplicateRepairTool
//     This calls `PersonDuplicateMergeTool.mergeOwnerDuplicate()`, which re-plans and re-checks
//     immediately before writing (never trusts a stale report), then performs the merge in ONE
//     GRDB write transaction via `PersonRepository.merge(duplicateId:into:)`.
//  =============================================================================
//
import Foundation
import Testing
@testable import AriKit

private let dbPathEnvVar = "ARIKIT_OWNER_DUPLICATE_DB_PATH"
private let commitEnvVar = "ARIKIT_OWNER_DUPLICATE_COMMIT"

struct OwnerDuplicateRepairTool {
    @Test func runOwnerDuplicateRepair() async throws {
        guard let path = ProcessInfo.processInfo.environment[dbPathEnvVar], !path.isEmpty else {
            print(
                "SKIP: runOwnerDuplicateRepair — set \(dbPathEnvVar) to a COPY of ari.sqlite to run "
                    + "this one-shot repair. See this file's header for exact invocation."
            )
            return
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("SKIP: runOwnerDuplicateRepair — \(dbPathEnvVar)=\(path) does not exist.")
            return
        }

        let db = try AppDatabase.makeShared(at: url)
        let tool = PersonDuplicateMergeTool(database: db)

        let outcome = try await tool.planOwnerDuplicateMerge()
        print("Owner-duplicate merge plan for \(path):")
        switch outcome {
        case .noOwner:
            print("  No owner is set in this database — nothing to merge.")
        case .noCandidates:
            print("  No non-owner person shares the owner's display name — nothing to merge.")
        case let .ambiguous(ids):
            print(
                "  AMBIGUOUS: \(ids.count) non-owner persons share the owner's display name "
                    + "(\(ids.map(\.rawValue).joined(separator: ", "))) — refusing to guess. "
                    + "Resolve manually via PersonRepository.merge(duplicateId:into:)."
            )
        case let .ready(report):
            print("  Owner:               \(report.ownerDisplayName) (\(report.ownerId.rawValue))")
            print("  Owner email before:  \(report.ownerEmailBefore ?? "(none)")")
            print("  Duplicate:           \(report.duplicateDisplayName) (\(report.duplicateId.rawValue))")
            print("  Duplicate email:     \(report.duplicateEmail ?? "(none)") — would carry onto the owner")
            print("  profileFact rows to move:        \(report.profileFactsToMove)")
            print("  meetingParticipant rows to move: \(report.participantLinksToMove)")
            print("  meetingParticipant rows to drop: \(report.participantLinksToDrop) (owner's row wins)")
            print("  speaker rows to move:            \(report.speakersToMove)")
            print("  series.ownerPersonId to repoint:  \(report.seriesToRepoint)")
        }

        guard ProcessInfo.processInfo.environment[commitEnvVar] == "1" else {
            print("DRY RUN ONLY — nothing was written. Set \(commitEnvVar)=1 to commit this exact plan.")
            return
        }

        guard case .ready = outcome else {
            print("Nothing to commit (outcome was not .ready).")
            return
        }

        let merged = try await tool.mergeOwnerDuplicate()
        if let merged {
            print("COMMITTED. Owner \(merged.displayName) now holds email \(merged.email ?? "(none)").")
        } else {
            print("COMMITTED (no-op — the plan changed between the two reads; re-run to check).")
        }
    }
}
