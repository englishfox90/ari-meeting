---
description: Run the project's full check suite — frontend tests, typecheck, lint, build, and Rust check/test.
---

Run the checks that gate a non-trivial change. Report results honestly — if something fails, show the output; don't declare success on a partial pass.

Frontend (from `frontend/`):
```bash
node --test tests/lib/*.test.mjs      # no package.json script exists for this
npx tsc --noEmit
pnpm lint
pnpm build
```
If `bun` is available, also: `bun test tests/lib/blocknote-markdown.test.ts`

Rust (from repo root):
```bash
cargo check
cargo test
```

Reminders:
- Many frontend tests are source-regex / visual-system assertions that read `DESIGN.md`/`DESIGN.json`. If you changed UI copy, design tokens, or recording-lifecycle strings, expect these to fail until updated in lockstep — surface which, don't silently skip.
- `cargo check`/`cargo test` are slow (native compilation of whisper/llama/ONNX). Run them in the background and monitor.
