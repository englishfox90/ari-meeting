//
//  RecallCardPayloadCodableTests.swift — plan §8 Slice C `RecallCardPayloadCodableTests`
//  (`ask-meetings-tools-and-cards.md` §5.1) — wire-contract-only tests for Slice B's addition of
//  `card` to `RecallResponse`.
//
import Foundation
import Testing
@testable import AriKit

@Suite("RecallCardPayload — wire contract (Codable round-trip + back-compat decoding)")
struct RecallCardPayloadCodableTests {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    @Test("MeetingCardPayload round-trips through the RecallCardPayload.meeting case")
    func meetingCardRoundTrips() throws {
        let payload = RecallCardPayload.meeting(
            MeetingCardPayload(
                meetingId: "m1",
                title: "Q3 review",
                meetingDate: "2026-07-18T00:00:00Z",
                hasSummary: true
            )
        )
        let data = try encoder.encode(payload)
        let decoded = try decoder.decode(RecallCardPayload.self, from: data)
        #expect(decoded == payload)
    }

    @Test("PersonCardPayload round-trips through the RecallCardPayload.person case")
    func personCardRoundTrips() throws {
        let payload = RecallCardPayload.person(
            PersonCardPayload(
                personId: "p1",
                displayName: "Sarah Ammon",
                role: "PM",
                organization: "Arivo",
                lastMeetingDate: "2026-07-10T00:00:00Z",
                meetingCount: 3
            )
        )
        let data = try encoder.encode(payload)
        let decoded = try decoder.decode(RecallCardPayload.self, from: data)
        #expect(decoded == payload)
    }

    @Test("SeriesCardPayload round-trips through the RecallCardPayload.series case")
    func seriesCardRoundTrips() throws {
        let payload = RecallCardPayload.series(
            SeriesCardPayload(
                seriesId: "s1",
                title: "Design team sync",
                meetingCount: 5,
                lastMeetingDate: "2026-07-01T00:00:00Z"
            )
        )
        let data = try encoder.encode(payload)
        let decoded = try decoder.decode(RecallCardPayload.self, from: data)
        #expect(decoded == payload)
    }

    @Test("CalendarEventCardPayload round-trips through the RecallCardPayload.calendarEvent case")
    func calendarEventCardRoundTrips() throws {
        let payload = RecallCardPayload.calendarEvent(
            CalendarEventCardPayload(
                eventId: "e1",
                title: "James sync",
                startTime: "2026-07-23T18:00:00Z",
                attendeeNames: ["James Nance"],
                isLinkedToRecordedMeeting: false
            )
        )
        let data = try encoder.encode(payload)
        let decoded = try decoder.decode(RecallCardPayload.self, from: data)
        #expect(decoded == payload)
    }

    @Test("A RecallResponse with a card round-trips through Codable")
    func recallResponseWithCardRoundTrips() throws {
        let response = RecallResponse(
            answer: "Sarah Ammon — 3 meetings.",
            sources: [],
            card: .person(PersonCardPayload(personId: "p1", displayName: "Sarah Ammon", meetingCount: 3))
        )
        let data = try encoder.encode(response)
        let decoded = try decoder.decode(RecallResponse.self, from: data)
        #expect(decoded == response)
    }

    @Test("A RecallResponse JSON blob with no card key decodes card == nil (back-compat)")
    func missingCardKeyDecodesAsNil() throws {
        let json = """
        { "answer": "Fine.", "sources": [] }
        """
        let decoded = try decoder.decode(RecallResponse.self, from: Data(json.utf8))
        #expect(decoded.card == nil)
        #expect(decoded.answer == "Fine.")
    }

    @Test("A RecallResponse with an explicit null card key decodes card == nil")
    func explicitNullCardDecodesAsNil() throws {
        let json = """
        { "answer": "Fine.", "sources": [], "card": null }
        """
        let decoded = try decoder.decode(RecallResponse.self, from: Data(json.utf8))
        #expect(decoded.card == nil)
    }

    // MARK: - §5.4 plural `cards` (ask-meetings-agentic-tools.md)

    @Test("cards: passing plural cards sets card to cards.first")
    func pluralCardsSetsSingularCardToFirst() {
        let person = RecallCardPayload.person(PersonCardPayload(
            personId: "p1",
            displayName: "Sarah Ammon",
            meetingCount: 3
        ))
        let event = RecallCardPayload.calendarEvent(
            CalendarEventCardPayload(
                eventId: "e1",
                title: "Sync",
                startTime: "2026-07-23T18:00:00Z",
                attendeeNames: [],
                isLinkedToRecordedMeeting: false
            )
        )
        let response = RecallResponse(answer: "Fine.", sources: [], cards: [person, event])
        #expect(response.cards == [person, event])
        #expect(response.card == person)
    }

    @Test("cards: a RecallResponse with plural cards round-trips through Codable")
    func pluralCardsRoundTrips() throws {
        let person = RecallCardPayload.person(PersonCardPayload(
            personId: "p1",
            displayName: "Sarah Ammon",
            meetingCount: 3
        ))
        let event = RecallCardPayload.calendarEvent(
            CalendarEventCardPayload(
                eventId: "e1",
                title: "Sync",
                startTime: "2026-07-23T18:00:00Z",
                attendeeNames: [],
                isLinkedToRecordedMeeting: false
            )
        )
        let response = RecallResponse(answer: "Fine.", sources: [], cards: [person, event])
        let data = try encoder.encode(response)
        let decoded = try decoder.decode(RecallResponse.self, from: data)
        #expect(decoded == response)
        #expect(decoded.card == person)
    }

    @Test("cards: a JSON blob with no cards key but a legacy card key derives cards == [card] (back-compat)")
    func missingCardsKeyDerivesFromLegacyCard() throws {
        // Built via the encoder (not hand-authored JSON) so this test does not depend on the exact
        // associated-value coding-key shape Swift's synthesized `Codable` picks for an unlabeled
        // enum payload — only on the FIELD ("card" present, "cards" absent) that matters here.
        let card = RecallCardPayload.person(PersonCardPayload(
            personId: "p1",
            displayName: "Sarah Ammon",
            meetingCount: 3
        ))
        var object = try #require(JSONSerialization.jsonObject(
            with: encoder.encode(RecallResponse(answer: "Fine.", sources: [], card: card))
        ) as? [String: Any])
        object.removeValue(forKey: "cards")
        let json = try JSONSerialization.data(withJSONObject: object)

        let decoded = try decoder.decode(RecallResponse.self, from: json)
        #expect(decoded.cards.count == 1)
        #expect(decoded.card == decoded.cards.first)
        #expect(decoded.card == card)
    }

    @Test("cards: a JSON blob with neither cards nor card decodes cards == [] (never fabricated)")
    func missingBothDecodesEmptyCards() throws {
        let json = """
        { "answer": "Fine.", "sources": [] }
        """
        let decoded = try decoder.decode(RecallResponse.self, from: Data(json.utf8))
        #expect(decoded.cards.isEmpty)
        #expect(decoded.card == nil)
    }
}
