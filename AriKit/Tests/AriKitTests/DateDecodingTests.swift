//
//  DateDecodingTests.swift — plan §5 test 3.
//
//  RFC3339 strings (with `Z`, with and without fractional seconds) decode to the correct `Date`
//  via `Models.jsonDecoder`; numeric audio times stay `Double` seconds; a malformed date string
//  surfaces a `DecodingError` rather than a silent default (No-Fake-State).
//
import Foundation
import Testing
@testable import AriKit

@Suite struct DateDecodingTests {
    private struct DateBox: Codable, Equatable {
        var at: Date
    }

    private func decodeDate(_ raw: String) throws -> Date {
        let json = Data(#"{"at":"\#(raw)"}"#.utf8)
        return try Models.jsonDecoder.decode(DateBox.self, from: json).at
    }

    @Test func decodesZuluWithoutFractionalSeconds() throws {
        let date = try decodeDate("2023-11-14T22:13:20Z")
        #expect(date == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func decodesZuluWithFractionalSeconds() throws {
        let date = try decodeDate("2023-11-14T22:13:20.500Z")
        #expect(date == Date(timeIntervalSince1970: 1_700_000_000.5))
    }

    @Test func decodesNumericUtcOffset() throws {
        // The engine's chrono `to_rfc3339` emits a numeric offset rather than `Z`.
        let date = try decodeDate("2023-11-14T22:13:20+00:00")
        #expect(date == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func numericAudioTimesStayDouble() throws {
        // Audio offsets are numbers, not dates — they must not pass through the date strategy.
        let transcript = try FixtureLoader.decode(Transcript.self, from: "transcript")
        #expect(transcript.audioStartTime == 3.0)
        #expect(transcript.audioEndTime == 5.5)
        #expect(transcript.duration == 2.5)
    }

    @Test func malformedDateThrows() {
        #expect(throws: DecodingError.self) {
            _ = try decodeDate("not-a-date")
        }
    }
}
