//
//  AskTranscriptItem.swift — the render model for one row in the Ask console transcript
//  (docs/plans/ari-ask-ui.md Phase A §3; extended by docs/plans/ask-meetings-agentic-tools.md
//  §5.3/§5.4 for the tool-first agentic path).
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
    /// `sources` is `[]` until `.done` lands (No-Fake-State — never attach sources early). `cards`
    /// is likewise `[]` until `.done` lands: the full set of deterministically-resolved entity
    /// cards a tool-first ask may surface (plan §5.4, `ask-meetings-agentic-tools.md`) — empty
    /// unless the ask's tool loop resolved at least one real, unambiguous row.
    case assistant(text: String, sources: [RecallSource], streaming: Bool, cards: [RecallCardPayload])
    /// Live model reasoning (Qwen3 `<think>` content, already stripped of tags), ephemeral —
    /// NEVER persisted (plan §5.3 decided). `text == ""` is today's honest "thinking…" placeholder
    /// shown before the first reasoning/answer delta arrives; `folded == true` once the first
    /// answer `.delta` has landed, collapsing the row to a one-line disclosure the user can
    /// re-expand — the row itself is only ever removed at the terminal `.done` (plan §5.3).
    case thinking(text: String, folded: Bool)
    /// One tool's dispatch lifecycle, ephemeral — NEVER persisted (plan §5.3/§6 No-Fake-State:
    /// shown only for a tool that actually ran). `toolName` is the raw tool identifier (matched
    /// against `ToolActivity.toolName` to update this exact row on `.finished`); `label` is the
    /// Swift-computed, human-facing string (never model text). `running == true` between
    /// `.started` and `.finished`; `ok` is only meaningful once `running == false`.
    case toolActivity(toolName: String, label: String, running: Bool, ok: Bool)
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
