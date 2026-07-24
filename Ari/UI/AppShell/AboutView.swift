//
//  AboutView.swift — the About modal (presented as a sheet from the left rail's "About" row).
//
//  Rewritten from the old Rust/React "About" dialog. Two things changed on purpose:
//
//  1. Meetily is credited as an ORIGIN, not an UPSTREAM. Ari began as a fork of Meetily by
//     Zackriya Solutions and inherited its capture/transcription engine, but it is now
//     Arivo's own product — there is no ongoing connection to track (see
//     .claude/rules/codebase-ownership.md). The old "independent fork … view upstream Meetily"
//     framing implied a live link that no longer exists; this is a gracious inspiration credit.
//
//  2. The lead value is COMPLETELY OFFLINE PROCESSING. Capture, transcription, and
//     summarization all run on-device; nothing leaves the Mac unless the owner deliberately
//     configures a remote provider. That is the pillar, so it leads.
//
//  No "Check for Updates" control: the Swift app ships no updater, and a button that does
//  nothing would be fake state (brand No-Fake-State, absolute). It is omitted rather than
//  faked.
//
import AriKit
import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var scheme

    /// Meetily by Zackriya Solutions — the origin project Ari forked from and still credits.
    private static let meetilyURL = URL(string: "https://github.com/Zackriya-Solutions/meeting-minutes")!

    var body: some View {
        VStack(spacing: 0) {
            closeBar
            ScrollView {
                VStack(spacing: MarginaliaSpacing.xl.value) {
                    masthead
                    Divider().overlay(Color.marginalia(.hairline, in: scheme))
                    pillarsSection
                    attribution
                }
                .padding(.horizontal, MarginaliaSpacing.xl.value)
                .padding(.bottom, MarginaliaSpacing.xl.value)
            }
        }
        .frame(width: 540, height: 760)
        .background(Color.marginalia(.canvas, in: scheme))
    }

    // MARK: - Close bar

    private var closeBar: some View {
        HStack {
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.marginalia(.inkSecondary, in: scheme))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, MarginaliaSpacing.md.value)
        .padding(.top, MarginaliaSpacing.md.value)
    }

    // MARK: - Masthead

    private var masthead: some View {
        VStack(spacing: MarginaliaSpacing.sm.value) {
            Image("DictationMark")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(96.0 / 64.0, contentMode: .fit)
                .frame(width: 56)
                .foregroundStyle(Color.marginalia(.accent, in: scheme))

            Text("Ari Meetings")
                .marginaliaTextStyle(.title1, in: scheme)

            Text(Self.appVersionString)
                .marginaliaTextStyle(.timecode, in: scheme, ink: .inkSecondary)

            Text(
                "Private, on-device meeting intelligence for macOS. Ari records and transcribes "
                    + "your meetings, then writes summaries that understand who was in the room, who "
                    + "owns the conversation, and what kind of meeting it is."
            )
            .marginaliaTextStyle(.body, in: scheme, ink: .inkSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, MarginaliaSpacing.xs.value)
        }
        .padding(.top, MarginaliaSpacing.sm.value)
    }

    // MARK: - Pillars

    private var pillarsSection: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
            Text("WHAT ARI IS")
                .marginaliaTextStyle(.caption, in: scheme)

            // Offline processing leads — it is the pillar the product is built on.
            pillarRow(
                Pillar(
                    title: "Completely offline processing",
                    body: "Capture, transcription, and summarization all run on this Mac. Nothing "
                        + "leaves the machine unless you deliberately configure a remote provider."
                ),
                Pillar(
                    title: "Context-aware summaries",
                    body: "Meetings aren\u{2019}t anonymous events. Ari weaves in the owner, the "
                        + "people present, and the meeting type so each summary fits the conversation."
                )
            )
            pillarRow(
                Pillar(
                    title: "A connected record",
                    body: "Recurring people and recurring formats carry forward across meetings, "
                        + "with calendar awareness grounding who and what."
                ),
                Pillar(
                    title: "Honest by design",
                    body: "Recording is always prompted, never silent. Summaries and recall cite "
                        + "real transcripts \u{2014} no invented activity or fabricated sources."
                )
            )
        }
    }

    private func pillarRow(_ left: Pillar, _ right: Pillar) -> some View {
        HStack(alignment: .top, spacing: MarginaliaSpacing.md.value) {
            pillarCard(left)
            pillarCard(right)
        }
    }

    private func pillarCard(_ pillar: Pillar) -> some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
            Text(pillar.title)
                .marginaliaTextStyle(.subheadline, in: scheme)
                .fixedSize(horizontal: false, vertical: true)
            Text(pillar.body)
                .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
        .padding(MarginaliaSpacing.md.value)
        .background {
            RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                .fill(Color.marginalia(.elevated, in: scheme))
                .overlay {
                    RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                        .strokeBorder(Color.marginalia(.hairline, in: scheme), lineWidth: 1)
                }
        }
    }

    // MARK: - Attribution

    /// Meetily as origin, not upstream. The link is a credit to the project Ari forked from,
    /// not a "check upstream" affordance.
    private var attribution: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
            (
                Text("Built on Meetily. ")
                    .font(MarginaliaTextStyle.body.font)
                    .foregroundColor(Color.marginalia(.inkBody, in: scheme))
                    + Text(
                        "Ari began as a fork of Meetily by Zackriya Solutions and grew from its "
                            + "capture and transcription engine. It has since become it\u{2019}s own "
                            + "product \u{2014} Meetily\u{2019}s original work and MIT license remain "
                            + "gratefully credited."
                    )
                    .font(MarginaliaTextStyle.body.font)
                    .foregroundColor(Color.marginalia(.inkSecondary, in: scheme))
            )
            .fixedSize(horizontal: false, vertical: true)

            Button {
                openURL(Self.meetilyURL)
            } label: {
                Label("Meetily on GitHub", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.marginalia(.secondary, .large, in: scheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MarginaliaSpacing.lg.value)
        .background {
            RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                .fill(Color.marginalia(.surface, in: scheme))
                .overlay {
                    RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                        .strokeBorder(Color.marginalia(.hairline, in: scheme), lineWidth: 1)
                }
        }
    }

    // MARK: - Version

    /// The app's real `CFBundleShortVersionString` (No-Fake-State — never a fabricated version
    /// number). Falls back to an honest placeholder if the bundle has no version yet.
    private static var appVersionString: String {
        guard let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            return "Version \u{2014}"
        }
        return "Version \(version)"
    }
}

/// One "what Ari is" pillar — plain data so `pillarRow`/`pillarCard` stay declarative.
private struct Pillar {
    let title: String
    let body: String
}

#Preview {
    AboutView()
        .frame(width: 540, height: 760)
}
