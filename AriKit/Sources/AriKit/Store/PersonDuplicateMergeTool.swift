//
//  PersonDuplicateMergeTool.swift — a one-shot, dry-run-first repair for the owner/attendee
//  duplicate-`Person` bug (docs/plans/duplicate-person-merge.md).
//
//  Root cause: the owner is seeded once from the macOS account name (no email,
//  `PersonRepository.ensureOwner`) and, separately, the SAME human is imported once as a calendar
//  attendee with an email (`upsertStubFromAttendee`) — two rows for one person. Because the owner
//  row has no email, calendar-attendee identity matching never resolves to it, so every meeting
//  where the owner is a calendar attendee attaches them as a PARTICIPANT under the duplicate row
//  instead, accumulating `profileFact`s there and bleeding cross-meeting content into summaries.
//
//  This tool finds that duplicate generically (a non-owner person sharing the owner's exact
//  display name), reports EXACTLY what a merge would move, and only writes when explicitly asked
//  to commit — see `AriKitTests/Store/OwnerDuplicateRepairTool.swift` for the deliberate,
//  env-var-gated invocation. It never runs implicitly (no call site in `AppEnvironment`/any view).
//
import Foundation

/// What `PersonDuplicateMergeTool.mergeOwnerDuplicate()` would move, computed WITHOUT writing
/// anything. Every count is a real read (No-Fake-State) — never estimated.
public struct OwnerDuplicateMergeReport: Sendable, Equatable {
    public let ownerId: PersonID
    public let ownerDisplayName: String
    public let ownerEmailBefore: String?
    public let duplicateId: PersonID
    public let duplicateDisplayName: String
    public let duplicateEmail: String?

    /// `profileFact` rows re-pointed from the duplicate to the owner.
    public let profileFactsToMove: Int
    /// `meetingParticipant` rows re-pointed from the duplicate to the owner.
    public let participantLinksToMove: Int
    /// `meetingParticipant` rows DROPPED because the owner is already linked to that same
    /// meeting — the owner's existing row (its `linkSource`) wins; see
    /// `PersonRepository.merge(duplicateId:into:)`'s doc comment for why.
    public let participantLinksToDrop: Int
    /// `speaker` rows re-pointed from the duplicate to the owner.
    public let speakersToMove: Int
    /// `series.ownerPersonId` rows re-pointed from the duplicate to the owner.
    public let seriesToRepoint: Int
}

/// Honest outcome of `planOwnerDuplicateMerge()` — never guesses when the candidate set isn't
/// exactly one (No-Fake-State: an ambiguous or absent duplicate must surface as such, not silently
/// pick one).
public enum OwnerDuplicateMergeOutcome: Sendable, Equatable {
    /// No owner is set yet — nothing to merge into.
    case noOwner
    /// No non-owner person shares the owner's display name — nothing to merge.
    case noCandidates
    /// More than one non-owner person shares the owner's display name — this tool refuses to
    /// guess which is the real duplicate; resolve manually (e.g. via `PersonRepository.merge`
    /// directly with the id you've confirmed).
    case ambiguous([PersonID])
    /// Exactly one candidate found; this is what merging it would do.
    case ready(OwnerDuplicateMergeReport)
}

/// Read-only planning + single-call commit for the owner/attendee duplicate repair. Construct with
/// the app's real `AppDatabase` (or a copy opened via `AppDatabase.makeShared(at:)`) — never opens
/// or resolves a path itself (plan §2.2: the Store never touches FileManager).
public struct PersonDuplicateMergeTool: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Case-/whitespace-insensitive display-name match — the only generic signal this tool uses to
    /// find "the same human as the owner, under a second row" without assuming anything about
    /// which one has the email.
    private static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Computes, WITHOUT WRITING ANYTHING, what merging the owner's name-duplicate would do.
    public func planOwnerDuplicateMerge() async throws -> OwnerDuplicateMergeOutcome {
        guard let owner = try await database.persons.owner() else { return .noOwner }

        let all = try await database.persons.all()
        let ownerKey = Self.normalizedName(owner.displayName)
        let candidates = all.filter { !$0.isOwner && Self.normalizedName($0.displayName) == ownerKey }

        guard !candidates.isEmpty else { return .noCandidates }
        guard candidates.count == 1, let duplicate = candidates.first else {
            return .ambiguous(candidates.map(\.id))
        }

        // Row-level, INCLUDING links to soft-deleted meetings: the merge re-points participant rows
        // unconditionally, so counting via `meetings(forPerson:)` (which hides soft-deleted ones)
        // would under-report the write we're asking a human to approve.
        let ownerMeetingIds = try await database.persons.participantMeetingIDs(forPerson: owner.id)
        let duplicateMeetingIds = try await database.persons.participantMeetingIDs(forPerson: duplicate.id)
        let collisions = ownerMeetingIds.intersection(duplicateMeetingIds)

        let allFacts = try await database.profileFacts.all(includingDeleted: true)
        let allSpeakers = try await database.speakers.all(includingDeleted: true)
        let allSeries = try await database.series.all(includingDeleted: true)

        let report = OwnerDuplicateMergeReport(
            ownerId: owner.id,
            ownerDisplayName: owner.displayName,
            ownerEmailBefore: owner.email,
            duplicateId: duplicate.id,
            duplicateDisplayName: duplicate.displayName,
            duplicateEmail: duplicate.email,
            profileFactsToMove: allFacts.filter { $0.personId == duplicate.id }.count,
            participantLinksToMove: duplicateMeetingIds.subtracting(collisions).count,
            participantLinksToDrop: collisions.count,
            speakersToMove: allSpeakers.filter { $0.personId == duplicate.id }.count,
            seriesToRepoint: allSeries.filter { $0.ownerPersonId == duplicate.id }.count
        )
        return .ready(report)
    }

    /// Commits the merge `planOwnerDuplicateMerge()` reported — re-plans and re-checks
    /// `.ready` immediately before writing (never trusts a caller-held stale report), then calls
    /// `PersonRepository.merge(duplicateId:into:)` with the duplicate merged INTO the owner (the
    /// owner's participant links win any collision — see that method's doc comment). Returns the
    /// merged owner `Person`, or `nil` if there was nothing to merge (`.noOwner`/`.noCandidates`).
    /// Throws only `OwnerDuplicateMergeOutcome` cases that need a human decision (`.ambiguous`)
    /// wrapped as `PersonDuplicateMergeToolError.ambiguousCandidates`.
    @discardableResult
    public func mergeOwnerDuplicate() async throws -> Person? {
        switch try await planOwnerDuplicateMerge() {
        case .noOwner, .noCandidates:
            return nil
        case let .ambiguous(candidateIds):
            throw PersonDuplicateMergeToolError.ambiguousCandidates(candidateIds)
        case let .ready(report):
            return try await database.persons.merge(duplicateId: report.duplicateId, into: report.ownerId)
        }
    }
}

public enum PersonDuplicateMergeToolError: Error, Sendable, Equatable {
    /// More than one non-owner person shares the owner's display name — refuses to guess.
    case ambiguousCandidates([PersonID])
}
