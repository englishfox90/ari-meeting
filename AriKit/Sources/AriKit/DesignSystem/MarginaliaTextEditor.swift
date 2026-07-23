//
//  MarginaliaTextEditor.swift — themed multi-line text input (docs/plans/
//  people-view-parity.md §5 Slice 4, decision 4).
//
//  A small multi-line sibling of `MarginaliaTextField`: same `MarginaliaFieldSpec.standard`
//  surface fill / hairline-to-accent-on-focus stroke / control radius, but a fixed-minimum-
//  height `TextEditor` rather than a single-line `TextField`, and a placeholder overlay since
//  `TextEditor` has no native `prompt`/placeholder support.
//
import SwiftUI

/// A themed multi-line text field (Notes / "Add a fact manually", etc.).
public struct MarginaliaTextEditor: View {
    private let text: Binding<String>
    private let prompt: String
    private let scheme: ColorScheme
    private let minHeight: CGFloat
    private let maxHeight: CGFloat?
    @FocusState private var isFocused: Bool

    public init(
        text: Binding<String>,
        prompt: String,
        scheme: ColorScheme,
        minHeight: CGFloat = 64,
        maxHeight: CGFloat? = nil
    ) {
        self.text = text
        self.prompt = prompt
        self.scheme = scheme
        self.minHeight = minHeight
        self.maxHeight = maxHeight
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            if text.wrappedValue.isEmpty {
                Text(prompt)
                    .marginaliaTextStyle(.body, in: scheme, ink: .inkSecondary)
                    .padding(.horizontal, MarginaliaSpacing.sm.value + 4)
                    .padding(.vertical, MarginaliaSpacing.xs.value + 3)
                    .allowsHitTesting(false)
            }
            TextEditor(text: text)
                .scrollContentBackground(.hidden)
                .marginaliaTextStyle(.body, in: scheme)
                .focused($isFocused)
                .padding(.horizontal, MarginaliaSpacing.sm.value)
                .padding(.vertical, MarginaliaSpacing.xs.value)
        }
        .frame(minHeight: minHeight, maxHeight: maxHeight)
        .background {
            RoundedRectangle(cornerRadius: MarginaliaFieldSpec.standard.radius.value, style: .continuous)
                .fill(Color.marginalia(MarginaliaFieldSpec.standard.fill, in: scheme))
        }
        .overlay {
            RoundedRectangle(cornerRadius: MarginaliaFieldSpec.standard.radius.value, style: .continuous)
                .strokeBorder(
                    Color.marginalia(
                        isFocused ? MarginaliaFieldSpec.standard.focusStroke : MarginaliaFieldSpec.standard.stroke,
                        in: scheme
                    ),
                    lineWidth: 1
                )
        }
    }
}
