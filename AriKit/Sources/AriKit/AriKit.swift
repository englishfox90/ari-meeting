//
//  AriKit.swift — package anchor.
//
//  Placeholder so the package compiles and the Swift tooling has a target. Real domain
//  code (Models / Store / Recall / Context) arrives phase by phase per
//  plans/swift-migration-plan.md — do not port engine code here ahead of its Phase-0 gate.
//

/// Namespace for the shared Ari domain layer.
///
/// Kept as a caseless enum (no instances) — it exists only to hang package-level
/// constants and, later, the module's public surface off of.
public enum AriKit {
    /// Semantic version of the AriKit package. Bumped as real subsystems land.
    public static let version = "0.0.1-scaffold"
}
