# Robust Migration & Pre-Migration Backup — AriKit Store

> **STATUS: PLAN (2026-07-23).** Incident fix. A populated production DB (22 meetings, 3765 transcripts) was silently wiped by GRDB's `eraseDatabaseOnSchemaChange` after an in-place edit to `v1_baseline` in a DEBUG build that is used as the owner's real app. Root cause is diagnosed; this plan designs the three approved defensive layers. **Plan only — no code is written here.**

## 1. Goal & seam

Make the AriKit GRDB store's migration process incapable of silently destroying user data. Three layers, all approved:

1. **Freeze `v1_baseline`; go additive-only** — the baseline is now effectively shipped (real data exists), so future schema changes are new `registerMigration("v2_…")` blocks, never edits to `v1_baseline`.
2. **Remove `eraseDatabaseOnSchemaChange`** (gate behind an explicit opt-in) — a real schema mismatch must surface as an honest `AppEnvironment.Status.failed(error)` (No-Fake-State), never a wipe.
3. **Automatic pre-migration backup** — snapshot the existing DB to a rolling 3-day store before the migrator runs.

**Seam:** this lands entirely on the target (Swift) side — `AriKit/Sources/AriKit/Store/**` (the store owner and migrator) and the `Ari` app target (`Ari/App/AppEnvironment.swift`, the composition root that resolves paths and drives bootstrap). It is Phase 3 step 1 ("Store") hardening, folding into the completed store plan `docs/plans/arikit-store.md`. The frozen Rust engine (`frontend/src-tauri/**`) is untouched; its `sqlx` schema and `meeting_minutes.sqlite` are read-only legacy sources only.

**Not a re-implementation of a frozen Rust feature.** The Rust app has no equivalent of GRDB's erase-on-schema-change footgun (sqlx applies additive migrations and never auto-erases). This is net-new hardening of a Swift-only mechanism, correctly on the Swift side of the cut.

**WIP check (principle 8):** single feature, single phase (the already-active Store work stream). No second phase opened.

## 2. Root cause (given — not re-investigated)

Two decisions combined into a data-loss trap in `AriKit/Sources/AriKit/Store/Migrations/SchemaMigrator.swift`:

- **`migrator.eraseDatabaseOnSchemaChange = true`** inside `#if DEBUG` (line 36). This GRDB flag, after migrating, compares the resulting schema against a fresh from-scratch migration; on any mismatch it DROPS AND RECREATES the whole database — silently, no thrown error.
- **`v1_baseline` edited in place on every slice** (documented in the file header lines 8–17 and `docs/plans/arikit-store.md` §6/§10). The most recent such edit added `askConversation.seriesId` + index (from `docs/plans/ari-ask-ui.md` Phase 0).

The DEBUG build is the owner's real app. A `v1_baseline` edit + rebuild → the migrated on-disk schema (built from the *old, already-applied* baseline recorded in `grdb_migrations`) no longer matches the *new* from-scratch baseline → GRDB erased all 22 meetings. The "unshipped, no data to protect" assumption behind extend-in-place is now false.

## 3. Module & surface — which files change

| File | Layer | Change |
|---|---|---|
| `AriKit/Sources/AriKit/Store/Migrations/SchemaMigrator.swift` | Store | Freeze `v1_baseline` (header + policy). Remove the `#if DEBUG` erase block; make erase an explicit parameter (default `false`). Rewrite header lines 8–17. |
| `AriKit/Sources/AriKit/Store/AppDatabase.swift` | Store | `makeShared`/`makeInMemory` gain `eraseDatabaseOnSchemaChange: Bool = false`; thread into `SchemaMigrator.migrator(eraseOnSchemaChange:)`. Add an **internal** initializer accepting a custom `DatabaseMigrator` (test seam only). |
| `AriKit/Sources/AriKit/Store/StoreBackup.swift` | Store | **NEW.** Stateless snapshot + count + pure prune-policy functions (§5). |
| `Ari/App/AppEnvironment.swift` | App | In `bootstrap()`, before `AppDatabase.makeShared` (currently line 145): resolve backups dir, run the pre-migration backup off the main actor, prune. Read `ARI_RESET_STORE` and pass it to `makeShared`. Update the file header. |
| `AriKit/Tests/AriKitTests/Store/StoreBackupTests.swift` | Tests | **NEW** (§7). |
| `AriKit/Tests/AriKitTests/Store/MigrationSafetyTests.swift` | Tests | **NEW** — the regression suite (§7). |

### 3.1 Public API — `StoreBackup` (new, in `AriKit.Store`)

`StoreBackup` is where the SQLite work lives (opening a connection, running the snapshot). Per `arikit-store.md` §2.2 ("the app resolves paths; the Store never touches FileManager"), it takes **explicit URLs** handed in by the app and never resolves or enumerates paths itself. The app layer owns all `FileManager` work (directory creation, enumeration, deletion).

```swift
public enum StoreBackup {
    public enum Error: Swift.Error, Sendable {
        case sourceUnreadable(underlying: String)   // couldn't open the source DB
        case destinationExists(URL)                 // VACUUM INTO refuses a pre-existing file
    }

    /// Row count of the `meeting` anchor table in an existing DB file, opened read-only.
    /// Returns 0 if the file has no `meeting` table (a freshly-created / erased DB).
    /// The app calls this to decide whether there is anything worth snapshotting.
    public static func meetingCount(at source: URL) throws -> Int

    /// Snapshot `source` to `destination` (a NEW file) using SQLite's `VACUUM INTO`.
    /// Returns the `meeting` row count captured. The caller guarantees `destination`
    /// does not yet exist. Never mutates `source`.
    @discardableResult
    public static func snapshot(from source: URL, to destination: URL) throws -> Int

    /// PURE retention policy — no FileManager. Given the existing snapshots (URL + mtime),
    /// return the URLs to delete: everything older than `keepWithin`, EXCEPT the single
    /// most-recent snapshot, which is always retained regardless of age.
    public static func snapshotsToPrune(
        existing: [(url: URL, date: Date)],
        now: Date,
        keepWithin: TimeInterval
    ) -> [URL]
}
```

Design notes:
- **Value types + free functions, no `@Observable`.** `StoreBackup` holds no state; it is an `enum` namespace of `static` throwing functions. No view state involved, so no `@Observable` class.
- **`meetingCount` uses the `meeting` table as the "non-empty" anchor.** File byte-size cannot distinguish "schema-only, 0 rows" (the wiped state) from "22 meetings" — an empty schema-only DB is still several KB of DDL. Row count is the only honest signal, which is exactly what the incident requires.

## 4. Concurrency model

- **`StoreBackup` is inherently `Sendable`** — a stateless enum with `static` functions over `Sendable` inputs (`URL`). No actor, no shared mutable state, no `@unchecked Sendable`.
- **Backup runs off the main actor.** `bootstrap()` is `@MainActor async`. `snapshot`/`meetingCount` do synchronous SQLite work (a `VACUUM INTO` on a 20 MB+ DB can take tens of ms) and must not block the main actor. Call them from `await Task.detached { try StoreBackup.snapshot(from:to:) }.value` — inputs are `Sendable` URLs, output is `Int`, so the detached closure type-checks cleanly under Swift 6 strict concurrency.
- **Single-owner is preserved (principle 3) by *sequencing*, not by a second simultaneous owner.** The backup opens a short-lived read connection on the DB file, runs the snapshot, and *closes it* — all **before** `AppDatabase.makeShared` opens its `DatabasePool`. At no instant do two writers (or two live connections from different owners) coexist on the AriKit file. The `VACUUM INTO` destination is a brand-new file. This mirrors the importer's "different file / read-only" reasoning in `arikit-store.md` §5.1, but here it is even safer because it's strictly sequential on the same file.
- **`AppDatabase`'s existing isolation is unchanged.** The added `eraseDatabaseOnSchemaChange` parameter flows through the private init → `SchemaMigrator.migrator(eraseOnSchemaChange:)`; construction stays actor-isolated, accessors stay `nonisolated`. No new `@unchecked Sendable`/`nonisolated(unsafe)`.

## 5. The three layers in detail

### Layer 1 — Freeze `v1_baseline`; additive-only from here

**Rule (the new discipline):** `v1_baseline` is FROZEN. It is now effectively shipped — real user data exists against it. **Every future schema change is a new `migrator.registerMigration("v2_<desc>") { db in … }` block using `ALTER TABLE` / `CREATE TABLE` / `CREATE INDEX`.** Editing `v1_baseline` (adding/removing/retyping a column, adding a table, adding an index) is prohibited.

The current `v1_baseline` source **already matches the hand-repaired live DB** (the header's documented tables, incl. `askConversation.seriesId` at lines 403–414 and its index). So **freezing at the current state is clean — no `v2` is needed today.** Layer 1 is purely a discipline + documentation change plus deleting the erase flag; the DDL itself does not change.

**Shape of the first post-freeze change** (illustrative — a hypothetical column add):

```swift
migrator.registerMigration("v2_add_meeting_templateId_backfill") { db in
    // ALTER TABLE only — never touch v1_baseline. Additive: nullable / defaulted column.
    try db.alter(table: "meeting") { t in
        t.add(column: "someNewField", .text)   // nullable → safe on existing rows
    }
    try db.create(index: "idx_meeting_someNewField", on: "meeting", columns: ["someNewField"])
}
```

Constraints on `v2+` blocks: additive/non-destructive (new nullable/defaulted column, new table, new index). A destructive change (drop/retype a column with live data) requires an explicit data-migration path + sign-off (per the `sqlite-schema` skill). SQLite cannot `ALTER` an FK onto an existing column, so any FK that couldn't be inline in the baseline must use the table-recreate pattern inside its own `v2+` migration — never by editing the baseline.

**Why this is safe with Layer 2:** with erase off, GRDB records `v1_baseline` as applied in `grdb_migrations` and only ever runs *not-yet-applied* registered migrations. Adding `v2_…` on top of an existing DB applies cleanly and additively; the baseline never re-runs.

### Layer 2 — Remove `eraseDatabaseOnSchemaChange` (gate behind explicit opt-in)

Delete the `#if DEBUG … migrator.eraseDatabaseOnSchemaChange = true … #endif` block (SchemaMigrator lines 33–37). Replace with a parameterized migrator:

```swift
enum SchemaMigrator {
    static func migrator(eraseOnSchemaChange: Bool = false) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        // Deliberately OFF by default. `true` DROPS AND RECREATES the DB on any schema
        // mismatch — the exact mechanism that wiped 22 meetings. Only ever enabled via the
        // explicit ARI_RESET_STORE opt-in (see AppEnvironment), never in normal launch.
        migrator.eraseDatabaseOnSchemaChange = eraseOnSchemaChange
        migrator.registerMigration("v1_baseline") { db in /* …frozen… */ }
        return migrator
    }
}
```

`AppDatabase.makeShared(at:eraseDatabaseOnSchemaChange:)` / `makeInMemory(eraseDatabaseOnSchemaChange:)` gain the parameter (default `false`) and pass it into `SchemaMigrator.migrator(eraseOnSchemaChange:)`.

**Where the gate reads:** in the app layer (`AppEnvironment.bootstrap()`), reading the process environment — this is honest process config, not a `FileManager` path resolution, so it belongs in the composition root:

```swift
let allowReset = ProcessInfo.processInfo.environment["ARI_RESET_STORE"] == "1"
let db = try AppDatabase.makeShared(at: url, eraseDatabaseOnSchemaChange: allowReset)
```

A dev who genuinely wants a clean slate sets `ARI_RESET_STORE=1` in the Xcode scheme's environment (or `ARI_RESET_STORE=1` before an `xcodebuild`/`swift run`). The env-read stays in the app; the Store stays policy-parameterized, never reading `ProcessInfo` itself.

**Failure behaviour after the fix (the desired No-Fake-State path):** if someone accidentally edits `v1_baseline` in place *without* a `v2` migration, GRDB (erase off) sees `v1_baseline` already applied, runs nothing, and leaves the on-disk schema as-is. The missing column then surfaces the first time a record touches it as a loud SQLite error ("no such column: …"), which `AppDatabase(_:)` throws out of the migrator/first query, `bootstrap()`'s `catch` maps to `status = .failed(String(describing: error))`, and the UI shows the real error — never a fake-ready empty library. This is the honest surface the incident demanded.

### Layer 3 — Automatic pre-migration backup (rolling 3-day)

**Location in `AppEnvironment.bootstrap()`:** immediately after `let url = try Self.databaseURL()` and **before** `AppDatabase.makeShared(at: url, …)` (currently line 145) — i.e. before the migrator can run.

**Backup mechanism — `VACUUM INTO` (chosen over file copy and over GRDB's `backup(to:)`):**
- **vs. file copy + checkpoint:** the DB is WAL mode (`DatabasePool`). A naïve copy of `ari.sqlite` alone misses committed frames still in `-wal`; copying `-wal`/`-shm` correctly and atomically is error-prone. Rejected.
- **vs. GRDB's `DatabaseReader.backup(to:)`:** works, but produces the snapshot into another live GRDB connection/DB you must then close — more moving parts.
- **`VACUUM INTO 'dest'`** produces a single, self-contained, defragmented snapshot file with **no `-wal`/`-shm` companions**, reads a consistent view including WAL frames, and is a single statement. It fails if the destination already exists — which is fine because destinations are uniquely timestamped. This is the simplest robust option; chosen.

**Backup directory & naming:** `~/Library/Application Support/com.arivo.ari/backups/` (a new sibling of `ari.sqlite`, resolved by a new `AppEnvironment.backupsDirURL()` alongside the existing `databaseURL()`, lines 483–493). Filename `ari-YYYYMMDD-HHmmss.sqlite` (unique per second).

**Flow (all in `AppEnvironment`, `FileManager` work here; SQLite work delegated to `StoreBackup`):**
1. If `ari.sqlite` does not exist → **skip** (genuine fresh first launch — nothing to protect).
2. `let count = try await Task.detached { try StoreBackup.meetingCount(at: url) }.value`. If `count == 0` → **skip** (empty/already-wiped DB — never snapshot an empty DB). This single guard enforces both policy clauses: *the backups directory only ever contains non-empty snapshots by construction*, so "never replace a non-empty snapshot with an empty one" and "always retain the most recent non-empty snapshot" reduce to trivially-true invariants.
3. Create `backups/`, compute `dest = backups/ari-<timestamp>.sqlite`, run `try await Task.detached { try StoreBackup.snapshot(from: url, to: dest) }.value`.
4. **Defensive verify:** if the returned count is `0` (a snapshot that somehow captured nothing), delete `dest` and log — never leave an empty file in the dir.
5. **Prune:** enumerate `backups/` (URL + mtime), call `StoreBackup.snapshotsToPrune(existing:now:keepWithin: 3 * 24 * 3600)`, and delete the returned URLs via `FileManager`. Because every file present is non-empty, the pure policy (delete older-than-3-days except always keep the newest) satisfies the retention spec exactly.
6. The whole Layer-3 block is **best-effort and non-fatal**: wrap in its own `do/catch` that logs and continues to `makeShared`. A backup failure must not block launch (and must not itself trigger a wipe) — the honest-failure surface for a *real* migration problem is Layer 2, not the backup.

**Ordering guarantee:** step 2/3 open and close their `StoreBackup` connection before `makeShared` opens the pool, preserving single-owner (§4).

## 6. Persistence

No schema change. `v1_baseline` DDL is unchanged (Layer 1 is a freeze, and the current source already matches the repaired live DB). No new tables, no new columns, no new migration today. The backup files are opaque SQLite snapshots, not part of the app's live schema. The single-DB-owner rule is reasserted and *strengthened* (§4): the only writer of `ari.sqlite` remains the one `AppDatabase`; `StoreBackup` reads sequentially before that owner opens.

## 7. Acceptance tests (Swift Testing — written first)

New under `AriKit/Tests/AriKitTests/Store/`. These require an **internal test seam** on `AppDatabase`: an `internal init(_ dbWriter:migrator:)` (or `internal static func make(at:migrator:)`) so a test can drive a *custom* `DatabaseMigrator` against an on-disk temp file. Reached via `@testable import AriKit`.

**`MigrationSafetyTests` — the core regression proving a schema change no longer wipes data:**
1. `test_additiveMigrationPreservesData`: open a temp-file DB with migrator A (`v1_baseline` only, erase **off**); insert a meeting; release. Reopen the **same file** with migrator B (`v1_baseline` + a `v2_addColumn` `ALTER TABLE`, erase **off**). Assert the meeting row still exists **and** the new column is present. (Proves the additive path.)
2. `test_inPlaceBaselineEditDoesNotWipe_erasesOff`: open with migrator A, insert a meeting, release. Reopen the same file with migrator C = a **modified baseline** (extra column added in place, NO new migration), erase **off**. Assert `SELECT COUNT(*) FROM meeting == 1` — **data is preserved** (GRDB runs nothing; no wipe). This is the direct regression for the incident.
3. `test_inPlaceBaselineEditWipes_whenEraseOn` (contrast/guard): same as (2) but erase **on**. Assert the meeting row is gone — documents that the flag is the danger and that the opt-in escape hatch actually clean-slates, justifying why default must be `false`.
4. `test_defaultMigratorHasEraseOff`: assert `SchemaMigrator.migrator()` (no arg) yields `eraseDatabaseOnSchemaChange == false`, and `makeShared`/`makeInMemory` default to off.

**`StoreBackupTests` — proving the pre-migration snapshot is created and policy holds:**
5. `test_snapshotCapturesAllRows`: build a temp DB with N meetings + transcripts; `snapshot(from:to:)`; assert the destination file exists, opens as a valid DB, and `meetingCount(at: dest) == N`; assert `source` is byte-identical before/after (never mutated).
6. `test_meetingCountZeroForFreshDb`: a migrated-but-empty DB → `meetingCount == 0` (the skip signal); a nonexistent path → `sourceUnreadable`/0 as specified.
7. `test_pruneKeepsWithin3DaysAndAlwaysNewest`: given synthetic `(url, date)` tuples spanning >3 days, assert `snapshotsToPrune` returns exactly the older-than-3-day entries **minus** the single newest, and that the newest (even if 10 days old) is never in the prune list.
8. `test_snapshotIsSelfContainedNoWal`: after `VACUUM INTO`, assert no `-wal`/`-shm` companion is required to reopen the snapshot (open it read-only and count).

**App-level orchestration** (`AppEnvironment.bootstrap` wiring — skip if the schema-change → wipe path can't be driven at the app target's test level) is covered indirectly: (2) proves the Store never wipes on an in-place edit, and (5) proves a snapshot is produced; the `AppEnvironment` glue (skip-when-fresh, skip-when-empty, verify-and-prune) is small and its policy pieces are unit-tested via (6)/(7).

## 8. Invariants preserved

- **Single-DB-owner (principle 3):** one `AppDatabase` writer for `ari.sqlite`; the backup's `StoreBackup` connection is read-only, on the same file, opened and closed *before* the owner opens — sequential, never concurrent. No dual-ORM/dual-writer situation.
- **No-Fake-State:** a real schema mismatch now surfaces as `Status.failed(error)` with the real SQLite error, never a silent wipe that presents a fake-empty library as "ready." The backup step never claims success it can't back (defensive verify + best-effort catch).
- **Paths resolved by app, Store never touches `FileManager` (arikit-store.md §2.2):** all path resolution, directory creation, enumeration, and deletion stay in `AppEnvironment`; `StoreBackup` receives explicit URLs and only does SQLite work. The `ARI_RESET_STORE` env-read also stays in the app layer.
- **Additive/non-destructive migrations (`sqlite-schema` skill):** re-affirmed and now enforced by freezing the baseline.

## 9. Risks & sequencing

Ordered, each independently testable:

1. **Layer 2 first (highest-leverage, smallest):** parameterize `SchemaMigrator.migrator(eraseOnSchemaChange:)`, remove the `#if DEBUG` erase block, thread the param through `AppDatabase.makeShared`/`makeInMemory`, add the internal custom-migrator test seam. Land `MigrationSafetyTests` (1–4). This alone closes the wipe vector.
2. **Layer 3:** add `StoreBackup` + `StoreBackupTests` (5–8) in the Store; then wire `AppEnvironment` (backups dir, off-main snapshot, verify, prune, `ARI_RESET_STORE` read). Defense-in-depth even if a future bug reintroduces a wipe.
3. **Layer 1 (docs/discipline):** freeze `v1_baseline` — rewrite the SchemaMigrator header, update the plan/skills/rules in lockstep (§10). No DDL change; the current baseline already matches the live DB.

**Risks:**
- **(a)** `VACUUM INTO` on a very large DB adds startup latency — mitigated by running off-main and by the empty-skip guard; the `.importing`-style status could show a brief "Backing up…" if it proves noticeable (optional, not required).
- **(b)** A pre-existing corrupt/locked DB could make `meetingCount` throw — handled by the best-effort catch (log, continue to `makeShared`, which will then surface its own honest error). The backup must never itself block or wipe.
- **(c)** Multiple launches per day create multiple snapshots; retention by age keeps it bounded. An optional "skip if a snapshot exists within the last hour" dedup is left as an open decision, not required for correctness.
- No Rust sidecar/spike-gate applies — this is pure Swift-side hardening.

## 10. Docs to update in lockstep

1. **`AriKit/Sources/AriKit/Store/Migrations/SchemaMigrator.swift`** — rewrite the header (lines 8–17): replace the "extend `v1_baseline` in place while unshipped" policy with "`v1_baseline` is FROZEN (real data exists 2026-07-22); all future changes are new `v2+` migrations." Document the removed erase flag and the `eraseOnSchemaChange` parameter (lines 33–37).
2. **`docs/plans/arikit-store.md`** — §6: replace the "slice-1 findings / extend-in-place while unshipped" note with the freeze rule; §10 sequencing note likewise. Add a short "Migration safety & pre-migration backup" subsection pointing at this plan.
3. **`.claude/skills/grdb/SKILL.md`** — drop the `#if DEBUG m.eraseDatabaseOnSchemaChange = true` example; replace with the parameterized-off-by-default pattern + `ARI_RESET_STORE` note; reinforce "never edit `v1_baseline` — it is shipped"; strengthen the gotcha ("off by default; the incident wiped 22 meetings").
4. **`.claude/rules/swift-conventions.md`** — the "Store is plain GRDB" bullet: add the migration-safety non-negotiables (baseline frozen → additive `v2+` only; `eraseDatabaseOnSchemaChange` never on by default, gated by `ARI_RESET_STORE`; a real mismatch is an honest `.failed`, never a wipe; pre-migration backup runs before the migrator).
5. **`.claude/skills/sqlite-schema/SKILL.md`** — reinforce the additive rule with the concrete "`v1_baseline` is frozen; the erase flag is banned by default" note.
6. **`Ari/App/AppEnvironment.swift`** header — document the new pre-migration backup step in `bootstrap()` and the `ARI_RESET_STORE` opt-in.
7. **Pointers only (no rewrite needed, but flag the policy change):** `docs/plans/ari-ask-ui.md` Phase 0, `docs/plans/arikit-recall-slice2.md` §4, `docs/plans/settings-ui.md` §2.1 — each endorsed an in-place `v1_baseline` edit. Add a one-line note that those were the *last legal* in-place edits; the baseline is now frozen.

## 11. Resolved decisions (2026-07-23)

1. **Reset opt-in surface:** `ARI_RESET_STORE=1` env var. (No `--reset-store` launch argument.)
2. **Backup cadence:** snapshot on every launch, pruned by 3-day age. (No last-hour dedup.)
3. **Retention window:** 3 days rolling; always retain the most recent non-empty snapshot regardless of age.
4. **User-visible backup status:** not required; add a brief "Backing up…" status only if `VACUUM INTO` latency proves noticeable.
