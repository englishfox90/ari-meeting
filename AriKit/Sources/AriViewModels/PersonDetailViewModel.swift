//
//  PersonDetailViewModel.swift — the Person detail screen's view model
//  (docs/plans/people-view-parity.md §2.4 Slice 4).
//
//  One-shot read (mirroring `MeetingDetailViewModel`'s detail-VM pattern), plus auxiliary
//  slices (participant meetings, voiceprint signature, fact buckets) refreshed alongside the
//  person and after any mutating action. Auxiliary slices are best-effort: a read failure
//  there leaves the slice at its last-known/empty value rather than failing the whole screen,
//  since `person` is the load-bearing state (mirrors `PeopleListViewModel`'s precedent).
//
//  Fact bucketing (← `frontend/src/app/person-details/page.tsx`): `listActiveAndPending(for:)`
//  splits into `pending` (status == .pending) and the active set, which is further split by
//  `factsNeedingReview(person:staleDays:28)` into `needsReview` (stale, still active) vs.
//  `active` (fresh). `others` (superseded/rejected/removed) is a client-side filter over
//  `all()` — no repository method returns just that bucket, and this VM only reads, never
//  fabricates, the split.
//
import AriKit
import Foundation
import Observation

@MainActor
@Observable
public final class PersonDetailViewModel {
    /// Facts older than this many days since last confirmation (or creation) surface in
    /// `needsReview` rather than `active` (← the React "over four weeks" bucket).
    public static let staleReviewDays = 28

    public private(set) var person: LoadState<Person> = .loading
    /// Meetings this person participated in, newest first (← `PersonRepository.meetings(forPerson:)`).
    public private(set) var participantMeetings: [Meeting] = []
    public var meetingCount: Int {
        participantMeetings.count
    }

    /// This person's canonical enrolled voiceprint signature, or `nil` when none is enrolled yet
    /// (No-Fake-State: the view must show honest "no voiceprint" copy, never a placeholder ring).
    public private(set) var signature: [Float]?

    /// Facts awaiting explicit Confirm/Reject.
    public private(set) var pendingFacts: [ProfileFact] = []
    /// Active facts that have gone stale (not reaffirmed in `staleReviewDays`) — Reaffirm/Dismiss.
    public private(set) var needsReviewFacts: [ProfileFact] = []
    /// Fresh active facts, read-only.
    public private(set) var activeFacts: [ProfileFact] = []
    /// Superseded/rejected/removed facts, read-only.
    public private(set) var otherFacts: [ProfileFact] = []

    private let database: AppDatabase
    private var personId: PersonID?

    public init(database: AppDatabase) {
        self.database = database
    }

    public func load(_ id: PersonID) async {
        personId = id
        do {
            guard let resolved = try await database.persons.find(id) else {
                person = .failed("Person not found.")
                return
            }
            person = .loaded(resolved)
        } catch {
            person = .failed(String(describing: error))
            return
        }

        await refreshMeetings(id)
        await refreshSignature(id)
        await refreshFacts(id)
    }

    // MARK: - Identity

    /// Saves authored identity fields onto the currently-loaded person, preserving
    /// `id`/`isOwner`/`createdAt`/`organization`. No-ops when `name` trims to empty, or when no
    /// person is loaded — mirrors `PeopleListViewModel.saveOwner`'s best-effort write pattern.
    public func saveIdentity(
        name: String,
        email: String?,
        role: String?,
        domain: String?,
        notes: String?
    ) async {
        guard let id = personId, case let .loaded(current) = person else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        var updated = current
        updated.displayName = trimmedName
        updated.email = nonEmpty(email)
        updated.role = nonEmpty(role)
        updated.domain = nonEmpty(domain)
        updated.notes = nonEmpty(notes)
        updated.updatedAt = Date()

        try? await database.persons.upsert(updated)
        await load(id)
    }

    // MARK: - Fact actions

    public func confirmFact(_ id: ProfileFactID) async {
        try? await database.profileFacts.confirmFact(id)
        await reloadFacts()
    }

    public func rejectFact(_ id: ProfileFactID) async {
        try? await database.profileFacts.rejectFact(id)
        await reloadFacts()
    }

    /// Alias for `confirmFact` — the "Reaffirm" action on a stale-review row.
    public func reaffirm(_ id: ProfileFactID) async {
        await confirmFact(id)
    }

    /// Alias for `rejectFact` — the "Dismiss" action on a stale-review row.
    public func dismiss(_ id: ProfileFactID) async {
        await rejectFact(id)
    }

    /// Adds a manually-authored fact (lands `.active` — Rust/repository parity). No-ops on an
    /// empty trimmed `text`, or when no person is loaded.
    public func addManualFact(text: String, kind: FactKind) async {
        guard let id = personId else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = try? await database.profileFacts.addManualFact(personId: id, factText: trimmed, factKind: kind)
        await reloadFacts()
    }

    /// Lazy-loads a fact's full provenance lineage for the "Seen in N meetings" expansion.
    /// Never fabricated — `nil`/empty when the fact has no recorded sources.
    public func provenance(for factID: ProfileFactID) async -> ProfileFactWithProvenance? {
        try? await database.profileFacts.withProvenance(factID)
    }

    // MARK: - Auxiliary slice refreshes (best-effort)

    private func refreshMeetings(_ id: PersonID) async {
        participantMeetings = await (try? database.persons.meetings(forPerson: id)) ?? []
    }

    private func refreshSignature(_ id: PersonID) async {
        guard let speaker = try? await database.speakers.canonicalEnrolledSpeaker(for: id) else {
            signature = nil
            return
        }
        signature = Voiceprint.signature(fromCentroid: speaker.centroid)
    }

    private func refreshFacts(_ id: PersonID) async {
        let activeAndPending = await (try? database.profileFacts.listActiveAndPending(for: id)) ?? []
        let needingReview = await (try? database.profileFacts.factsNeedingReview(
            person: id, staleDays: Self.staleReviewDays
        )) ?? []
        let needsReviewIds = Set(needingReview.filter { $0.status == .active }.map(\.id))

        pendingFacts = activeAndPending.filter { $0.status == .pending }
        needsReviewFacts = activeAndPending.filter { $0.status == .active && needsReviewIds.contains($0.id) }
        activeFacts = activeAndPending.filter { $0.status == .active && !needsReviewIds.contains($0.id) }

        let otherStatuses: Set<FactStatus> = [.superseded, .rejected, .removed]
        let all = await (try? database.profileFacts.all()) ?? []
        otherFacts = all.filter { $0.personId == id && otherStatuses.contains($0.status) }
    }

    private func reloadFacts() async {
        guard let id = personId else { return }
        await refreshFacts(id)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
