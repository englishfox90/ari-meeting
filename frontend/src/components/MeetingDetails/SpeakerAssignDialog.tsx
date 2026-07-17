'use client';

import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog';
import {
  Command,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
} from '@/components/ui/command';
import { cn } from '@/lib/utils';
import {
  speakerService,
  type MeetingSpeaker,
  type SpeakerMatchSuggestion,
} from '@/services/speakerService';
import { personService } from '@/services/personService';
import type { PersonSummary } from '@/types/person';
import type { SpeakerSample } from '@/lib/speaker-samples';
import { SpeakerSampleList } from './SpeakerSampleList';
import { VoiceprintGlyph } from './VoiceprintGlyph';

const STATE_LABEL: Record<MeetingSpeaker['enrollmentState'], string> = {
  provisional: 'Provisional — not yet confirmed',
  confirmed: 'Confirmed',
  owner: 'Owner (you)',
};

export interface SpeakerAssignDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  /** The speaker being reviewed (null closes the dialog cleanly). */
  speaker: MeetingSpeaker | null;
  /** Resolved display name for the speaker (personName ?? label ?? "Speaker N"). */
  speakerDisplayName: string;
  /** All known persons, selectable in the picker. */
  persons: PersonSummary[];
  /** Ids of persons linked to this meeting — surfaced first in the picker. */
  participantIds: Set<string>;
  /** Called after a successful assignment so the caller can refetch. */
  onAssigned: () => Promise<void> | void;
  /** Representative lines this speaker said — the evidence to read/hear. */
  samples?: SpeakerSample[];
  /** Whether a playable recording exists (drives honest disabled play buttons). */
  audioAvailable?: boolean;
  /** Whether the shared meeting player is currently playing. */
  isPlaying?: boolean;
  /** Seek the meeting audio to `seconds` and play (hear the voice). */
  onPlayClip?: (seconds: number) => void;
  /**
   * personId → how many OTHER speakers in this meeting are already assigned to
   * that person. Surfaces accidental repeats (picking the same name for every
   * speaker) directly in the picker, without hard-blocking legitimate reuse.
   */
  assignedByPerson?: Map<string, number>;
}

/**
 * Confirm-before-enroll assignment surface for one diarized speaker. Shows who
 * the speaker is (honest enrollment state), the EVIDENCE to identify them
 * (sample lines you can read + play to hear the voice), REAL ranked match
 * suggestions (never invented scores), a searchable person picker (meeting
 * participants first), and an inline "create new person" path. Nothing
 * auto-assigns — the user always chooses.
 */
export function SpeakerAssignDialog({
  open,
  onOpenChange,
  speaker,
  speakerDisplayName,
  persons,
  participantIds,
  onAssigned,
  samples = [],
  audioAvailable = false,
  isPlaying = false,
  onPlayClip,
  assignedByPerson,
}: SpeakerAssignDialogProps) {
  const [suggestions, setSuggestions] = useState<SpeakerMatchSuggestion[]>([]);
  const [suggestionsLoading, setSuggestionsLoading] = useState(false);
  const [suggestionsError, setSuggestionsError] = useState<string | null>(null);
  const [assigningPersonId, setAssigningPersonId] = useState<string | null>(null);
  const [assignError, setAssignError] = useState<string | null>(null);
  const [query, setQuery] = useState('');
  const [creating, setCreating] = useState(false);

  const speakerId = speaker?.speakerId ?? null;
  const busy = assigningPersonId !== null || creating;

  // Fetch real match suggestions whenever the dialog opens for a speaker.
  useEffect(() => {
    if (!open || !speakerId || !speakerService.isAvailable()) {
      setSuggestions([]);
      setSuggestionsError(null);
      return;
    }
    let cancelled = false;
    setSuggestionsLoading(true);
    setSuggestionsError(null);
    speakerService
      .matchSuggestions(speakerId)
      .then((result) => {
        if (!cancelled) setSuggestions(result);
      })
      .catch((reason) => {
        if (!cancelled) {
          setSuggestions([]);
          setSuggestionsError(reason instanceof Error ? reason.message : String(reason));
        }
      })
      .finally(() => {
        if (!cancelled) setSuggestionsLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [open, speakerId]);

  // Reset transient assignment state when switching speakers / closing.
  useEffect(() => {
    setAssignError(null);
    setAssigningPersonId(null);
    setCreating(false);
    setQuery('');
  }, [speakerId, open]);

  // Persons sorted with this meeting's participants first, then by name.
  const sortedPersons = useMemo(() => {
    return [...persons].sort((a, b) => {
      const aIn = participantIds.has(a.id) ? 0 : 1;
      const bIn = participantIds.has(b.id) ? 0 : 1;
      if (aIn !== bIn) return aIn - bIn;
      return a.displayName.localeCompare(b.displayName);
    });
  }, [persons, participantIds]);

  const participants = useMemo(
    () => sortedPersons.filter((p) => participantIds.has(p.id)),
    [sortedPersons, participantIds],
  );
  const others = useMemo(
    () => sortedPersons.filter((p) => !participantIds.has(p.id)),
    [sortedPersons, participantIds],
  );

  const assign = useCallback(
    async (personId: string) => {
      if (!speakerId) return;
      setAssigningPersonId(personId);
      setAssignError(null);
      try {
        await speakerService.assignToPerson(speakerId, personId);
        await onAssigned();
        onOpenChange(false);
      } catch (reason) {
        setAssignError(reason instanceof Error ? reason.message : String(reason));
      } finally {
        setAssigningPersonId(null);
      }
    },
    [speakerId, onAssigned, onOpenChange],
  );

  // Create a brand-new person from the typed query, then assign this speaker to
  // them. Common when the speaker isn't in the People list yet.
  const createAndAssign = useCallback(
    async (name: string) => {
      const trimmed = name.trim();
      if (!speakerId || !trimmed || !personService.isAvailable()) return;
      setCreating(true);
      setAssignError(null);
      try {
        const person = await personService.upsert({ displayName: trimmed });
        await speakerService.assignToPerson(speakerId, person.id);
        await onAssigned();
        onOpenChange(false);
      } catch (reason) {
        setAssignError(reason instanceof Error ? reason.message : String(reason));
      } finally {
        setCreating(false);
      }
    },
    [speakerId, onAssigned, onOpenChange],
  );

  const personName = (id: string) =>
    persons.find((p) => p.id === id)?.displayName ?? 'Unknown person';

  const canCreate = personService.isAvailable() && query.trim().length > 0;

  // One picker row, annotated when the person is already tagged to other
  // speaker(s) in this meeting — the guard against picking the same name twice.
  const renderPersonItem = (p: PersonSummary) => {
    const already = assignedByPerson?.get(p.id) ?? 0;
    return (
      <CommandItem key={p.id} value={p.displayName} onSelect={() => assign(p.id)} disabled={busy}>
        <span className="truncate">{p.displayName}</span>
        {already > 0 && (
          <span className="ml-auto flex-shrink-0 pl-2 text-[0.625rem] italic text-muted-foreground">
            {already === 1 ? 'already a speaker here' : `already ${already} speakers here`}
          </span>
        )}
      </CommandItem>
    );
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-md gap-0 p-0">
        <DialogHeader className="border-b border-border px-5 py-4">
          <div className="flex items-start gap-3">
            {speaker && (
              <VoiceprintGlyph
                speakerId={speaker.speakerId}
                state={speaker.enrollmentState}
                size={40}
                className="mt-0.5"
                title={`${speakerDisplayName} — voiceprint`}
              />
            )}
            <div className="min-w-0">
              <DialogTitle className="text-base">Review speaker</DialogTitle>
              <DialogDescription className="text-xs">
                {speaker
                  ? `${speakerDisplayName} · ${STATE_LABEL[speaker.enrollmentState]} · ${speaker.segmentCount} segment${speaker.segmentCount === 1 ? '' : 's'}`
                  : 'No speaker selected.'}
              </DialogDescription>
            </div>
          </div>
        </DialogHeader>

        {speaker && (
          <div className="max-h-[70vh] overflow-y-auto">
            {/* Current assignment — honest, no fake name. */}
            <div className="px-5 py-3 text-xs">
              <p className="app-eyebrow">Current</p>
              <p className="mt-1 text-foreground">
                {speaker.personId
                  ? `Assigned to ${speaker.personName ?? personName(speaker.personId)}`
                  : 'Unassigned'}
              </p>
            </div>

            {/* Evidence — read the words, play the clip, recognise the voice. */}
            <div className="border-t border-border px-5 py-3">
              <div className="flex items-center justify-between gap-2">
                <p className="app-eyebrow">Sample lines</p>
                {!audioAvailable && (
                  <span className="text-[0.625rem] text-muted-foreground">
                    No audio to play
                  </span>
                )}
              </div>
              <div className="mt-2">
                <SpeakerSampleList
                  samples={samples}
                  audioAvailable={audioAvailable}
                  isPlaying={isPlaying}
                  onPlayClip={(s) => onPlayClip?.(s)}
                />
              </div>
            </div>

            {/* Real match suggestions — never invented. */}
            <div className="border-t border-border px-5 py-3">
              <p className="app-eyebrow">Suggestions</p>
              {suggestionsLoading ? (
                <p className="mt-2 text-xs text-muted-foreground">Comparing voice…</p>
              ) : suggestionsError ? (
                <p className="mt-2 text-xs text-destructive">{suggestionsError}</p>
              ) : suggestions.length === 0 ? (
                <p className="mt-2 text-xs text-muted-foreground">
                  No close matches — pick a person below.
                </p>
              ) : (
                <ul className="mt-2 space-y-1.5">
                  {suggestions.map((s) => (
                    <li key={s.personId}>
                      <button
                        type="button"
                        disabled={busy}
                        onClick={() => assign(s.personId)}
                        className={cn(
                          'flex w-full items-center justify-between gap-2 rounded-md border border-border bg-secondary px-3 py-2 text-left text-sm transition-colors hover:bg-secondary/70 disabled:opacity-50',
                        )}
                      >
                        <span className="truncate text-foreground">
                          Looks like {s.personName}
                        </span>
                        <span className="flex-shrink-0 font-mono text-xs text-muted-foreground">
                          {s.score.toFixed(2)}
                        </span>
                      </button>
                    </li>
                  ))}
                </ul>
              )}
            </div>

            {/* Manual person picker — participants first, create-new inline. */}
            <div className="border-t border-border px-5 py-3">
              <p className="app-eyebrow mb-2">Assign to person</p>
              <Command className="rounded-md border border-border bg-card">
                <CommandInput
                  placeholder="Search or name a new person…"
                  value={query}
                  onValueChange={setQuery}
                />
                <CommandList>
                  <CommandEmpty>
                    {canCreate ? (
                      <button
                        type="button"
                        disabled={busy}
                        onClick={() => createAndAssign(query)}
                        className="mx-1 flex w-[calc(100%-0.5rem)] items-center gap-2 rounded-md px-2 py-2 text-left text-sm text-foreground hover:bg-secondary disabled:opacity-50"
                      >
                        {creating ? 'Creating…' : (
                          <>Create <span className="font-medium">&ldquo;{query.trim()}&rdquo;</span> as a new person</>
                        )}
                      </button>
                    ) : (
                      <span className="px-2 text-xs text-muted-foreground">
                        Type a name to create a new person.
                      </span>
                    )}
                  </CommandEmpty>
                  {participants.length > 0 && (
                    <CommandGroup heading="In this meeting">
                      {participants.map(renderPersonItem)}
                    </CommandGroup>
                  )}
                  {others.length > 0 && (
                    <CommandGroup heading="Everyone else">
                      {others.map(renderPersonItem)}
                    </CommandGroup>
                  )}
                </CommandList>
              </Command>
              {assignError && (
                <p className="mt-2 text-xs text-destructive">{assignError}</p>
              )}
            </div>
          </div>
        )}
      </DialogContent>
    </Dialog>
  );
}
