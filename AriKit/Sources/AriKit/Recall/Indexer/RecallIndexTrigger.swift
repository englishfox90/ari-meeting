//
//  RecallIndexTrigger.swift — the single, gated place indexing fires from
//  (docs/plans/ask-meetings-tools-and-cards.md §3.1).
//
//  Fixes Bug A ("indexing never runs automatically"): a meeting is indexed exactly once per
//  lifecycle, triggered by its SUMMARY being saved — never by a transcript save, retranscription,
//  or import. Gating on "summary exists" collapses what would otherwise be up to three separate
//  index runs into one, and matches "index once, when the content is actually settled."
//
//  `Sendable` value type over an injected `Indexer`/`RecallIndexRepository`, mirroring the
//  existing `Indexer`/`HybridSearch` "value type over injected handles" convention — safe to call
//  from any isolation domain. Both operations are fire-and-forget: they spawn a detached `Task`
//  and never block their caller, since the caller's own write (the summary save, or the meeting
//  delete) has already committed before this is invoked.
//
import Foundation

public struct RecallIndexTrigger: Sendable {
    private let indexer: Indexer
    private let recallIndex: RecallIndexRepository

    public init(indexer: Indexer, recallIndex: RecallIndexRepository) {
        self.indexer = indexer
        self.recallIndex = recallIndex
    }

    /// Fire-and-forget: spawns a detached `Task` calling `indexer.indexMeeting(meetingId)`. Never
    /// throws, never blocks the caller. `Indexer.indexMeeting` never throws itself (it logs and
    /// swallows), and the shared `ReindexCoordinator`/idempotent content-hash inside `Indexer`
    /// keeps a concurrent re-trigger (e.g. re-generating a summary) from piling up wasted work.
    public func indexAfterSummary(_ meetingId: MeetingID) {
        Task.detached(priority: .utility) { [indexer] in
            await indexer.indexMeeting(meetingId)
        }
    }

    /// Fire-and-forget purge: removes any indexed chunks for a deleted meeting — the human
    /// decision (§3.1.1) that a delete should actively purge the index, not just rely on
    /// `HybridSearch`'s query-time soft-delete filter. Best-effort (`try?`): a purge failure must
    /// never surface to or block the caller, since the meeting's own tombstone write has already
    /// succeeded.
    public func purgeOnDelete(_ meetingId: MeetingID) {
        Task.detached(priority: .utility) { [recallIndex] in
            try? await recallIndex.deleteMeeting(meetingId)
        }
    }
}
