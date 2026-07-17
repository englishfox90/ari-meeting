# brand/ — Ari Meetings "Marginalia" brand system

Canonical brand and design-system reference for the **SwiftUI era** of Ari Meetings.
Adopted 2026-07-16 after a three-concept exploration and a deep-dive iteration with Paul.

- `BRAND.md` — the master document (story, voice, principles, color, type, mark, motion, SwiftUI mapping).
- `tokens.json` — machine-readable tokens mirroring BRAND.md; will drive the SwiftUI theme and a future visual-system test.
- `assets/` — the mark family as tintable SVGs (`currentColor`).

**Important:** the repo-root `DESIGN.md` / `DESIGN.json` are the *current* Tauri app's Arivo system and are
load-bearing fixtures for `frontend/tests/lib/visual-system.test.mjs`. They stay untouched until the SwiftUI
migration replaces that frontend. Do not reconcile the two systems.

Design history (private artifacts): three-concept exploration — https://claude.ai/code/artifact/04888fec-8f2a-4167-94be-e080f667ec3a · Marginalia deep dive — https://claude.ai/code/artifact/2cc325d6-2d4d-4360-ab46-ff1c59e0769b
