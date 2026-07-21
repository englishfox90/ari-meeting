//
//  StripCodeFencesTests.swift — port of the Rust `strip_code_fences` unit test (Phase 3.4
//  Track H §2.6, ← `ari-engine/src/persons/extraction.rs::strip_code_fences`, `:274`).
//
import Foundation
import Testing
@testable import AriKit

@Suite("PersonExtraction.stripCodeFences")
struct StripCodeFencesTests {
    @Test("Plain JSON with no fences round-trips unchanged")
    func plainJSONUnchanged() {
        let raw = "[{\"a\":1}]"
        #expect(PersonExtraction.stripCodeFences(raw) == raw)
    }

    @Test("A ```json fenced block is unwrapped")
    func jsonFencedBlockIsUnwrapped() {
        let raw = "```json\n[{\"a\":1}]\n```"
        #expect(PersonExtraction.stripCodeFences(raw) == "[{\"a\":1}]")
    }

    @Test("A bare ``` fenced block (no language tag) is unwrapped")
    func bareFencedBlockIsUnwrapped() {
        let raw = "```\n[{\"a\":1}]\n```"
        #expect(PersonExtraction.stripCodeFences(raw) == "[{\"a\":1}]")
    }

    @Test("A fenced block missing its closing fence still strips the opening one")
    func missingClosingFenceStillStripsOpening() {
        let raw = "```json\n[{\"a\":1}]"
        #expect(PersonExtraction.stripCodeFences(raw) == "[{\"a\":1}]")
    }

    @Test("Leading/trailing whitespace around the whole response is trimmed")
    func surroundingWhitespaceIsTrimmed() {
        let raw = "  \n[{\"a\":1}]\n  "
        #expect(PersonExtraction.stripCodeFences(raw) == "[{\"a\":1}]")
    }
}
