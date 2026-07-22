//
//  MarginaliaTextField.swift — themed text/search input (plan §5 Tier 1.1,
//  docs/plans/arikit-component-library.md).
//
//  Wraps stock `TextField(.plain)`; `MarginaliaSearchField` adds a leading
//  `magnifyingglass` + trailing clear button.
//
//  `MarginaliaTextField` (form fields) and the `.compact` search field share
//  `MarginaliaFieldSpec.standard` — `.surface` fill, hairline stroke that becomes `.accent`
//  on focus, `MarginaliaRadius.control`, 26pt height.
//
//  `MarginaliaSearchField` defaults to `.prominent` — a tall, capsule-shaped, top-level
//  find field in the Apple Music idiom. This is the one search style used across the app's
//  primary surfaces (sidebar rail, People, Series) so every search reads as the same
//  control; `.compact` remains for dense inline contexts (e.g. picker sheets).
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
/// when `!text.isEmpty`).
///
/// Two sizes: `.prominent` (default) is the app-wide, Apple-Music-style top-level find —
/// a tall (`Self.prominentHeight`pt) capsule with a medium-weight glyph; `.compact` matches
/// `MarginaliaFieldSpec.standard` (26pt, control radius) for dense inline contexts.
public struct MarginaliaSearchField: View {
    /// Visual sizing for the search field. `.prominent` is the default so every primary
    /// search surface renders the same tall pill; `.compact` is opt-in for picker sheets.
    public enum Size: Sendable {
        case prominent
        case compact
    }

    /// The prominent (default) field height — taller than the 26pt form/dropdown spec so a
    /// top-level search reads as the focal control, matching the Apple Music find field.
    static let prominentHeight: CGFloat = 38

    private let text: Binding<String>
    private let prompt: String
    private let scheme: ColorScheme
    private let size: Size
    private let onSubmit: (() -> Void)?
    @FocusState private var isFocused: Bool

    public init(
        text: Binding<String>,
        prompt: String,
        scheme: ColorScheme,
        size: Size = .prominent,
        onSubmit: (() -> Void)? = nil
    ) {
        self.text = text
        self.prompt = prompt
        self.scheme = scheme
        self.size = size
        self.onSubmit = onSubmit
    }

    private var height: CGFloat {
        size == .prominent ? Self.prominentHeight : MarginaliaFieldSpec.standard.height
    }

    private var horizontalPadding: CGFloat {
        (size == .prominent ? MarginaliaSpacing.md : MarginaliaSpacing.sm).value
    }

    private var glyphSize: CGFloat {
        size == .prominent ? 15 : 13
    }

    /// Prominent search is a capsule (Apple Music idiom); compact keeps the control radius
    /// shared with form fields and dropdowns. Split into fill + stroke builders so the
    /// concrete (insettable) shape is preserved for `strokeBorder`.
    @ViewBuilder
    private var fieldFill: some View {
        let color = Color.marginalia(MarginaliaFieldSpec.standard.fill, in: scheme)
        switch size {
        case .prominent:
            Capsule(style: .continuous).fill(color)
        case .compact:
            RoundedRectangle(cornerRadius: MarginaliaFieldSpec.standard.radius.value, style: .continuous).fill(color)
        }
    }

    @ViewBuilder
    private var fieldStroke: some View {
        let color = Color.marginalia(
            isFocused ? MarginaliaFieldSpec.standard.focusStroke : MarginaliaFieldSpec.standard.stroke,
            in: scheme
        )
        switch size {
        case .prominent:
            Capsule(style: .continuous).strokeBorder(color, lineWidth: 1)
        case .compact:
            RoundedRectangle(cornerRadius: MarginaliaFieldSpec.standard.radius.value, style: .continuous)
                .strokeBorder(color, lineWidth: 1)
        }
    }

    public var body: some View {
        HStack(spacing: MarginaliaSpacing.sm.value) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: glyphSize, weight: .medium))
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
                        .font(.system(size: glyphSize, weight: .regular))
                        .foregroundStyle(Color.marginalia(.inkSecondary, in: scheme))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .frame(height: height)
        .background { fieldFill }
        .overlay { fieldStroke }
        // Make the whole field a hit target — tapping the glyph or the empty padding focuses
        // the input, not just the text glyphs themselves. The inner TextField and clear button
        // consume their own taps first, so this only catches the surrounding area.
        .contentShape(hitShape)
        .onTapGesture { isFocused = true }
    }

    /// The full-field hit region, matched to the visible shape so taps anywhere inside the
    /// pill (or rounded rect) focus the input.
    private var hitShape: AnyShape {
        switch size {
        case .prominent:
            AnyShape(Capsule(style: .continuous))
        case .compact:
            AnyShape(RoundedRectangle(cornerRadius: MarginaliaFieldSpec.standard.radius.value, style: .continuous))
        }
    }
}
