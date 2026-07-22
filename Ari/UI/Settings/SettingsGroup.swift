//
//  SettingsGroup.swift — the Apple-System-Settings grouped-list idiom, Marginalia-skinned
//  (docs/plans/settings-ui.md §6).
//
//  Replaces the earlier one-card-per-setting stack (the removed `SettingsCard`) with the familiar
//  macOS System Settings shape: related rows share ONE paper
//  container separated by inset hairline dividers, each row `label-left / control-right`, with an
//  optional uppercase header above and a caption footnote below. Jakob's-law familiar (mirrors the
//  system Settings the user already knows), still unmistakably ours — warm `.elevated` paper +
//  `.hairline` stroke, never glass (glass stays chrome-only per `SettingsView`).
//
//  Three pieces:
//    • `SettingsGroup { … }`      — header + divider-joined container + footnote.
//    • `SettingsRow(_:…) { … }`   — one titled row, label-left / trailing control-right.
//    • `.settingsRowInsets()`     — the row insets for a free-form block dropped straight into a
//                                    group (an API-key field, a download progress bar, a button).
//
import AriKit
import AriViewModels
import SwiftUI

/// A grouped-list container: an optional caption header, a paper card whose direct child views are
/// treated as rows and joined by inset hairline dividers, and an optional caption footnote.
///
/// Each top-level view in `content` becomes one row — compose `SettingsRow`s, or any view carrying
/// `.settingsRowInsets()`. Dividers are inserted *between* rows only (never leading/trailing), so a
/// single-row group reads as a plain card.
struct SettingsGroup<Content: View>: View {
    let header: String?
    let footnote: String?
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var scheme

    init(header: String? = nil, footnote: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.header = header
        self.footnote = footnote
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
            if let header {
                Text(header)
                    .marginaliaTextStyle(.caption, in: scheme)
                    .padding(.leading, MarginaliaSpacing.md.value)
            }

            VStack(spacing: 0) {
                Group(subviews: content()) { subviews in
                    // Positional identity (`id: \.offset`) is safe here ONLY because no row inside a
                    // group holds its own `@State` — all Settings state lives at the section level
                    // and controls bind by value (e.g. calendars by `calendarId`). If a future row
                    // gains internal `@State`, switch to the subview's stable identity.
                    ForEach(Array(subviews.enumerated()), id: \.offset) { index, subview in
                        subview
                        if index < subviews.count - 1 {
                            Rectangle()
                                .fill(Color.marginalia(.hairline, in: scheme))
                                .frame(height: 1)
                                .padding(.leading, MarginaliaSpacing.md.value)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                    .fill(Color.marginalia(.elevated, in: scheme))
            }
            .overlay {
                RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                    .strokeBorder(Color.marginalia(.hairline, in: scheme), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous))

            if let footnote {
                Text(footnote)
                    .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
                    .padding(.leading, MarginaliaSpacing.md.value)
            }
        }
    }
}

/// One grouped-list row: a leading label block (title + optional secondary description) and a
/// trailing control (a `Picker(.menu).labelsHidden()`, a bare `Toggle`, a value + badge, …).
///
/// For a row that is entirely free-form (a field, a progress bar, a button block), skip this and
/// drop the content into the group with `.settingsRowInsets()` instead.
struct SettingsRow<Trailing: View>: View {
    private let title: String
    private let description: String?
    @ViewBuilder private let trailing: () -> Trailing

    @Environment(\.colorScheme) private var scheme

    init(_ title: String, description: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.description = description
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: MarginaliaSpacing.md.value) {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                Text(title)
                    .marginaliaTextStyle(.body, in: scheme)
                if let description {
                    Text(description)
                        .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                }
            }
            Spacer(minLength: MarginaliaSpacing.sm.value)
            trailing()
        }
        .settingsRowInsets()
    }
}

extension View {
    /// The standard grouped-list row insets — horizontal `.md`, vertical `.sm`, full-width leading,
    /// with the ~44 pt minimum row height macOS lists use. Applied by `SettingsRow` and by any
    /// free-form block dropped directly into a `SettingsGroup`.
    func settingsRowInsets() -> some View {
        padding(.horizontal, MarginaliaSpacing.md.value)
            .padding(.vertical, MarginaliaSpacing.sm.value)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
}

/// A grouped-list toggle row: label-left / switch-right, matching macOS System Settings. The switch
/// takes its color from the app's global tint (BRAND.md §10) — never hand-colored here.
///
/// For a control that isn't built yet, prefer `honestDisabledRow(_:availability:)` on the binding
/// site so the real `Availability` reason surfaces as the row subtitle and the switch greys out —
/// the Apple-idiomatic honest-disabled treatment (No-Fake-State), no separate info banner.
struct SettingsToggleRow: View {
    private let title: String
    private let description: String?
    private let isOn: Binding<Bool>

    init(_ title: String, description: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.description = description
        self.isOn = isOn
    }

    var body: some View {
        SettingsRow(title, description: description) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

extension Availability {
    /// The disabled reason string, or `nil` when enabled — for surfacing honest-disabled state as a
    /// row subtitle inside a `SettingsGroup`.
    var disabledReason: String? {
        if case let .disabled(reason) = self {
            return reason
        }
        return nil
    }

    var isDisabled: Bool {
        disabledReason != nil
    }
}
