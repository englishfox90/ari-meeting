//
//  VocabularySource.swift — the real `vocabularyBias` seam for `SpeechTranscriberProvider`
//  (docs/plans/custom-vocabulary.md §2.4).
//
//  Thin `Sendable` struct over `AppDatabase`: reads enabled terms via `VocabularyRepository` and
//  resolves them with the pure `VocabularyBias.resolve`. Best-effort by design — any DB failure
//  (or an empty/disabled vocabulary) resolves to `nil`, which the provider treats as "attach no
//  context at all." A meeting must never fail to transcribe because vocabulary couldn't be read.
//
import Foundation

public struct VocabularySource: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// The current bias snapshot, or `nil` when there is nothing to bias with (no enabled terms,
    /// or the read failed). Callers should call this once per transcription session, not per
    /// buffer (see `SpeechTranscriberProvider`'s hot-path constraint).
    public func bias() async -> VocabularyBias? {
        guard let terms = try? await database.vocabulary.enabledTerms() else { return nil }
        return VocabularyBias.resolve(terms)
    }
}
