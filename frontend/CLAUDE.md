# Frontend — Scoped Rules

You're in the Next.js 14 frontend (App Router, static export, dev on port 3118). See repo-root `CLAUDE.md` and `.claude/rules/` for the full picture; this is the frontend-specific checklist.

## The rules that bite

1. **State is React Context only** — no redux/zustand/react-query. Add providers to the `src/app/layout.tsx` tree. Route recording state through `RecordingStateContext` / `src/services/recordingService.ts`, not ad-hoc `invoke`.
2. **Calling the backend:** `invoke` from `@tauri-apps/api/core`. **Top-level arg keys are camelCase** — Tauri v2 maps them to the snake_case Rust params (`meetingId` → `meeting_id`). Keys *nested inside a struct param* instead follow that struct's serde rule (snake_case when it has no `#[serde(rename_all)]`, e.g. `{ args: { save_path } }`). Prefer wrapping new calls in a `src/services/*Service.ts`. Two casing layers — don't conflate them: `.claude/rules/tauri-ipc.md`.
3. **Styling:** always merge classes with `cn()` from `@/lib/utils`. Use the HSL CSS-variable tokens in `src/app/globals.css` — never hardcode hex. Build UI from shadcn/ui primitives in `src/components/ui/`.
4. **Design tokens are load-bearing.** `frontend/tests/lib/visual-system.test.mjs` asserts the UI matches root `DESIGN.md`/`DESIGN.json`. Change a token in `globals.css`/`tailwind.config.js` → update `DESIGN.*` in lockstep or the test fails. (`.claude/rules/design-system.md`)
5. **No-Fake-State:** never render invented metrics/progress/counts/timestamps/citations. Honest empty/loading/error states only.
6. **Guard Tauri availability** — code paths that call `invoke` must handle running outside the Tauri runtime (plain `pnpm run dev` in a browser has no backend).

## Authoritative config files (duplicates still present — verify before touching)

There are duplicate build configs; the authoritative one in each pair is:

- **Tailwind:** `tailwind.config.js` (shadcn points here). ⚠️ But `tailwind.config.ts` is the only one loading `@tailwindcss/typography`, and `prose` classes are used (chat + transcript panels) — do NOT delete `.ts` until you confirm which config Tailwind actually loads and that `prose` styling survives. Dedup is a tracked follow-up.
- **PostCSS:** `postcss.config.js` (has tailwind + autoprefixer). `.mjs` is a Tailwind-v4 stub — verify resolution order before removing.
- **ESLint:** `.eslintrc.json` via `next lint`. `eslint.config.mjs` is a non-functional flat config (missing deps) — safe candidate to remove after confirming `next lint` still uses the legacy file.

## Tests

Run: `node --test tests/lib/*.test.mjs` (there is no `package.json` test script). One TS test is Bun-only: `bun test tests/lib/blocknote-markdown.test.ts`. Many tests are source-regex/visual-system assertions — update them in lockstep with UI copy, tokens, and lifecycle strings. Typecheck with `npx tsc --noEmit`.

## Directory map

`src/app/` (routes + layout provider tree), `src/components/` (+ `ui/` shadcn), `src/contexts/` (8 global contexts), `src/hooks/` (~19), `src/lib/` (domain logic incl. `native-qa-mode`, `recording-lifecycle`), `src/services/` (Tauri IPC wrappers), `src/types/`.
