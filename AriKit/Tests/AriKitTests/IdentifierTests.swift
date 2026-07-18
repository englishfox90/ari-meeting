//
//  IdentifierTests.swift — plan §5 test 4.
//
//  `Identifier<Entity>` encodes/decodes as a bare JSON string (single-value container), is
//  `Hashable`, and — documented here, enforced by the type system — cannot cross entities.
//
import Foundation
import Testing
@testable import AriKit

@Suite struct IdentifierTests {
    private struct Box: Codable, Equatable {
        var id: MeetingID
    }

    @Test func encodesAsBareString() throws {
        let data = try Models.jsonEncoder.encode(Box(id: "meeting-42"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(object["id"] == "meeting-42")
    }

    @Test func decodesFromBareString() throws {
        let json = Data(#"{"id":"meeting-42"}"#.utf8)
        let box = try Models.jsonDecoder.decode(Box.self, from: json)
        #expect(box.id == MeetingID("meeting-42"))
        #expect(box.id.rawValue == "meeting-42")
    }

    @Test func isHashable() {
        let set: Set<MeetingID> = ["a", "b", "a"]
        #expect(set.count == 2)
    }

    @Test func distinctEntitiesAreDistinctTypes() {
        // A `MeetingID` and a `PersonID` share a `rawValue` type but are unrelated types.
        // The following would NOT compile, which is the whole point of the phantom tag:
        //
        //     let personId: PersonID = ModelSamples.meeting.id   // ❌ type error
        //
        // We assert the runtime shape instead: same raw string, independent typed identity.
        let meetingId = MeetingID("shared-raw")
        let personId = PersonID("shared-raw")
        #expect(meetingId.rawValue == personId.rawValue)
    }
}
