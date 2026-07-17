---
description: Implement a Swift feature from a spec/plan doc — architect → implement → test → review loop.
---

Implement a net-new capability **Swift-first** (per the migration plan: net-new work does not grow the Rust/React app). Drive the loop; don't freelance a big change without a plan.

Input: `$ARGUMENTS` names the feature or points at a spec. Look for a spec in `docs/specs/` or a plan in `docs/plans/`; if none exists, produce one first.

Loop:

1. **Plan (architect).** If there's no `docs/plans/<feature>.md`, dispatch the **`swift-architect`** agent to write one (plan-only — it does not edit code). The plan states: which `AriKit` module(s) or app target it touches, the public Swift surface, concurrency/isolation model, the tests that encode the acceptance bar, and any invariant it must preserve.
2. **Confirm the seam.** Verify it lands on the **target side** of any cut seam (plan principle 8): once the Swift store exists, new tables go into the SQLiteData store only; new UI goes SwiftUI-first. New persistence uses the **`grdb`** / **`sqlite-schema`** skills. The Rust app is **frozen** (all F1–F8 shipped there as the baseline) — this is a *new* capability going Swift-side, not a re-implementation of an existing frozen Rust feature. If the request is really "redo something the frozen Rust app already does," stop and flag it — we don't re-port frozen features on a whim.
3. **Implement.** Write the Swift + its tests together. Swift 6 strict concurrency; `@Observable`-MVVM for any view state (no TCA). The PostToolUse hook formats/lints each file as you go.
4. **Verify.** `/swift-test` green, `/swift-build` clean. For anything user-visible, `/swift-run` and actually observe it.
5. **Review.** Dispatch **`swift-code-reviewer`** on the diff (Swift 6 concurrency, invariant preservation, GRDB-only) before considering it done.

Keep to the WIP limit: **one feature in flight**. If asked to start a second, say so.
