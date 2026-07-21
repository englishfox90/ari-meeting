//
//  MarginaliaTextField.swift — themed text/search input (plan §5 Tier 1.1,
//  docs/plans/arikit-component-library.md).
//
//  Wraps stock `TextField(.plain)`; `MarginaliaSearchField` adds a leading
//  `magnifyingglass` + trailing clear button. Both share `MarginaliaFieldSpec.standard` —
//  `.surface` fill, hairline stroke that becomes `.accent` on focus, `MarginaliaRadius
//  .control`, 26pt height.
//
import SwiftUI

/// A themed single-line text field.
public struct MarginaliaTextField: View {
    private let text: Binding<String>
    private let prompt: String
    private let scheme: ColorScheme
    @FocusState private var isFocused: Bool

    public init(text: Binding<String>, prompt: String, scheme: ColorScheme) {
        self.text = text
        self.prompt = prompt
        self.scheme = scheme
    }

    public var body: some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain)
            .marginaliaTextStyle(.body, in: scheme)
            .focused($isFocused)
            .padding(.horizontal, MarginaliaSpacing.sm.value)
            .frame(height: MarginaliaFieldSpec.standard.height)
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

/// A themed search field: leading `magnifyingglass`, trailing clear button (shown only
/// when `!text.isEmpty`), same surface/stroke/radius/height as `MarginaliaTextField`.
public struct MarginaliaSearchField: View {
    private let text: Binding<String>
    private let prompt: String
    private let scheme: ColorScheme
    private let onSubmit: (() -> Void)?
    @FocusState private var isFocused: Bool

    public init(text: Binding<String>, prompt: String, scheme: ColorScheme, onSubmit: (() -> Void)? = nil) {
        self.text = text
        self.prompt = prompt
        self.scheme = scheme
        self.onSubmit = onSubmit
    }

    public var body: some View {
        HStack(spacing: MarginaliaSpacing.xs.value) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.marginalia(.inkSecondary, in: scheme))

            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .marginaliaTextStyle(.body, in: scheme)
                .focused($isFocused)
                .onSubmit {
                    onSubmit?()
                }

            if !text.wrappedValue.isEmpty {
                Button {
                    text.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.marginalia(.inkSecondary, in: scheme))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, MarginaliaSpacing.sm.value)
        .frame(height: MarginaliaFieldSpec.standard.height)
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
