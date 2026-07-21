//
//  MarginaliaSegmentedControl.swift — button-row segmented switcher (plan §5 Tier 1.3,
//  docs/plans/arikit-component-library.md).
//
//  Reproduces `MeetingDetailView.sectionSwitcher` exactly: a custom button row (not stock
//  `Picker(.segmented)`, which would force solid-accent selection — the plan's §8 decision
//  preserves the live look). Selected segment renders `.secondary`; unselected renders
//  `.quiet` — never solid accent, preserving `accentSolidFillExclusive` (Signal Rule).
//
import SwiftUI

/// One segment in a `MarginaliaSegmentedControl`.
public struct MarginaliaSegment<Value: Hashable>: Sendable where Value: Sendable {
    public let value: Value
    public let title: String

    public init(value: Value, title: String) {
        self.value = value
        self.title = title
    }

    public var id: Value { value }
}

/// A button-row segmented switcher, matching `MeetingDetailView.sectionSwitcher`'s look.
public struct MarginaliaSegmentedControl<Value: Hashable & Sendable>: View {
    private let selection: Binding<Value>
    private let segments: [MarginaliaSegment<Value>]
    private let scheme: ColorScheme

    public init(selection: Binding<Value>, segments: [MarginaliaSegment<Value>], scheme: ColorScheme) {
        self.selection = selection
        self.segments = segments
        self.scheme = scheme
    }

    /// The declared role mapping for a segment's selection state (plan §5 Tier 1.3):
    /// selected -> `.secondary` (tonal, not solid accent), unselected -> `.quiet`.
    public static func role(selected: Bool) -> MarginaliaButtonRole {
        selected ? .secondary : .quiet
    }

    public var body: some View {
        HStack(spacing: MarginaliaSpacing.sm.value) {
            ForEach(segments, id: \.id) { segment in
                Button(segment.title) {
                    selection.wrappedValue = segment.value
                }
                .buttonStyle(
                    .marginalia(
                        Self.role(selected: segment.value == selection.wrappedValue),
                        .regular,
                        in: scheme
                    )
                )
            }
        }
    }
}
