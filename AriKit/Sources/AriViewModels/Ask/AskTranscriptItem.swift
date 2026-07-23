//
//  AskTranscriptItem.swift — the render model for one row in the Ask console transcript
//  (docs/plans/ari-ask-ui.md Phase A §3).
//
//  Pure value type — no view/SwiftUI dependency. `[S<n>]` chips are resolved by the VIEW against
//  the owning `.assistant` row's own `sources` array (index `n-1`); this type carries the sources
//  so that resolution is possible, but does no tokenizing itself (that's `AskAnswerText`, an
//  app-target concern, plan §2/§10 test 14 — explicitly out of scope here).
//
import AriKit
import Foundation

/// One row in the Ask console transcript.
public enum AskTranscriptItemKind: Sendable, Equatable {
    /// A user-authored question, verbatim.
    case user(String)
    /// An assistant answer. `streaming == true` while deltas are still arriving — the accumulated
    /// text so far; `false` once the terminal `.done` has replaced it with the reconciled answer.
    /// `sources` is `[]` until `.done` lands (No-Fake-State — never attach sources early). `card`
    /// is likewise `nil` until `.done` lands: a deterministically-resolved entity card (plan §5.1,
    /// `ask-meetings-tools-and-cards.md`), `nil` unless Slice B's entity resolution found exactly
    /// one real, unambiguous row.
    case assistant(text: String, sources: [RecallSource], streaming: Bool, card: RecallCardPayload?)
    /// The honest "searching local meeting excerpts…" placeholder shown before the first delta.
    case thinking
    /// A surfaced `RecallEngineError.localizedDescription`, verbatim — never paraphrased or
    /// invented. `showSettings` flags whether an "Open Settings" affordance is warranted
    /// (`.modelNotConfigured`/`.loopbackViolation`).
    case error(String, showSettings: Bool)
}

/// One row in the Ask console transcript, identified for `List`/`ForEach` use in the (later)
/// SwiftUI layer.
public struct AskTranscriptItem: Sendable, Equatable, Identifiable {
    public let id: String
    public var kind: AskTranscriptItemKind

    public init(id: String = UUID().uuidString, kind: AskTranscriptItemKind) {
        self.id = id
        self.kind = kind
    }
}
