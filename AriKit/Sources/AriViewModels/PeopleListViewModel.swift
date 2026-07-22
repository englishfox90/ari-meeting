//
//  PeopleListViewModel.swift — the People list screen's view model
//  (docs/plans/people-view-parity.md §2.4 Slice 3).
//
//  Mirrors `MeetingsListViewModel`'s load pattern for the roster: a one-shot
//  `PersonRepository.all()` read (so a real read failure surfaces as an honest
//  `.failed(String)`), then live updates via `observeAll()`. `.empty` is a first-class,
//  honest state distinct from `.loaded([])`.
//
//  `owner`, `pendingFacts`, `signatures`, and `factCounts` are auxiliary slices refreshed
//  alongside the roster (and after any mutating action) — each is best-effort (a read
//  failure there leaves the slice at its last-known/empty value rather than failing the
//  whole screen, since the roster itself is the load-bearing state).
//
import AriKit
import Foundation
import Observation

@MainActor
@Observable
public final class PeopleListViewModel {
    public private(set) var state: LoadState<[Person]> = .loading
    /// The current search query. Filtering is derived (`filtered`); the underlying `state` is
    /// left whole so clearing the query restores the full list without a re-read.
    public var searchText: String = ""

    /// The recording owner, if one has been set — `nil` until `observe()`/`saveOwner(_:)`
    /// resolves it (best-effort; a read failure just leaves this `nil`, matching the
    /// honest-empty "Set up profile" affordance rather than fabricating a placeholder owner).
    public private(set) var owner: Person?
    /// Every non-deleted pending fact across every person, for the cross-person review list.
    /// Best-effort: a read failure leaves this empty rather than blocking the roster.
    public private(set) var pendingFacts: [ProfileFactWithPerson] = []
    /// Each person's canonical enrolled voiceprint signature, keyed by person id — only present
    /// for persons with a real enrolled voiceprint (No-Fake-State: a missing key means no glyph,
    /// never an invented one).
    public private(set) var signatures: [PersonID: [Float]] = [:]
    /// Per-person `(pending, active)` fact badge counts. A missing key means `(0, 0)`.
    public private(set) var factCounts: [PersonID: ProfileFactRepository.FactCounts] = [:]

    private let database: AppDatabase
    private var observationTask: Task<Void, Never>?

    public init(database: AppDatabase) {
        self.database = database
    }

    /// The loaded roster, owner excluded, filtered by `searchText` (case-insensitive over
    /// display name / email / role). Empty unless `state` is `.loaded`.
    public var filtered: [Person] {
        guard case let .loaded(all) = state else { return [] }
        let others = all.filter { !$0.isOwner }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return others }
        return others.filter { person in
            person.displayName.localizedCaseInsensitiveContains(query)
                || (person.email?.localizedCaseInsensitiveContains(query) ?? false)
                || (person.role?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    /// True when the user has a non-empty query that matches no one in a genuinely non-empty
    /// (owner-excluded) roster — an honest "no matches" state distinct from "no people exist at
    /// all" (empty roster, empty query).
    public var hasNoMatches: Bool {
        guard case let .loaded(all) = state else { return false }
        let others = all.filter { !$0.isOwner }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !others.isEmpty, !query.isEmpty else { return false }
        return filtered.isEmpty
    }

    /// Loads the initial roster (honest `.failed` on a real error), the auxiliary slices, then
    /// starts consuming the live persons stream for updates. Idempotent-guarded so a re-entrant
    /// `.task` doesn't start a second live observer.
    public func observe() async {
        do {
            let people = try await database.persons.all()
            state = people.isEmpty ? .empty : .loaded(people)
        } catch {
            state = .failed(String(describing: error))
            return
        }

        await refreshOwner()
        await refreshPendingFacts()
        await refreshSignatures()
        await refreshFactCounts()

        guard observationTask == nil else { return }
        let stream = database.persons.observeAll()
        observationTask = Task { [weak self] in
            for await people in stream {
                guard let self else { return }
                state = people.isEmpty ? .empty : .loaded(people)
            }
        }
    }

    // MARK: - Owner actions

    /// Saves the owner profile: mutates the existing owner in place (preserving id/createdAt) if
    /// one exists, otherwise creates a new owner `Person`. `setOwner` is called either way so the
    /// single-true-owner invariant is repository-enforced, not hand-rolled here. Best-effort — a
    /// write failure leaves `owner` at its prior value.
    public func saveOwner(
        displayName: String,
        email: String?,
        role: String?,
        organization: String?,
        domain: String?,
        notes: String?
    ) async {
        let now = Date()
        var person: Person = if let existing = owner {
            existing
        } else {
            Person(
                id: PersonID(UUID().uuidString),
                displayName: displayName,
                isOwner: true,
                createdAt: now,
                updatedAt: now
            )
        }
        person.displayName = displayName
        person.email = email
        person.role = role
        person.organization = organization
        person.domain = domain
        person.notes = notes
        person.updatedAt = now

        try? await database.persons.upsert(person)
        try? await database.persons.setOwner(person.id)
        await refreshOwner()
    }

    // MARK: - Pending-fact actions

    /// Confirms a pending fact, then refreshes the pending list + badge counts (a confirm moves
    /// a person's count from "pending" to "active").
    public func confirmPendingFact(_ id: ProfileFactID) async {
        try? await database.profileFacts.confirmFact(id)
        await refreshPendingFacts()
        await refreshFactCounts()
    }

    /// Rejects a pending fact, then refreshes the pending list + badge counts.
    public func rejectPendingFact(_ id: ProfileFactID) async {
        try? await database.profileFacts.rejectFact(id)
        await refreshPendingFacts()
        await refreshFactCounts()
    }

    // MARK: - Auxiliary slice refreshes (best-effort)

    private func refreshOwner() async {
        owner = try? await database.persons.owner()
    }

    private func refreshPendingFacts() async {
        pendingFacts = await (try? database.profileFacts.pendingFactsAll()) ?? []
    }

    private func refreshFactCounts() async {
        factCounts = await (try? database.profileFacts.factCounts()) ?? [:]
    }

    private func refreshSignatures() async {
        guard let speakers = try? await database.speakers.listCanonicalEnrolled() else {
            signatures = [:]
            return
        }
        var result: [PersonID: [Float]] = [:]
        for speaker in speakers {
            guard let personId = speaker.personId,
                  let signature = Voiceprint.signature(fromCentroid: speaker.centroid) else { continue }
            result[personId] = signature
        }
        signatures = result
    }
}
