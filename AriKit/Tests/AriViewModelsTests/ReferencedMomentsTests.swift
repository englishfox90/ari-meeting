//
//  ReferencedMomentsTests.swift — citation-timecode extraction from summary markdown.
//
import Testing
@testable import AriViewModels

@Suite("ReferencedMoments")
struct ReferencedMomentsTests {

    @Test("parses [MM:SS] and @ref(MM:SS) markers, sorted and de-duplicated")
    func parsesBothForms() {
        let markdown = "Decided at [24:06]. Earlier @ref(3:59) and again [24:06]."
        #expect(ReferencedMoments.parse(from: markdown) == [239, 1446])
    }

    @Test("parses H:MM:SS markers")
    func parsesHours() {
        #expect(ReferencedMoments.parse(from: "long one @ref(1:02:03)") == [3723])
    }

    @Test("no markers yields an empty list (never fabricated)")
    func honestEmpty() {
        #expect(ReferencedMoments.parse(from: "A plain summary with no citations.").isEmpty)
    }

    @Test("ignores malformed timecodes")
    func ignoresMalformed() {
        // 9:99 has an out-of-range seconds field; a bare 3:14 has no bracket/ref wrapper.
        #expect(ReferencedMoments.parse(from: "bad [9:99] and bare 3:14").isEmpty)
    }
}
