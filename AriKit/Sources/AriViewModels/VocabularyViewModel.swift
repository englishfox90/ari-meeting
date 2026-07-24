//
//  VocabularyViewModel.swift — the Settings custom-vocabulary editor's view model
//  (docs/plans/custom-vocabulary.md §2.5/§8 Step 5).
//
//  Mirrors `PeopleListViewModel`'s load pattern: a one-shot `VocabularyRepository.all()` read (so a
//  real read failure surfaces as an honest `.failed(String)`), then live updates via
//  `observeAll()`. Every mutating action is a throwing entrypoint over `VocabularyRepository` —
//  `VocabularyError.duplicateTerm` / `.capExceeded` / `.emptyTerm` are surfaced as real
//  human-readable messages, never silently swallowed (No-Fake-State: the cap and duplicate checks
//  are load-bearing correctness, not cosmetic validation).
//
import AriKit
import Foundation
import Observation

@MainActor
@Observable
public final class VocabularyViewModel {
    public private(set) var state: LoadState<[VocabularyTerm]> = .loading
    /// The real number of ENABLED terms, tracked independently of `state.value.count` so it stays
    /// accurate even while `state` is `.loading`/`.failed` (e.g. reflecting the cap in a banner
    /// that renders before the list itself resolves).
    public private(set) var enabledCount: Int = 0
    /// The most recent `VocabularyBias.resolve(_:)` result over the CURRENT enabled terms — used
    /// only to surface `droppedVariantCount` honestly; never persisted, never fed to a live
    /// transcription (that snapshot happens once per session inside `VocabularySource`).
    public private(set) var droppedVariantCount: Int = 0
    /// The most recent mutating-action failure, human-readable. Set on every thrown error from
    /// add/update/delete/setEnabled; cleared at the start of the next attempt.
    public private(set) var errorMessage: String?

    public var isAtCap: Bool { enabledCount >= VocabularyBias.maxEnabledTerms }
    public var terms: [VocabularyTerm] { state.value ?? [] }

    private let database: AppDatabase
    private var observationTask: Task<Void, Never>?

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Loads the initial list (honest `.failed` on a real error), then starts consuming the live
    /// vocabulary stream for updates. Idempotent-guarded so a re-entrant `.task` doesn't start a
    /// second live observer.
    public func observe() async {
        do {
            let all = try await database.vocabulary.all()
            state = all.isEmpty ? .empty : .loaded(all)
        } catch {
            state = .failed(String(describing: error))
            return
        }

        await refreshDerivedCounts()

        guard observationTask == nil else { return }
        let stream = database.vocabulary.observeAll()
        observationTask = Task { [weak self] in
            for await terms in stream {
                guard let self else { return }
                state = terms.isEmpty ? .empty : .loaded(terms)
                await refreshDerivedCounts()
            }
        }
    }

    /// Adds a NEW term. Returns `nil` on success, or a real human-readable error message on
    /// failure — the caller keeps its form open and shows the message rather than pretending the
    /// term was saved (No-Fake-State).
    @discardableResult
    public func add(
        term: String,
        definition: String?,
        alternateForms: [String],
        misheardAs: [String],
        isEnabled: Bool
    ) async -> String? {
        let now = Date()
        let newTerm = VocabularyTerm(
            id: VocabularyTermID(UUID().uuidString),
            term: term,
            definition: definition,
            alternateForms: alternateForms,
            misheardAs: misheardAs,
            isEnabled: isEnabled,
            createdAt: now,
            updatedAt: now
        )
        return await save(newTerm)
    }

    /// Updates an EXISTING term in place (preserves `id`/`createdAt`). Returns `nil` on success, or
    /// a real error message on failure.
    @discardableResult
    public func update(
        _ existing: VocabularyTerm,
        term: String,
        definition: String?,
        alternateForms: [String],
        misheardAs: [String],
        isEnabled: Bool
    ) async -> String? {
        var updated = existing
        updated.term = term
        updated.definition = definition
        updated.alternateForms = alternateForms
        updated.misheardAs = misheardAs
        updated.isEnabled = isEnabled
        updated.updatedAt = Date()
        return await save(updated)
    }

    private func save(_ term: VocabularyTerm) async -> String? {
        errorMessage = nil
        do {
            try await database.vocabulary.upsert(term)
            await refreshDerivedCounts()
            return nil
        } catch {
            let message = Self.userFacingMessage(for: error)
            errorMessage = message
            return message
        }
    }

    /// Enables/disables a term. Surfaces `.capExceeded` honestly (the toggle visually reverts,
    /// since the mutation never actually happened) rather than flipping the switch and silently
    /// failing to persist it.
    public func setEnabled(_ isEnabled: Bool, for id: VocabularyTermID) async {
        errorMessage = nil
        do {
            try await database.vocabulary.setEnabled(isEnabled, for: id)
            await refreshDerivedCounts()
        } catch {
            errorMessage = Self.userFacingMessage(for: error)
        }
    }

    /// Soft-deletes a term, then refreshes derived counts (a delete can free the cap).
    public func delete(_ id: VocabularyTermID) async {
        errorMessage = nil
        do {
            try await database.vocabulary.softDelete(id, at: Date())
            await refreshDerivedCounts()
        } catch {
            errorMessage = Self.userFacingMessage(for: error)
        }
    }

    private func refreshDerivedCounts() async {
        enabledCount = (try? await database.vocabulary.enabledCount()) ?? 0
        guard let enabled = try? await database.vocabulary.enabledTerms() else {
            droppedVariantCount = 0
            return
        }
        droppedVariantCount = VocabularyBias.resolve(enabled)?.droppedCount ?? 0
    }

    /// Translates `VocabularyError` into the exact copy the Settings sheet shows — real numbers,
    /// never a generic "something went wrong" (No-Fake-State).
    private static func userFacingMessage(for error: Error) -> String {
        switch error {
        case let VocabularyError.duplicateTerm(term):
            return "“\(term)” is already in your vocabulary."
        case let VocabularyError.capExceeded(limit):
            return "You already have \(limit) enabled terms — the maximum. Disable or delete one to enable this term."
        case VocabularyError.emptyTerm:
            return "Enter a term before saving."
        default:
            return String(describing: error)
        }
    }
}
