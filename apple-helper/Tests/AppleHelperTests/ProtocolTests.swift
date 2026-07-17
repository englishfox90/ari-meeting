//
//  ProtocolTests.swift
//  AppleHelperTests
//
//  Cross-language conformance guarantee: the Swift Codable layer MUST decode the
//  very same shared fixtures the Rust side uses
//  (`frontend/src-tauri/src/apple/fixtures/*.json`).
//
//  Fixture location: we reference the shared fixtures IN PLACE (no copying) by
//  resolving a path relative to this source file via `#filePath`, then walking
//  up to the repo root — the same 4-level walk as ari-notch's ProtocolTests.
//
//  Module import: `@testable import apple_helper` — the SwiftPM module name for
//  the `apple-helper` executable target (hyphen → underscore).
//

import XCTest
@testable import apple_helper

final class ProtocolTests: XCTestCase {

    // MARK: Fixture resolution

    /// Absolute URL of the shared fixtures directory, resolved from this file.
    ///   .../apple-helper/Tests/AppleHelperTests/ProtocolTests.swift
    ///   → up 4 to repo root → frontend/src-tauri/src/apple/fixtures
    private static var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AppleHelperTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // apple-helper/
            .deletingLastPathComponent() // <repo root>/
            .appendingPathComponent("frontend/src-tauri/src/apple/fixtures", isDirectory: true)
    }

    private func fixtureData(_ name: String) throws -> Data {
        let url = Self.fixturesDir.appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    private func decodeRequest(_ name: String) throws -> AppleRequest {
        try JSONDecoder().decode(AppleRequest.self, from: fixtureData(name))
    }

    private func decodeResponse(_ name: String) throws -> AppleResponse {
        try JSONDecoder().decode(AppleResponse.self, from: fixtureData(name))
    }

    // MARK: - Sanity: fixtures are present where we expect them

    func testFixturesDirectoryExists() {
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: Self.fixturesDir.path),
            "shared fixtures not found at \(Self.fixturesDir.path) — check the relative path from #filePath"
        )
    }

    // MARK: - Inbound fixtures decode to the expected case

    func testProbeDecodes() throws {
        XCTAssertEqual(try decodeRequest("probe.json"), .probe)
    }

    func testShutdownDecodes() throws {
        XCTAssertEqual(try decodeRequest("shutdown.json"), .shutdown)
    }

    func testEnsureAssetsDecodes() throws {
        XCTAssertEqual(
            try decodeRequest("ensure_assets.json"),
            .ensureAssets(which: "speech")
        )
    }

    func testSummarizeDecodes() throws {
        XCTAssertEqual(
            try decodeRequest("summarize.json"),
            .summarize(
                text: "Alice: Let's ship the release on Friday. Bob: I'll finish the API by Thursday. Alice: Great, I'll handle the changelog.",
                instruction: "Summarize the key decisions and action items from this meeting transcript.",
                maxTokens: 512
            )
        )
    }

    func testTranscribeDecodes() throws {
        XCTAssertEqual(
            try decodeRequest("transcribe.json"),
            .transcribe(pcmBase64: "AAAAAAAAAAAAAAAAAAAAAA==", locale: "en-US")
        )
    }

    func testEmbedBatchDecodes() throws {
        XCTAssertEqual(
            try decodeRequest("embed_batch.json"),
            .embedBatch(texts: [
                "Let's ship the release on Friday.",
                "I'll finish the API by Thursday.",
            ])
        )
    }

    // MARK: - Outbound fixtures decode to the expected case

    func testProbeResultDecodes() throws {
        XCTAssertEqual(
            try decodeResponse("probe_result.json"),
            .probeResult(
                speechAvailable: true,
                foundationAvailable: true,
                osOk: true,
                appleIntelligence: true,
                speechAssetsInstalled: false
            )
        )
    }

    func testErrorDecodes() throws {
        XCTAssertEqual(
            try decodeResponse("error.json"),
            .error(message: "Apple Intelligence is not enabled")
        )
    }

    func testSummarizeResultDecodes() throws {
        XCTAssertEqual(
            try decodeResponse("summarize_result.json"),
            .summarizeResult(
                text: "Decision: ship the release on Friday. Action items: Bob to finish the API by Thursday; Alice to handle the changelog."
            )
        )
    }

    func testTranscribeResultDecodes() throws {
        XCTAssertEqual(
            try decodeResponse("transcribe_result.json"),
            .transcribeResult(text: "Let's start with the roadmap.", confidence: 0.94)
        )
    }

    func testEmbedResultDecodes() throws {
        XCTAssertEqual(
            try decodeResponse("embed_result.json"),
            .embedResult(vectors: [[0.1, 0.2, 0.3], [-0.4, 0.5, -0.6]])
        )
    }

    func testProgressDecodes() throws {
        XCTAssertEqual(
            try decodeResponse("progress.json"),
            .progress(fraction: 0.42)
        )
    }

    func testEnsureResultDecodes() throws {
        XCTAssertEqual(
            try decodeResponse("ensure_result.json"),
            .ensureResult(installed: true)
        )
    }

    // MARK: - Forward-compatibility: unknown `type` → .unknown, never throws

    func testUnknownRequestTypeDecodesToUnknown() throws {
        let data = Data(#"{"type":"totally_new_request","foo":42}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(AppleRequest.self, from: data), .unknown)
    }

    func testUnknownResponseTypeDecodesToUnknown() throws {
        let data = Data(#"{"type":"totally_new_response","foo":42}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(AppleResponse.self, from: data), .unknown)
    }

    // MARK: - Round-trip: encode → decode is stable

    func testProbeResultRoundTrips() throws {
        let original = AppleResponse.probeResult(
            speechAvailable: true,
            foundationAvailable: false,
            osOk: true,
            appleIntelligence: true,
            speechAssetsInstalled: false
        )
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(AppleResponse.self, from: data), original)
    }

    // MARK: - Summarize round-trips: encode → semantic JSON equality with fixture

    /// Parse two JSON blobs into comparable Foundation objects (order-independent
    /// for objects). Returns true when they are semantically equal.
    private func jsonEqual(_ a: Data, _ b: Data) throws -> Bool {
        let objA = try JSONSerialization.jsonObject(with: a)
        let objB = try JSONSerialization.jsonObject(with: b)
        return NSDictionary(dictionary: objA as! [String: Any])
            .isEqual(to: objB as! [String: Any])
    }

    func testSummarizeRoundTripsToFixture() throws {
        let request = try decodeRequest("summarize.json")
        let encoded = try JSONEncoder().encode(request)
        XCTAssertTrue(
            try jsonEqual(encoded, fixtureData("summarize.json")),
            "re-encoded summarize request did not semantically match summarize.json"
        )
        // Encode → decode is also stable.
        XCTAssertEqual(try JSONDecoder().decode(AppleRequest.self, from: encoded), request)
    }

    func testEnsureAssetsRoundTripsToFixture() throws {
        let request = try decodeRequest("ensure_assets.json")
        let encoded = try JSONEncoder().encode(request)
        XCTAssertTrue(
            try jsonEqual(encoded, fixtureData("ensure_assets.json")),
            "re-encoded ensureAssets request did not semantically match ensure_assets.json"
        )
        XCTAssertEqual(try JSONDecoder().decode(AppleRequest.self, from: encoded), request)
    }

    func testEmbedBatchRoundTripsToFixture() throws {
        let request = try decodeRequest("embed_batch.json")
        let encoded = try JSONEncoder().encode(request)
        XCTAssertTrue(
            try jsonEqual(encoded, fixtureData("embed_batch.json")),
            "re-encoded embedBatch request did not semantically match embed_batch.json"
        )
        XCTAssertEqual(try JSONDecoder().decode(AppleRequest.self, from: encoded), request)
    }

    func testEmbedResultRoundTripsToFixture() throws {
        let response = try decodeResponse("embed_result.json")
        let encoded = try JSONEncoder().encode(response)
        XCTAssertTrue(
            try jsonEqual(encoded, fixtureData("embed_result.json")),
            "re-encoded embedResult did not semantically match embed_result.json"
        )
        XCTAssertEqual(try JSONDecoder().decode(AppleResponse.self, from: encoded), response)
    }

    func testProgressRoundTripsToFixture() throws {
        let response = try decodeResponse("progress.json")
        let encoded = try JSONEncoder().encode(response)
        XCTAssertTrue(
            try jsonEqual(encoded, fixtureData("progress.json")),
            "re-encoded progress did not semantically match progress.json"
        )
        XCTAssertEqual(try JSONDecoder().decode(AppleResponse.self, from: encoded), response)
    }

    func testEnsureResultRoundTripsToFixture() throws {
        let response = try decodeResponse("ensure_result.json")
        let encoded = try JSONEncoder().encode(response)
        XCTAssertTrue(
            try jsonEqual(encoded, fixtureData("ensure_result.json")),
            "re-encoded ensureResult did not semantically match ensure_result.json"
        )
        XCTAssertEqual(try JSONDecoder().decode(AppleResponse.self, from: encoded), response)
    }

    func testTranscribeRoundTripsToFixture() throws {
        let request = try decodeRequest("transcribe.json")
        let encoded = try JSONEncoder().encode(request)
        XCTAssertTrue(
            try jsonEqual(encoded, fixtureData("transcribe.json")),
            "re-encoded transcribe request did not semantically match transcribe.json"
        )
        XCTAssertEqual(try JSONDecoder().decode(AppleRequest.self, from: encoded), request)
    }

    func testTranscribeResultRoundTripsToFixture() throws {
        let response = try decodeResponse("transcribe_result.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let encoded = try encoder.encode(response)
        XCTAssertTrue(
            try jsonEqual(encoded, fixtureData("transcribe_result.json")),
            "re-encoded transcribeResult did not semantically match transcribe_result.json"
        )
        XCTAssertEqual(try JSONDecoder().decode(AppleResponse.self, from: encoded), response)
    }

    /// Confidence MUST encode as an explicit JSON null (not an omitted key) when
    /// nil, matching the Rust `Option<f32>` shape.
    func testTranscribeResultNilConfidenceEncodesAsNull() throws {
        let response = AppleResponse.transcribeResult(text: "hello world", confidence: nil)
        let data = try JSONEncoder().encode(response)
        let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as! [String: Any]
        XCTAssertTrue(obj.keys.contains("confidence"), "confidence key must be present even when nil")
        XCTAssertTrue(obj["confidence"] is NSNull, "confidence must encode as JSON null when nil")
        // And it round-trips back to a nil confidence.
        XCTAssertEqual(try JSONDecoder().decode(AppleResponse.self, from: data), response)
    }

    // MARK: - base64 → [Float] little-endian Float32 helper

    func testDecodePCMFloat32LEZeros() throws {
        // 16 zero bytes → 4 zero floats.
        let base64 = Data(repeating: 0, count: 16).base64EncodedString()
        let floats = try Transcribe.decodePCMFloat32LE(base64: base64)
        XCTAssertEqual(floats, [0, 0, 0, 0])
    }

    func testDecodePCMFloat32LEKnownValue() throws {
        // 1.0f little-endian is 00 00 80 3F.
        let bytes: [UInt8] = [0x00, 0x00, 0x80, 0x3F]
        let base64 = Data(bytes).base64EncodedString()
        let floats = try Transcribe.decodePCMFloat32LE(base64: base64)
        XCTAssertEqual(floats, [1.0])
    }

    func testDecodePCMFloat32LERejectsMisalignedLength() {
        // 5 bytes is not a multiple of 4 → honest throw, never silent truncation.
        let base64 = Data([1, 2, 3, 4, 5]).base64EncodedString()
        XCTAssertThrowsError(try Transcribe.decodePCMFloat32LE(base64: base64))
    }

    func testDecodePCMFloat32LERejectsInvalidBase64() {
        XCTAssertThrowsError(try Transcribe.decodePCMFloat32LE(base64: "not!valid!base64!"))
    }

    func testSummarizeResultRoundTripsToFixture() throws {
        let response = try decodeResponse("summarize_result.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let encoded = try encoder.encode(response)
        XCTAssertTrue(
            try jsonEqual(encoded, fixtureData("summarize_result.json")),
            "re-encoded summarizeResult did not semantically match summarize_result.json"
        )
        // Encode → decode is also stable.
        XCTAssertEqual(try JSONDecoder().decode(AppleResponse.self, from: encoded), response)
    }
}
