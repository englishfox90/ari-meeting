import { invoke as invokeTauri } from '@tauri-apps/api/core';

export interface TemplateInfo {
  id: string;
  name: string;
  description: string;
}

export interface TemplateSuggestion {
  id: string;
  name: string;
}

/**
 * Template IPC wrappers.
 *
 * `suggestTemplate` is F6 auto-selection: the backend classifies the transcript
 * against the available templates and returns the best-fitting one. It never
 * throws for classifier failure (the Rust side degrades to `standard_meeting`),
 * but callers should still guard so a summary is never blocked by this step.
 */
export const templateService = {
  async listTemplates(): Promise<TemplateInfo[]> {
    return (await invokeTauri('api_list_templates')) as TemplateInfo[];
  },

  /**
   * Auto-select the best template for a transcript. `text` is the full
   * transcript payload; the backend only reads a bounded excerpt.
   * `speakerCount` (distinct identified speakers) and `calendarContext`
   * (F3 owner/attendee/event context) are optional hints that bias the
   * classifier toward call types like 1:1s that a transcript excerpt alone
   * may not signal clearly.
   */
  async suggestTemplate(
    text: string,
    speakerCount?: number,
    calendarContext?: string,
  ): Promise<TemplateSuggestion> {
    return (await invokeTauri('api_suggest_template', {
      text,
      speakerCount: speakerCount ?? null,
      calendarContext: calendarContext ?? null,
    })) as TemplateSuggestion;
  },

  /**
   * The template id a meeting's summary was generated with, so the picker can
   * restore it on reopen instead of defaulting to `standard_meeting`. Returns
   * `null` when the meeting has no summary yet. Backfills legacy meetings from
   * the summary cache blob on the backend.
   */
  async getMeetingTemplate(meetingId: string): Promise<string | null> {
    return (await invokeTauri('api_get_meeting_template', {
      meetingId,
    })) as string | null;
  },
};
