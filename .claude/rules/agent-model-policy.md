# Rule: Subagent Model Policy (cheap-produce, principal-review)

When the main loop runs on a top tier (**Opus** or **Fable**), it acts as the *principal engineer / reviewer*: it decomposes work, delegates the mechanical parts to cheaper subagents, and **validates their output itself**. Subagents therefore default to **Sonnet or Haiku** — never silently inherit an Opus/Fable main loop, which is pure cost with no reasoning benefit for mechanical work.

This is the durable form of the `prefer-cheap-agent-models` correction (a subagent audit was mistakenly launched on inherited Opus on 2026-07-17).

## Two enforcement layers

1. **Per-agent default (deterministic) — `model:` frontmatter in `.claude/agents/*.md`.** This binds the tier to the agent regardless of the main-loop model or whether the delegation remembered to pass one. This is the floor.
2. **Ad-hoc calls (this rule) — bare `Agent` / `Workflow agent()` calls** that aren't one of the named agents: pass `model` / `opts.model` explicitly per the tiers below. Do not rely on inheritance.

## Tiers

| Tier | Model | Use for |
|------|-------|---------|
| Mechanical | `haiku` | grep/cross-reference audits, file sweeps, registration checks, structured-output extraction, mechanical ports |
| Producer | `sonnet` | implementing from an approved plan, drafting, most delegated coding, moderate reasoning |
| Principal / gate | `inherit` | genuine architecture/planning, judgment-heavy code review, adversarial verify, ambiguous decisions |

`inherit` (not hardcoded `opus`) is used for the principal tier so those agents track whichever top model the main loop is on — **Opus or Fable** — instead of downgrading Fable→Opus.

## Named-agent assignments (kept in lockstep with the frontmatter)

- `swift-architect` → **inherit** — the plan gates all downstream work; a weak plan is expensive to recover from.
- `swift-code-reviewer` → **inherit** — it *is* the validation gate.
- `swift-implementer` → **sonnet** — produces from an already-approved plan.
- `tauri-command-auditor` → **haiku** — pure registration/casing cross-reference.

## Escalation is allowed

Frontmatter sets the *default floor*, not a ceiling. Override **upward** with the `model` param for a genuinely hard single instance (e.g. a `swift-implementer` port with thorny concurrency). Default down, escalate deliberately — never the reverse.
