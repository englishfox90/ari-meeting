//
//  UnknownEnumToleranceTests.swift — plan §5 test 1.
//
//  For each forward-tolerant enum: a known raw decodes to its known case; an unseen raw decodes
//  to `.unknown("futureValue")` (never throws); and re-encoding the unknown round-trips the raw
//  losslessly.
//
import Foundation
import Testing
@testable import AriKit

@Suite struct UnknownEnumToleranceTests {
    /// Wraps an enum in a keyed object so we exercise the exact single-value coding path used in
    /// real models (and avoid relying on top-level JSON fragment support).
    private struct Box<T: Codable & Equatable>: Codable, Equatable {
        var value: T
    }

    private func decode<T: Codable & Equatable>(_: T.Type, raw: String) throws -> T {
        let json = Data(#"{"value":"\#(raw)"}"#.utf8)
        return try Models.jsonDecoder.decode(Box<T>.self, from: json).value
    }

    private func encodedRaw<T: Codable & Equatable>(_ value: T) throws -> String {
        let data = try Models.jsonEncoder.encode(Box(value: value))
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: String]
        )
        return try #require(object["value"])
    }

    /// Exercises the tolerance contract generically for one enum.
    private func check<T: UnknownTolerantEnum & Codable & Equatable>(
        _ type: T.Type,
        known: String,
        knownCase: T
    ) throws {
        // Known value → known case.
        #expect(try decode(type, raw: known) == knownCase)

        // Unseen value → .unknown, never a throw.
        let future = "futureValue"
        let decoded = try decode(type, raw: future)
        #expect(decoded == T.unknownCase(future))
        #expect(decoded.rawValue == future)

        // Unknown re-encodes to exactly the preserved raw.
        #expect(try encodedRaw(decoded) == future)

        // Known value re-encodes to its canonical raw.
        #expect(try encodedRaw(knownCase) == known)
    }

    @Test func enrollmentStateTolerance() throws {
        try check(EnrollmentState.self, known: "confirmed", knownCase: .confirmed)
    }

    @Test func factKindTolerance() throws {
        // Includes the snake_case canonical raw for `roleSignal`.
        try check(FactKind.self, known: "role_signal", knownCase: .roleSignal)
    }

    @Test func factStatusTolerance() throws {
        try check(FactStatus.self, known: "superseded", knownCase: .superseded)
    }

    @Test func factOriginTolerance() throws {
        try check(FactOrigin.self, known: "self_reported", knownCase: .selfReported)
    }

    @Test func factSourceRelationTolerance() throws {
        try check(FactSourceRelation.self, known: "reaffirmed", knownCase: .reaffirmed)
    }

    @Test func calendarLinkSourceTolerance() throws {
        try check(CalendarLinkSource.self, known: "calendar", knownCase: .calendar)
    }

    @Test func segmentSourceTolerance() throws {
        try check(SegmentSource.self, known: "import", knownCase: .import)
    }
}
