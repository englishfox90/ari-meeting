//
//  RecallBounds.swift — the bounded-context caps (plan §2.2, ← shell.rs:98-103, :283).
//
//  These are the load-bearing "a broad query cannot turn into an unbounded local-model request"
//  limits (plan principle 6, bounded context). Ported verbatim from the frozen Rust constants;
//  the search-side caps (`ftsCandidates`, `rrfK`, …) land with Slice 4 and are intentionally
//  omitted here to keep Slice 1 scoped to the pure shell.
//
import Foundation

/// Numeric caps enforced by the recall safety shell.
public enum RecallBounds {
    /// Overall context budget handed to the local model (← `MAX_MEETING_RECALL_CONTEXT_CHARS`).
    public static let maxContextChars = 48_000
    /// Maximum number of retained per-meeting sources (← `MAX_MEETING_RECALL_SOURCES`).
    public static let maxSources = 64
    /// Per-source excerpt budget (← `MAX_MEETING_RECALL_SOURCE_CHARS`).
    public static let maxSourceChars = 8_000
    /// Distinct meetings retained by global recall (← `MAX_GLOBAL_RECALL_MEETINGS`).
    public static let maxGlobalMeetings = 8
    /// Trailing conversation turns retained as context (← `MAX_LOCAL_RECALL_HISTORY_TURNS`).
    public static let maxHistoryTurns = 8
    /// Character budget for the assembled history block (← `MAX_LOCAL_RECALL_HISTORY_CHARS`).
    public static let maxHistoryChars = 8_000
    /// Maximum accepted question length (← `shell.rs:283`, the `chars().count() > 1_000` gate).
    public static let maxQuestionChars = 1_000
}
