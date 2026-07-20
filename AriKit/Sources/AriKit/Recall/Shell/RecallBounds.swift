//
//  RecallBounds.swift — the bounded-context caps (plan §2.2, ← shell.rs:98-103, :283).
//
//  These are the load-bearing "a broad query cannot turn into an unbounded local-model request"
//  limits (plan principle 6, bounded context). Ported verbatim from the frozen Rust constants.
//  The search-side caps (`ftsCandidates`, `rrfK`, …, ← search.rs:24-34) land here with Slice 4.
//
import Foundation

/// Numeric caps enforced by the recall safety shell.
public enum RecallBounds {
    /// Overall context budget handed to the local model (← `MAX_MEETING_RECALL_CONTEXT_CHARS`).
    public static let maxContextChars = 48000
    /// Maximum number of retained per-meeting sources (← `MAX_MEETING_RECALL_SOURCES`).
    public static let maxSources = 64
    /// Per-source excerpt budget (← `MAX_MEETING_RECALL_SOURCE_CHARS`).
    public static let maxSourceChars = 8000
    /// Distinct meetings retained by global recall (← `MAX_GLOBAL_RECALL_MEETINGS`).
    public static let maxGlobalMeetings = 8
    /// Trailing conversation turns retained as context (← `MAX_LOCAL_RECALL_HISTORY_TURNS`).
    public static let maxHistoryTurns = 8
    /// Character budget for the assembled history block (← `MAX_LOCAL_RECALL_HISTORY_CHARS`).
    public static let maxHistoryChars = 8000
    /// Maximum accepted question length (← `shell.rs:283`, the `chars().count() > 1_000` gate).
    public static let maxQuestionChars = 1000

    // MARK: - Search-side caps (Slice 4, ← search.rs:24-34)

    /// Lexical-arm (FTS5 BM25) candidate limit (← `FTS_CANDIDATES`).
    public static let ftsCandidates = 48
    /// Semantic-arm (vector cosine) candidate limit (← `VECTOR_CANDIDATES`).
    public static let vectorCandidates = 48
    /// Reciprocal-rank-fusion constant; larger flattens the contribution across ranks (← `RRF_K`).
    public static let rrfK: Double = 60.0
    /// Chunks handed downstream after fusion + recency weighting (← `MAX_HITS`).
    public static let maxHits = 60
    /// Recency half-life in days: a chunk's fused score halves every this many days of meeting
    /// age (← `RECENCY_HALF_LIFE_DAYS`).
    public static let recencyHalfLifeDays: Double = 45.0
    /// Never suppress an old meeting's relevance below this fraction (← `RECENCY_FLOOR`).
    public static let recencyFloor: Double = 0.35

    // MARK: - People-context caps (Slice 7, ← recall/context.rs:19-21)

    /// Distinct people surfaced per meeting in the people-context block (← `MAX_PEOPLE_PER_MEETING`).
    /// This port unifies on a single bound where the frozen Rust source used two different
    /// literals for related-but-separate lists (`MAX_PEOPLE_PER_MEETING = 8` for
    /// `meeting_people`/`attach_people`, but a hardcoded `.take(6)` for the meeting-scoped
    /// participant-fact bullets in `people_context_block`) — see `PeopleContext.swift`'s header.
    public static let maxPeoplePerMeeting = 8
    /// Truncation budget for a single inferred-fact line (← `MAX_FACT_CHARS`).
    public static let maxFactChars = 160
    /// Truncation budget for a calendar event's notes line (← `MAX_NOTE_CHARS`).
    public static let maxNoteChars = 300
}
