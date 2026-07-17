# Rule: This Is Our Codebase

This project began as a fork of `henryvn27/meetily_improved` (→ Zackriya's Meetily, MIT), but it is now **Arivo's own product**, developed in our own direction. We **own the entire tree** — inherited engine code included — and there is no upstream rebase to protect.

This rule replaces the former *additive-only* rule, which existed only to keep rebases against upstream cheap. That constraint is retired.

## What this means

- **Refactor inherited code freely.** Reorganizing, renaming, splitting, or deleting upstream-derived files is allowed and welcome when it improves the code. You are not confined to "registration points" anymore.
- **Delete dead code** rather than working around it. (The historical dead files — `lib_old_complex.rs`, `audio_v2/`, `*-old.rs`, `*.backup`, `audio/stt.rs` — have already been removed.)
- **No upstream tracking.** We do not fetch, merge, or rebase from Meetily/meetily_improved. Don't add machinery or docs that assume we do.

## What still holds (these are correctness rules, not fork rules)

- **Two-edit command registration** — a `#[tauri::command]` plus its entry in `generate_handler!` in `lib.rs`. Forgetting the second is a silent "command not found". (`tauri-ipc.md`)
- **DB access through `database/repositories/` only** — never inline `sqlx` in command modules. (`coding-conventions.md`)
- **Preserve and extend the engine's tests.** The codebase ships unit tests for engine behavior; keep them passing and add to them. The `local_recall_tests` recall invariants (loopback-only, bounded context, no invented citations) are load-bearing.
- **Keep the docs honest.** When you change structure, update `.claude/context/architecture.md`, the module map, and any scoped `CLAUDE.md` in lockstep. When you change a design token, update `DESIGN.json`/`DESIGN.md` (the visual-system test enforces this).

## The remaining discipline

Prefer **new modules, tables, and commands for net-new capability** — not to appease upstream, but because separation of concerns keeps the tree navigable. Editing existing code is fully allowed when it's the right call. Refactor deliberately (for clarity or correctness), run the checks (`build-and-run.md`) before committing non-trivial changes, and leave the tree more coherent than you found it.
