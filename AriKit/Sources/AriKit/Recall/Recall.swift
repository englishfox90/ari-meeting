///
///  Recall.swift — SCAFFOLD, no engine code yet, gated by Phase 3.
///
///  Per plans/swift-migration-plan.md, this module will hold the hybrid retrieval engine
///  (BM25 ⊕ vector RRF + recency) that answers "Ask Meetings" queries — the Swift port of
///  today's Rust `api_answer_meetings_locally` safety shell. The invariants (loopback-only,
///  bounded context, never-invents-citations, sources returned separately from the answer)
///  must survive the port as tested Swift behavior, not just intentions (plan principle 6).
///
public enum Recall {}
