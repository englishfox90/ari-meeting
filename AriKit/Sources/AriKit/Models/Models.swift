//
//  Models.swift — the shared domain value types (Swift mirror of the frozen Rust engine).
//
//  This module is the Swift port of the Rust engine's domain vocabulary
//  (`database/models.rs`, `persons/models.rs`, `meeting_series/models.rs`,
//  `calendar/models.rs`) as **pure, persistence-agnostic value types**. It is the
//  foundational brick that `Store`, `Recall`, and `Context` build on
//  (docs/plans/arikit-models.md).
//
//  Design rules (plan §3, §7):
//  - Every type is a `struct`/`enum` and unconditionally `Sendable`; no actors, no
//    `@unchecked Sendable`, no `nonisolated(unsafe)`.
//  - No persistence: no GRDB/SQLiteData, no `FetchableRecord`/`PersistableRecord`. These
//    are the values a later `Store/` port will persist, not the store itself.
//  - Codable is camelCase-native, matching the frozen engine's IPC surface
//    (`#[serde(rename_all = "camelCase")]`). Ambiguous documented exceptions carry
//    explicit `CodingKeys`.
//
//  `enum Models` is the module namespace; it hosts the shared Codable factory
//  (`Models.jsonDecoder` / `Models.jsonEncoder`, see Support/ModelsCoding.swift) with the
//  RFC3339 date strategy every domain type decodes through.
//
public enum Models {}
