/**
 * Person Profiles (F2) + Owner Context (F3) Service
 *
 * Wraps the Rust `person_*` / `owner_*` / `profile_fact_*` /
 * `summary_context_for_meeting` Tauri commands. Pure 1-to-1 invoke wrappers -
 * snake_case argument keys matching the Rust command signatures exactly,
 * camelCase return shapes matching the `#[serde(rename_all = "camelCase")]`
 * structs on the Rust side. Guards against running outside the Tauri
 * runtime (plain `pnpm run dev` in a browser has no backend).
 */

import { invoke } from '@tauri-apps/api/core';
import type {
  AppConfig,
  ExtractionResult,
  FactKind,
  NewPerson,
  Person,
  PersonDetail,
  PersonSummary,
  ProfileFact,
  ProfileFactSource,
  ProfileFactWithPerson,
  ReconciliationResult,
} from '@/types/person';

function isTauriAvailable(): boolean {
  return typeof window !== 'undefined' && Boolean(window.__TAURI_INTERNALS__);
}

export class PersonService {
  /**
   * Whether the app is running inside the Tauri desktop shell (vs. a plain
   * browser dev server, which has no backend).
   */
  isAvailable(): boolean {
    return isTauriAvailable();
  }

  /**
   * List every known person, with honest active/pending fact counts.
   */
  async list(): Promise<PersonSummary[]> {
    return invoke<PersonSummary[]>('person_list');
  }

  /**
   * Fetch a person's authored identity plus all facts and meeting count.
   */
  async get(personId: string): Promise<PersonDetail> {
    return invoke<PersonDetail>('person_get', { personId });
  }

  /**
   * Create or update a person's authored identity fields.
   */
  async upsert(person: NewPerson): Promise<Person> {
    return invoke<Person>('person_upsert', { person });
  }

  /**
   * Delete a person and their facts/links.
   */
  async remove(personId: string): Promise<void> {
    return invoke<void>('person_delete', { personId });
  }

  /**
   * The single owner profile, if one has been set.
   */
  async getOwner(): Promise<Person | null> {
    return invoke<Person | null>('owner_get');
  }

  /**
   * Set (or update) the owner profile. Ensures exactly one owner exists.
   */
  async setOwner(person: NewPerson): Promise<Person> {
    return invoke<Person>('owner_set', { person });
  }

  /**
   * Import attendees from a calendar event as (stub) persons, linking them
   * to the event's meeting if one exists.
   */
  async importFromEvent(eventId: string): Promise<Person[]> {
    return invoke<Person[]>('person_import_from_event', { eventId });
  }

  /**
   * Persons linked to a meeting as participants.
   */
  async meetingParticipants(meetingId: string): Promise<PersonSummary[]> {
    return invoke<PersonSummary[]>('meeting_participants', { meetingId });
  }

  /**
   * A person's inferred facts, optionally including superseded ones.
   */
  async factsForPerson(personId: string, includeSuperseded: boolean): Promise<ProfileFact[]> {
    return invoke<ProfileFact[]>('profile_facts_for_person', {
      personId,
      includeSuperseded,
    });
  }

  /**
   * Every fact across all persons still awaiting confirm/reject.
   */
  async pendingFacts(): Promise<ProfileFactWithPerson[]> {
    return invoke<ProfileFactWithPerson[]>('profile_facts_pending');
  }

  /**
   * Confirm a pending fact, promoting it to active.
   */
  async confirmFact(factId: string): Promise<void> {
    return invoke<void>('profile_fact_confirm', { factId });
  }

  /**
   * Reject a pending fact.
   */
  async rejectFact(factId: string): Promise<void> {
    return invoke<void>('profile_fact_reject', { factId });
  }

  /**
   * Add a manually-authored fact (lands active, not pending).
   */
  async addManualFact(personId: string, factText: string, factKind: FactKind): Promise<ProfileFact> {
    return invoke<ProfileFact>('profile_fact_add_manual', {
      personId,
      factText,
      factKind,
    });
  }

  /**
   * Run fact extraction over a meeting's transcript. Extracted facts land as
   * 'pending'. Safe to call fire-and-forget after a summary completes.
   */
  async extractFactsForMeeting(meetingId: string): Promise<ExtractionResult> {
    return invoke<ExtractionResult>('person_extract_facts_for_meeting', { meetingId });
  }

  /**
   * Reconcile a meeting's facts against each participant's CURRENT active+pending facts
   * (add/keep/supersede/remove) instead of blindly appending new ones, then enforce the
   * per-person active-fact cap. Supersedes `extractFactsForMeeting` as the post-summary
   * trigger — prefer this for new callers.
   */
  async reconcileFactsForMeeting(meetingId: string): Promise<ReconciliationResult> {
    return invoke<ReconciliationResult>('person_reconcile_facts_for_meeting', { meetingId });
  }

  /**
   * All recorded sources (origin + reaffirmations + carried-forward) for a fact,
   * newest observation first. Empty for manually-added facts.
   */
  async factSources(factId: string): Promise<ProfileFactSource[]> {
    return invoke<ProfileFactSource[]>('profile_fact_sources', { factId });
  }

  /**
   * Active/pending facts for a person that haven't been (re)confirmed in over 4 weeks —
   * candidates for reconfirmation or removal. No UI consumes this yet; natural mount point
   * is a "Needs review" section on the person detail page, next to the pending-facts
   * confirm/reject UI.
   */
  async factsNeedingReview(personId: string): Promise<ProfileFact[]> {
    return invoke<ProfileFact[]>('person_facts_needing_review', { personId });
  }

  /**
   * Assemble the terse owner + participants context block for a meeting, to
   * be prepended to the summary's custom prompt. Returns "" when nothing is
   * known.
   */
  async summaryContextForMeeting(meetingId: string): Promise<string> {
    return invoke<string>('summary_context_for_meeting', { meeting_id: meetingId });
  }

  /**
   * The global app config (currently just the company-wide organization).
   * Organization is a global setting, not a per-person field.
   */
  async getAppConfig(): Promise<AppConfig> {
    return invoke<AppConfig>('app_config_get');
  }

  /**
   * Set the company-wide organization (persisted to the editable ari.config.json).
   */
  async setOrganization(organization: string): Promise<AppConfig> {
    return invoke<AppConfig>('app_config_set_organization', { organization });
  }
}

// Export singleton instance
export const personService = new PersonService();
