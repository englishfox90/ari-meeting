//
//  MarginaliaGlassTabs.swift — the capsule Liquid Glass tab switcher (HIG "tab views",
//  owner direction 2026-07-21).
//
//  The HIG's glass tab appearance — a capsule glass container with a sliding selected
//  pill — has no stock macOS equivalent (the stock segmented `Picker` renders the
//  rectangular control), so this is sanctioned custom chrome built from the glass
//  primitives (liquid-glass-adoption.md v2: navigation layer, neutral `.regular` glass
//  container). Selection styling follows the brand's selection convention: selection-wash
//  pill + accent label (accent-on-selection is a sanctioned Signal use).
//
//  Motion: the pill slides between segments with the `fast` Marginalia token via
//  `matchedGeometryEffect`; under Reduce Motion the move is instant (no animation) —
//  state-driven only, per BRAND.md §8.
//
import SwiftUI

/// A capsule glass tab switcher: `Capsule` glass container, sliding selection pill.
public struct MarginaliaGlassTabs<Tab: Hashable>: View {
    private let tabs: [(tag: Tab, title: String)]
    private let selection: Binding<Tab>
    private let scheme: ColorScheme

    @Namespace private var pillNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(tabs: [(tag: Tab, title: String)], selection: Binding<Tab>, scheme: ColorScheme) {
        self.tabs = tabs
        self.selection = selection
        self.scheme = scheme
    }

    public var body: some View {
        HStack(spacing: MarginaliaSpacing.xs.value) {
            ForEach(tabs, id: \.tag) { tab in
                segment(tab)
            }
        }
        .padding(MarginaliaSpacing.xs.value)
        .glassEffect(.regular, in: Capsule())
    }

    @ViewBuilder
    private func segment(_ tab: (tag: Tab, title: String)) -> some View {
        let isSelected = tab.tag == selection.wrappedValue
        Button {
            withAnimation(MarginaliaMotion.animation(.fast, reduceMotion: reduceMotion)) {
                selection.wrappedValue = tab.tag
            }
        } label: {
            Text(tab.title)
                .marginaliaTextStyle(.body, in: scheme, ink: isSelected ? .accent : .inkBody)
                .padding(.horizontal, MarginaliaSpacing.md.value)
                .padding(.vertical, MarginaliaSpacing.xs.value)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Color.marginalia(.selectionWash, in: scheme))
                            .matchedGeometryEffect(id: "selection-pill", in: pillNamespace)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
