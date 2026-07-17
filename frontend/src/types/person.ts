/**
 * Person Profiles (F2) + Owner Context (F3) types.
 *
 * These mirror the camelCase JSON shapes returned by the Rust `person_*` /
 * `owner_*` / `profile_fact_*` commands (see F2-contract.md). The Rust side
 * serializes with `#[serde(rename_all = "camelCase")]`, so these interfaces
 * are the exact wire shape - no transformation needed on the frontend.
 */

export type FactKind = 'goal' | 'interest' | 'project' | 'role_signal' | 'other';

export type FactSourceKind = 'self_reported' | 'attributed';

export type FactStatus = 'pending' | 'active' | 'superseded' | 'rejected';

export interface Person {
  id: string;
  email?: string | null;
  displayName: string;
  role?: string | null;
  organization?: string | null;
  domain?: string | null;
  notes?: string | null;
  isOwner: boolean;
  createdAt: string;
  updatedAt: string;
}

export interface PersonSummary {
  id: string;
  email?: string | null;
  displayName: string;
  role?: string | null;
  organization?: string | null;
  isOwner: boolean;
  activeFactCount: number;
  pendingFactCount: number;
}

export interface ProfileFact {
  id: string;
  personId: string;
  factText: string;
  factKind: FactKind;
  sourceMeetingId?: string | null;
  sourceMeetingTitle?: string | null;
  sourceSegmentRef?: string | null;
  sourceKind: FactSourceKind;
  confidence: number;
  sourceCount: number;
  status: FactStatus;
  supersededBy?: string | null;
  createdAt: string;
}

export type FactSourceRelation = 'origin' | 'reaffirmed' | 'carried';

export interface ProfileFactSource {
  id: string;
  factId: string;
  meetingId?: string | null;
  meetingTitle?: string | null;
  segmentRef?: string | null;
  sourceKind: FactSourceKind;
  relation: FactSourceRelation;
  confidence: number;
  observedAt: string; // RFC3339 UTC
}

export interface ProfileFactWithPerson {
  fact: ProfileFact;
  personId: string;
  personDisplayName: string;
}

export interface PersonDetail {
  person: Person;
  facts: ProfileFact[];
  meetingCount: number;
}

export interface NewPerson {
  id?: string | null;
  email?: string | null;
  displayName: string;
  role?: string | null;
  organization?: string | null;
  domain?: string | null;
  notes?: string | null;
}

export interface AppConfig {
  /** Company-wide organization (global config, not per-person). Defaults to "Arivo". */
  organization: string;
}

export interface ExtractionResult {
  created: number;
  meetingId: string;
  message: string;
}

/**
 * Result of `person_reconcile_facts_for_meeting` — replaces plain extraction as the
 * post-summary trigger. Instead of only ever inserting new pending facts, reconciliation
 * shows the model each participant's current facts and asks it to add/keep/supersede/
 * remove, then enforces a per-person active-fact cap.
 */
export interface ReconciliationResult {
  meetingId: string;
  added: number;
  superseded: number;
  kept: number;
  removed: number;
  /** Facts auto-pruned afterward for exceeding the per-person active-fact cap. */
  capped: number;
  message: string;
}
