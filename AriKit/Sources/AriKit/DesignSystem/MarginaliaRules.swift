///
///  MarginaliaRules.swift — the brand rules encoded as constants.
///
///  Mirrors `brand/tokens.json` → `rules`. These aren't rendering primitives like the rest
///  of DesignSystem — they're brand invariants (BRAND.md §3, §9) surfaced as testable
///  constants so a future lint/review pass has something concrete to check code against,
///  rather than re-reading prose each time.
///
public enum MarginaliaRules {
    /// The Signal Rule: the accent (Shin-kai) covers at most this fraction of any screen.
    public static let accentMaxCoverage: Double = 0.08

    /// The only roles the accent is allowed to signal (BRAND.md §3, §9).
    public static let accentAllowedOn: [String] = ["selection", "citations", "links", "speakerNames"]

    /// Solid accent fill is reserved for the one primary action per view/viewport; all
    /// other accent use is stroke, text, or wash.
    public static let accentSolidFillExclusive = true

    /// The heading ink (Iron Gall / ink-washed paper white) is text only — never
    /// interactive, never a state signal.
    public static let headingInkInteractive = false

    /// No-Fake-State (absolute): never invent metrics, progress, counts, timestamps, or
    /// citations not backed by real application state.
    public static let noFakeState = true

    /// Recording is always prompted, never silent.
    public static let recordingAlwaysConsented = true

    /// Every neutral in the palette is warm; cool grays are never introduced.
    public static let warmNeutralsOnly = true

    /// Bricolage Grotesque is used for headings/display only at this size and above;
    /// below it, SF Pro Semibold stands in.
    public static let bricolageMinSizePt: Double = 17

    /// The full Dictation mark is never rendered below this height; below it, callers
    /// switch to the signature-flick cut instead.
    public static let markMinFullSizePx: Double = 32
}
