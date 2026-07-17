# Rule: Verify a Module Is Live; Delete Dead Code

The tree inherited dead code alongside live code with **near-identical names** — a real trap. The known-dead files have now been removed, but the habit still matters: before building on a module, confirm it's actually wired.

## Previously-dead files — now removed

These were confirmed dead (not declared in `lib.rs`, registered to no command) and have been **deleted**:

- `frontend/src-tauri/src/lib_old_complex.rs` (old 2,437-line monolith, dead `TRANSCRIPT_SERVER_URL`)
- `frontend/src-tauri/src/audio/core-old.rs`
- `frontend/src-tauri/src/audio/recording_saver_old.rs`
- `frontend/src-tauri/src/audio/recording_commands.rs.backup`
- `frontend/src-tauri/src/audio/stt.rs` (early prototype with `speaker_embedding`, referenced crates not in `Cargo.toml`)
- `frontend/src-tauri/src/audio_v2/` (dormant parallel rewrite, 20+ TODOs, wired to no command)

If any reference to these resurfaces, it's stale — remove it.

## The archived Python backend

`archive/legacy-python-backend/` (formerly `backend/`) is the pre-native Meetily FastAPI + Docker + whisper-server stack. It is **dead** — the app is fully native (SQLite + repositories + local/cloud LLMs + llama-helper sidecar). Kept only for migration reference.

- Do not run it, add endpoints to it, or treat it as a supported API.
- Do not reintroduce a `localhost:5167` (Python) or `127.0.0.1:8178` (old transcript server) dependency. Any remaining references to these are stale constants/CSP leftovers — safe to delete.

## How to check a file is live

- Is it declared? `grep "mod <name>" frontend/src-tauri/src/lib.rs`
- Is the command registered? Search the `generate_handler![…]` list in `lib.rs`.
- Is it imported by live code? `rg "<symbol>" --type rust`

When two files share a base name (`x.rs` vs `x-old.rs`), the un-suffixed one is almost always live — but verify.

## Removing dead code is now the default

We own the whole tree (see `codebase-ownership.md`), so there's no reason to leave dead code in place. When you confirm something is dead, **delete it** rather than working around it. `frontend/src-tauri/CLEANUP_PLAN.md` still tracks larger structural cleanups (module dedup, dependency audit); reconcile with it and, for anything non-trivial, confirm with the user before deleting.
