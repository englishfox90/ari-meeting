//
//  AriKit.swift — package anchor.
//
//  Real domain code (Models / Store / Recall / Context / Engine) arrives phase by phase
//  per plans/swift-migration-plan.md — see the doc comment at the top of each module's
//  namespace file for what's scoped there and why it's still empty. DesignSystem is the
//  one module that IS live today: it's needed by the very first SwiftUI screen, not
//  gated behind a Phase-0 spike.
//

/// Namespace for the shared Ari domain layer.
///
/// Kept as a caseless enum (no instances) — it exists only to hang package-level
/// constants and, later, the module's public surface off of.
public enum AriKit {
    /// Semantic version of the AriKit package. Bumped as real subsystems land.
    public static let version = "0.0.1-scaffold"
}
