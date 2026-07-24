//
//  SummaryBlockAttribute.swift — the structural block identity carried on each editor
//  paragraph by the rich-text summary editor (`docs/plans/rich-summary-editor.md` §2.1).
//
//  `SummaryBlockKind` is the single source of truth for "what kind of paragraph is this" —
//  the serializer (`SummaryRichText.serialize`) reads THIS attribute, never fonts, to decide
//  how a paragraph round-trips to markdown. Fonts are presentation, derived FROM the kind
//  (§2.4's formatting definition, a later step); they are never read back for structure.
//
import Foundation
import SwiftUI

/// The structural identity of one editor paragraph.
///
/// - `paragraph` — plain body text.
/// - `heading(level:)` — `#`×level in the closed 1...6 range (clamped by callers).
/// - `bulletItem` — an unordered list item.
/// - `numberedItem` — an ordered list item; the SOURCE numbering is dropped on parse — the
///   serializer always renumbers from 1 within each contiguous run.
public enum SummaryBlockKind: Codable, Hashable, Sendable {
    case paragraph
    case heading(level: Int)
    case bulletItem
    case numberedItem
}

/// A paragraph-scoped `AttributedString` attribute carrying `SummaryBlockKind`.
///
/// - `inheritedByAddedText = true` — typed text inside/continuing a paragraph keeps its
///   block kind, which is what makes "Enter in a bullet continues the list" work: the new
///   paragraph inherits `bulletItem` even before any explicit re-stamp.
/// - `runBoundaries = .paragraph` — the attribute is coalesced per paragraph and kept
///   consistent across edits, the mechanism that makes "attribute, not font" reliable as
///   the single source of structural truth.
public enum SummaryBlockAttribute: CodableAttributedStringKey {
    public typealias Value = SummaryBlockKind
    public static let name = "com.arivo.ari.summaryBlock"
    public static let inheritedByAddedText = true
    public static let runBoundaries: AttributedString.AttributeRunBoundaries? = .paragraph
}

/// The attribute scope used by the summary rich-text editor: the structural block kind
/// plus the standard SwiftUI attributes (font, foregroundColor, etc.) needed to present and
/// constrain it.
public extension AttributeScopes {
    struct AriAttributes: AttributeScope {
        public let summaryBlock: SummaryBlockAttribute
        public let swiftUI: SwiftUIAttributes
    }

    /// Ergonomic scope accessor: `attributedString.ari.summaryBlock`.
    var ari: AriAttributes.Type {
        AriAttributes.self
    }
}

public extension AttributeDynamicLookup {
    subscript<T: AttributedStringKey>(
        dynamicMember keyPath: KeyPath<AttributeScopes.AriAttributes, T>
    ) -> T {
        self[T.self]
    }
}
