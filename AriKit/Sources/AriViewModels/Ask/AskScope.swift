//
//  AskScope.swift — the Ask console's scope value type + pure resolver
//  (docs/plans/ari-ask-ui.md Phase A §3 `AskScope`/`AskScopeResolver`).
//
//  Headless, app-agnostic: `AriViewModels` never imports the app-target `SidebarSection`
//  (plan §3). `AskScopeResolver` is fed a small nav descriptor (`AskNavContext`) built by the
//  app from its own navigation state, and returns precedence-ordered scopes — **meeting > series
//  > global** (← `RecallEngine`'s own precedence, `RecallEngine.swift:9`) — with no engine/DB
//  access of its own.
//
import AriKit
import Foundation

/// One askable scope. `.meeting`/`.series` carry a display `title` so the pill/empty-state copy
/// never has to re-derive it from elsewhere.
public enum AskScope: Sendable, Hashable {
    case global
    case series(SeriesID, title: String)
    case meeting(MeetingID, title: String)

    /// Display title for this scope (pill label / empty-state heading).
    public var title: String {
        switch self {
        case .global:
            "All meetings"
        case let .series(_, title):
            title
        case let .meeting(_, title):
            title
        }
    }

    /// The pair `RecallEngine.answerMeetingsLocallyStream(meetingId:seriesId:)` expects — exactly
    /// one non-nil, or both nil for global (mirrors the engine's own precedence, plan §3).
    public var engineScope: (meetingId: MeetingID?, seriesId: SeriesID?) {
        switch self {
        case .global:
            (nil, nil)
        case let .series(id, _):
            (nil, id)
        case let .meeting(id, _):
            (id, nil)
        }
    }

    /// The store's scope key pair — same shape as `AskConversationStore.list(meetingId:seriesId:)`
    /// / `create(meetingId:seriesId:title:)`. Identical to `engineScope` today; kept as a distinct
    /// name because the two seams (engine vs. store) are conceptually different call sites even
    /// though they resolve the same way.
    public var persistenceKey: (meetingId: MeetingID?, seriesId: SeriesID?) {
        engineScope
    }
}

/// A series reference carried by `AskNavContext.meeting` when the meeting belongs to a series.
/// A plain struct (not a labeled tuple) so `AskNavContext` can be `Hashable` — Swift tuples don't
/// conform to `Hashable` on their own.
public struct AskNavSeriesRef: Sendable, Hashable {
    public let id: SeriesID
    public let title: String

    public init(id: SeriesID, title: String) {
        self.id = id
        self.title = title
    }
}

/// A minimal, app-agnostic description of "where the user is right now" that
/// `AskScopeResolver` turns into available/default `AskScope`s. Built by the app from its own
/// navigation state (current sidebar section + top of the nav path) — `AriViewModels` never
/// imports the app-target navigation types themselves (plan §3).
public enum AskNavContext: Sendable, Hashable {
    /// Viewing a specific meeting; `series` is non-nil only when that meeting belongs to one.
    case meeting(MeetingID, title: String, series: AskNavSeriesRef?)
    /// Viewing a specific series (not drilled into one of its meetings).
    case series(SeriesID, title: String)
    /// Anywhere else — only the global scope is available.
    case none
}

/// Pure scope-availability resolver (plan §3). No DB/engine access — the app supplies whatever
/// series-membership fact it already knows via `AskNavContext.meeting(series:)`.
public struct AskScopeResolver: Sendable {
    public init() {}

    /// Precedence-ordered, narrowest-first: meeting (if present) > series (if present) > global
    /// (always last, always present). Pill visibility is `availableScopes(...).count > 1`.
    public func availableScopes(for context: AskNavContext) -> [AskScope] {
        switch context {
        case let .meeting(id, title, series):
            var scopes: [AskScope] = [.meeting(id, title: title)]
            if let series {
                scopes.append(.series(series.id, title: series.title))
            }
            scopes.append(.global)
            return scopes
        case let .series(id, title):
            return [.series(id, title: title), .global]
        case .none:
            return [.global]
        }
    }

    /// The narrowest available scope for `context` — the default selection when opening Ask from
    /// there.
    public func defaultScope(from context: AskNavContext) -> AskScope {
        availableScopes(for: context).first ?? .global
    }
}
