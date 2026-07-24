//
//  ToolTurnStateTests.swift — plan §8.2 `ToolTurnStateTests` (`ask-meetings-agentic-tools.md`).
//
import Foundation
import Testing
@testable import AriKit

@Suite("ToolTurnState — per-ask agentic accumulation")
struct ToolTurnStateTests {
    private func makeSource(meetingId: String, matchContext: String = "some excerpt text") -> RecallSource {
        RecallSource(meetingId: meetingId, title: "Fixture meeting", matchContext: matchContext, timestamp: "00:05")
    }

    @Test("registerSource dedups by (meetingId, matchContext-prefix) and returns a stable 1-based index")
    func registerSourceDedupsAndReturnsStableIndex() async {
        let state = ToolTurnState()
        let first = await state.registerSource(makeSource(meetingId: "m1", matchContext: "the same excerpt"))
        let second = await state.registerSource(makeSource(meetingId: "m1", matchContext: "the same excerpt"))
        let third = await state.registerSource(makeSource(meetingId: "m2", matchContext: "a different excerpt"))

        #expect(first == 1)
        #expect(second == 1, "re-registering the same source returns the SAME stable index, not a new one")
        #expect(third == 2)
        #expect(await state.sources.count == 2)
    }

    @Test("registerSource hard-caps at RecallBounds.maxAgenticSources, returning nil beyond the cap")
    func registerSourceHardCaps() async {
        let state = ToolTurnState()
        var lastIndex: Int?
        for i in 0 ..< (RecallBounds.maxAgenticSources + 5) {
            lastIndex = await state.registerSource(makeSource(meetingId: "m\(i)", matchContext: "excerpt \(i)"))
        }
        #expect(await state.sources.count == RecallBounds.maxAgenticSources)
        #expect(lastIndex == nil, "the source past the cap is never registered")
    }

    @Test("attach dedups by card value equality")
    func attachDedupsByEquality() async {
        let state = ToolTurnState()
        let payload = PersonCardPayload(personId: "p1", displayName: "Sarah Ammon", meetingCount: 2)
        await state.attach(.person(payload))
        await state.attach(.person(payload))
        #expect(await state.cards.count == 1)
    }

    @Test("attach keeps distinct cards, e.g. a person AND a calendar event")
    func attachKeepsDistinctCards() async {
        let state = ToolTurnState()
        await state.attach(.person(PersonCardPayload(personId: "p1", displayName: "Sarah Ammon", meetingCount: 2)))
        await state.attach(.calendarEvent(CalendarEventCardPayload(
            eventId: "e1", title: "Sync", startTime: "2026-07-23T18:00:00Z", attendeeNames: ["Sarah Ammon"],
            isLinkedToRecordedMeeting: false
        )))
        #expect(await state.cards.count == 2)
    }

    @Test("surface/isSurfaced tracks meeting ids a tool result exposed this turn")
    func surfaceTracksMeetingIds() async {
        let state = ToolTurnState()
        let id = MeetingID("m1")
        #expect(await state.isSurfaced(id) == false)
        await state.surface(id)
        #expect(await state.isSurfaced(id) == true)
        #expect(await state.isSurfaced(MeetingID("m2")) == false)
    }

    @Test("beginIteration allows exactly maxAgenticIterations calls, then always returns false")
    func beginIterationEnforcesTheBudget() async {
        let state = ToolTurnState()
        var allowed = 0
        for _ in 0 ..< (RecallBounds.maxAgenticIterations + 3) {
            if await state.beginIteration() {
                allowed += 1
            }
        }
        #expect(allowed == RecallBounds.maxAgenticIterations)
        // The budget never resets mid-turn — every subsequent call after exhaustion still fails.
        #expect(await state.beginIteration() == false)
        #expect(await state.iterations == RecallBounds.maxAgenticIterations)
    }
}
