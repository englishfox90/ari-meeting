///
///  ReindexCoordinator.swift — single-flight guard for a full recall backfill (plan §5 Slice 5,
///  ← indexer.rs:21,138-149's module-level `static REINDEX_RUNNING: AtomicBool`).
///
///  Rust guards overlapping full backfills (startup + first-query auto-trigger + an explicit
///  reindex command can all race) with a global `AtomicBool` + `try_begin_reindex`/`end_reindex`.
///  Swift's Swift-6-clean equivalent is an `actor` holding a plain `Bool` — this removes the
///  global mutable static entirely while preserving exact single-flight semantics: at most one
///  `reindexAll` runs at a time; a second concurrent caller is turned away immediately rather than
///  queued. Per-meeting `Indexer.indexMeeting` stays unguarded and cheap (mirrors `indexer.rs:32`),
///  so it is NOT gated by this actor.
///
public actor ReindexCoordinator {
    private var isRunning = false

    public init() {}

    /// Attempt to begin a backfill. Returns `true` (and marks the guard held) if none was
    /// already running; returns `false` immediately otherwise (← `try_begin_reindex`).
    public func tryBegin() -> Bool {
        if isRunning {
            return false
        }
        isRunning = true
        return true
    }

    /// Release the guard (← `end_reindex`). Safe to call even if `tryBegin` was never called by
    /// this caller — mirrors the Rust unconditional `store(false, ...)`.
    public func end() {
        isRunning = false
    }
}
