//
//  AskNavTracker.swift — view-declared "where am I" presence for the Ask FAB's scope pill
//  (bug fix, 2026-07-24: the parallel `askNavStack` `RootSplitView` used to maintain only ever
//  got appended at explicit `path.append` call sites, so any internal `NavigationLink(value:)`
//  push — the Saved-meetings list, Home's recent cards, People, an existing series row — bypassed
//  it entirely and left the scope pill stuck on `.none`).
//
//  The fix is structural: instead of a stack maintained by every PUSH call site, the destination
//  VIEWS THEMSELVES register their own presence while they're on screen. Any navigation mechanism
//  that ends up showing `MeetingDetailView`/`SeriesDetailView` — `path.append`, an internal
//  `NavigationLink(value:)`, a notification-driven `pendingNavigation`, an import auto-open —
//  is therefore immune by construction; there is no call site left to forget.
//
import AriKit
import Foundation
import Observation

/// The Ask FAB's nav-position key — "the meeting/series currently in view", or `.none` when
/// neither applies (a list page, a person page, settings, …). `AskOverlayHost` resolves this into
/// the richer `AskNavContext` (real titles + series membership) itself.
public enum AskNavKey: Hashable, Sendable {
    case none
    case meeting(MeetingID)
    case series(SeriesID)
}

/// An ordered stack of "a view is currently showing this nav key" registrations. Destination
/// views push a token when they appear (or when their identifying id changes while reused — see
/// `MeetingDetailView`'s `.task(id:)`-driven push, since it documents being reused across
/// meetings without a fresh `.onAppear`) and remove that SAME token when they go away.
///
/// **Invariant: remove by token, never by popping the last entry.** Multiple views can be
/// registered at once (e.g. mid-push-transition, or a stacked series → meeting drill-down), and
/// SwiftUI does not guarantee `onAppear`/`onDisappear` (or successive `.task(id:)` fires) arrive
/// in a strict push/pop order during a transition. Removing by the exact token a view was handed
/// back means an out-of-order disappear can never evict a DIFFERENT, still-live view's entry —
/// only its own. `top` always reflects the most recently pushed entry that hasn't been removed.
@MainActor
@Observable
public final class AskNavTracker {
    /// An opaque handle returned by `push(_:)`. Views hold onto this and pass it back to
    /// `remove(_:)` — never index by position.
    public struct Token: Hashable, Sendable {
        private let id: UUID

        fileprivate init() {
            id = UUID()
        }
    }

    private var entries: [(token: Token, key: AskNavKey)] = []

    public init() {}

    /// Registers `key` as newly visible; returns a token the caller must hold and pass to
    /// `remove(_:)` when it stops being visible (or is replaced by a fresh registration for the
    /// same underlying view).
    @discardableResult
    public func push(_ key: AskNavKey) -> Token {
        let token = Token()
        entries.append((token, key))
        return token
    }

    /// Removes exactly the entry matching `token`, wherever it sits in the stack. A no-op if the
    /// token isn't present (already removed, or never pushed) — callers can call this
    /// unconditionally on cleanup.
    public func remove(_ token: Token) {
        entries.removeAll { $0.token == token }
    }

    /// The most recently pushed still-live key, or `.none` when nothing is registered.
    public var top: AskNavKey {
        entries.last?.key ?? .none
    }
}
