//
//  NativeEventStableIDTests.swift — regression for the recurring-occurrence id collapse.
//
//  EventKit hands back every occurrence of a recurring series as a separate event sharing one
//  `eventIdentifier`. Before `NativeEvent.stableID`, keying the DB row on that alone collapsed the
//  whole series to a single row (only the last occurrence written survived), so occurrences —
//  including "today's" — silently vanished from the calendar view. These tests pin the fix.
//
import Foundation
import Testing
@testable import AriKit

@Suite("NativeEvent.stableID")
struct NativeEventStableIDTests {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("non-recurring event keeps its bare identifier")
    func nonRecurringUnchanged() {
        let id = NativeEvent.stableID(
            eventIdentifier: "evt-1",
            hasRecurrenceRules: false,
            isDetached: false,
            occurrenceDate: base
        )
        #expect(id == "evt-1")
    }

    @Test("recurring occurrences of one series get distinct ids")
    func recurringOccurrencesAreDistinct() {
        let day1 = NativeEvent.stableID(
            eventIdentifier: "series-A",
            hasRecurrenceRules: true,
            isDetached: false,
            occurrenceDate: base
        )
        let day2 = NativeEvent.stableID(
            eventIdentifier: "series-A",
            hasRecurrenceRules: true,
            isDetached: false,
            occurrenceDate: base.addingTimeInterval(24 * 60 * 60)
        )
        #expect(day1 != day2)
        #expect(day1.hasPrefix("series-A|"))
        #expect(day2.hasPrefix("series-A|"))
    }

    @Test("detached exception keeps its own (already-distinct) identifier")
    func detachedUnchanged() {
        // A detached instance is assigned its own eventIdentifier by EventKit, so it must not be
        // suffixed — that keeps its id stable across syncs.
        let id = NativeEvent.stableID(
            eventIdentifier: "detached-1",
            hasRecurrenceRules: true,
            isDetached: true,
            occurrenceDate: base
        )
        #expect(id == "detached-1")
    }

    @Test("recurring event with no occurrence date falls back to the bare identifier")
    func recurringWithoutOccurrenceDate() {
        let id = NativeEvent.stableID(
            eventIdentifier: "series-B",
            hasRecurrenceRules: true,
            isDetached: false,
            occurrenceDate: nil
        )
        #expect(id == "series-B")
    }

    @Test("same inputs always produce the same id (deterministic across syncs)")
    func deterministic() {
        let first = NativeEvent.stableID(
            eventIdentifier: "series-C",
            hasRecurrenceRules: true,
            isDetached: false,
            occurrenceDate: base
        )
        let second = NativeEvent.stableID(
            eventIdentifier: "series-C",
            hasRecurrenceRules: true,
            isDetached: false,
            occurrenceDate: base
        )
        #expect(first == second)
    }
}
