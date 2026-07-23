//
//  AskScopeResolverTests.swift — plan §10 test 7 (docs/plans/ari-ask-ui.md): scope derivation
//  precedence, meeting > series > global, series offered only when present.
//
import Foundation
import Testing
@testable import AriKit
@testable import AriViewModels

@Suite("AskScopeResolver — scope derivation precedence")
struct AskScopeResolverTests {
    private let resolver = AskScopeResolver()

    @Test("meeting with a series: available = [meeting, series, global], default = meeting")
    func meetingWithSeriesOffersAllThree() {
        let context = AskNavContext.meeting(
            "meeting-1", title: "Weekly sync",
            series: AskNavSeriesRef(id: "series-1", title: "Weekly sync series")
        )

        let available = resolver.availableScopes(for: context)
        #expect(available == [
            .meeting("meeting-1", title: "Weekly sync"),
            .series("series-1", title: "Weekly sync series"),
            .global
        ])
        #expect(resolver.defaultScope(from: context) == .meeting("meeting-1", title: "Weekly sync"))
    }

    @Test("meeting with NO series: available = [meeting, global], no series scope offered")
    func meetingWithoutSeriesOffersNoSeriesScope() {
        let context = AskNavContext.meeting("meeting-2", title: "1:1", series: nil)

        let available = resolver.availableScopes(for: context)
        #expect(available == [.meeting("meeting-2", title: "1:1"), .global])
        #expect(!available.contains { if case .series = $0 { true } else { false } })
        #expect(resolver.defaultScope(from: context) == .meeting("meeting-2", title: "1:1"))
    }

    @Test("series context: available = [series, global], default = series")
    func seriesContextOffersSeriesAndGlobal() {
        let context = AskNavContext.series("series-2", title: "Standup")

        let available = resolver.availableScopes(for: context)
        #expect(available == [.series("series-2", title: "Standup"), .global])
        #expect(resolver.defaultScope(from: context) == .series("series-2", title: "Standup"))
    }

    @Test("no context: available = [global] only, default = global")
    func noContextOffersGlobalOnly() {
        let available = resolver.availableScopes(for: .none)
        #expect(available == [.global])
        #expect(resolver.defaultScope(from: .none) == .global)
    }

    @Test("pill visibility is available.count > 1")
    func pillVisibilityRule() {
        #expect(resolver.availableScopes(for: .none).count == 1)
        #expect(resolver.availableScopes(for: .series("s", title: "S")).count > 1)
    }
}
