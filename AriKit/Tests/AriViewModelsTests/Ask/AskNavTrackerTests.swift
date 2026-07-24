//
//  AskNavTrackerTests.swift — view-declared nav presence for the Ask FAB scope pill (bug fix,
//  2026-07-24). Covers the tracker's own invariants: push/remove by token (not position), top
//  precedence, and out-of-order removal safety during a push/pop transition.
//
import Foundation
import Testing
@testable import AriKit
@testable import AriViewModels

@MainActor
@Suite("AskNavTracker — view-declared nav presence")
struct AskNavTrackerTests {
    @Test("empty tracker reports .none")
    func emptyReportsNone() {
        let tracker = AskNavTracker()
        #expect(tracker.top == .none)
    }

    @Test("a single push reports its key as top")
    func singlePushReportsItself() {
        let tracker = AskNavTracker()
        _ = tracker.push(.meeting("meeting-1"))
        #expect(tracker.top == .meeting("meeting-1"))
    }

    @Test("the most recently pushed entry wins, even with an older entry still registered")
    func mostRecentPushWins() {
        let tracker = AskNavTracker()
        _ = tracker.push(.series("series-1"))
        _ = tracker.push(.meeting("meeting-1"))
        #expect(tracker.top == .meeting("meeting-1"))
    }

    @Test("removing the top entry reveals the next-most-recent entry")
    func removingTopRevealsPrevious() {
        let tracker = AskNavTracker()
        let seriesToken = tracker.push(.series("series-1"))
        let meetingToken = tracker.push(.meeting("meeting-1"))
        tracker.remove(meetingToken)
        #expect(tracker.top == .series("series-1"))
        tracker.remove(seriesToken)
        #expect(tracker.top == .none)
    }

    @Test("removing an OUT-OF-ORDER token (not the top) only evicts that entry, never a still-live one")
    func outOfOrderRemovalOnlyEvictsItsOwnEntry() {
        // Mirrors a real push/pop transition race: a series detail view's cleanup can fire after
        // the meeting it drilled into has already pushed its own entry. Removing the series
        // token must never evict the meeting's entry underneath it.
        let tracker = AskNavTracker()
        let seriesToken = tracker.push(.series("series-1"))
        _ = tracker.push(.meeting("meeting-1"))
        tracker.remove(seriesToken)
        #expect(tracker.top == .meeting("meeting-1"))
    }

    @Test("removing a token that was never pushed (or already removed) is a harmless no-op")
    func removingUnknownTokenIsNoOp() {
        let tracker = AskNavTracker()
        let token = tracker.push(.meeting("meeting-1"))
        tracker.remove(token)
        // Removing again — a view's cleanup path calling `remove` unconditionally on teardown.
        tracker.remove(token)
        #expect(tracker.top == .none)
    }

    @Test("re-pushing after a task(id:)-style refresh (old token removed, new token pushed) tracks the new key")
    func replacingRegistrationTracksNewKey() {
        // Mirrors `MeetingDetailView`'s `.task(id: meetingId)`: the SAME view instance can be
        // reused for a different meetingId, so it removes its old token and pushes a fresh one
        // rather than relying on onAppear/onDisappear alone.
        let tracker = AskNavTracker()
        var token = tracker.push(.meeting("meeting-1"))
        #expect(tracker.top == .meeting("meeting-1"))

        tracker.remove(token)
        token = tracker.push(.meeting("meeting-2"))
        #expect(tracker.top == .meeting("meeting-2"))
    }
}
