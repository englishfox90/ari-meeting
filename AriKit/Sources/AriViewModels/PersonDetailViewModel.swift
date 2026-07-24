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
    /// `id`/`isOwner`/`createdAt`/`organization`.
    ///
    /// Returns `nil` on success, or a human-readable error string on failure/rejection (the
    /// write is NOT swallowed — No-Fake-State: a rejected save must surface, not look like it
    /// worked). No-ops (returns an error) when `name` trims to empty or no person is loaded.
    ///
    /// **Email is the identity key** (`upsertStubFromAttendee` dedups on it), so two rules apply
    /// (2026-07-23 duplicate-Ryan incident, see `EmailValidation`):
    /// - **Read-only once set** — if this person already has an email, it is preserved and any
    ///   incoming change is ignored (correcting a wrong email is a merge/heal operation, not a
    ///   free-text edit that would silently split identity).
    /// - **Validated when first set** — setting an email requires a structurally valid address,
    ///   so a display name can never land in the email field.
    @discardableResult
    public func saveIdentity(
        name: String,
        email: String?,
        role: String?,
        domain: String?,
        notes: String?
    ) async -> String? {
        guard let id = personId, case let .loaded(current) = person else {
            return "No person is loaded."
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return "Name can't be empty." }

        let resolvedEmail: String?
        if let existing = current.email, !existing.isEmpty {
            // Locked: keep the existing key regardless of what the (disabled) field submitted.
            resolvedEmail = existing
        } else if let incoming = EmailValidation.normalized(email) {
            guard EmailValidation.isValid(incoming) else {
                return "“\(incoming)” isn't a valid email address."
            }
            resolvedEmail = incoming
        } else {
            resolvedEmail = nil
        }

        var updated = current
        updated.displayName = trimmedName
        updated.email = resolvedEmail
        updated.role = nonEmpty(role)
        updated.domain = nonEmpty(domain)
        updated.notes = nonEmpty(notes)
        updated.updatedAt = Date()

        do {
            try await database.persons.upsert(updated)
            await load(id)
            return nil
        } catch {
            // First-setting an email that another person already holds trips the `person.email`
            // UNIQUE index. That's exactly the "two rows, one human" case this feature guards
            // against — surface it as a merge hint rather than a raw SQLite string (still honest,
            // No-Fake-State), since this editor has no merge affordance of its own yet.
            if String(describing: error).contains("UNIQUE constraint failed: person.email") {
                return "Another person already uses this email — they may need to be merged."
            }
            return String(describing: error)
        }
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

    /// Runs `PersonFactConsolidation` (docs/plans/person-fact-consolidation.md §7) over the
    /// currently-loaded person's facts, reloads the fact buckets, and returns the honest result
    /// message for the caller to surface (mirrors `saveIdentity`'s "return a string, caller
    /// displays it" pattern). `settings`/`secrets`/`clientFactory` are injected by the caller —
    /// this view model has no Keychain/settings-table access of its own (same reason
    /// `SettingsViewModel` takes `secrets` as an init param rather than constructing its own).
    /// No-ops (returns an honest "no person loaded" message) when nothing is loaded yet.
    public func consolidateFacts(
        settings: any SettingsReading,
        secrets: any SecretsReading,
        clientFactory: @escaping @Sendable (ProviderConfig) throws -> any LLMClient = {
            try ProviderFactory.make(config: $0)
        }
    ) async -> String {
        guard let id = personId else { return "No person is loaded." }
        let consolidation = PersonFactConsolidation(
            db: database, settings: settings, secrets: secrets, clientFactory: clientFactory
        )
        let result = await (try? consolidation.consolidateFacts(for: id))
            ?? ConsolidationResult(merged: 0, factsRetired: 0, kept: 0, message: "Consolidation failed.")
        await reloadFacts()
        return result.message
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
