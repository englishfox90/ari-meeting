'use client';

import { Suspense, useCallback, useEffect, useState, useSyncExternalStore } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { AppState } from '@/components/app-shell/AppState';
import { PageHeader } from '@/components/app-shell/PageHeader';
import { Surface } from '@/components/app-shell/Surface';
import { MeetilyGlyph } from '@/components/app-shell/MeetilyGlyph';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Textarea } from '@/components/ui/textarea';
import { Label } from '@/components/ui/label';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { cn } from '@/lib/utils';
import { personService } from '@/services/personService';
import { voiceprintService } from '@/services/voiceprintService';
import { VoiceprintGlyph } from '@/components/MeetingDetails/VoiceprintGlyph';
import type { FactKind, FactSourceRelation, NewPerson, PersonDetail, ProfileFact, ProfileFactSource } from '@/types/person';

// Tauri rejects an `invoke` with the command's `Err(String)` as a plain string;
// surface it verbatim so backend failures are diagnosable from the UI.
function errorText(error: unknown): string {
  if (typeof error === 'string') return error;
  if (error instanceof Error) return error.message;
  return JSON.stringify(error);
}

/**
 * Read a person's cached canonical voiceprint signature, re-rendering when the
 * shared cache warms. `undefined` = no enrolled voiceprint (→ render nothing).
 */
function usePersonVoiceprint(personId: string | null): number[] | undefined {
  const subscribe = useCallback(
    (onChange: () => void) => voiceprintService.subscribe(onChange),
    [],
  );
  const getSnapshot = useCallback(
    () => (personId ? voiceprintService.getPersonSignature(personId) : undefined),
    [personId],
  );
  return useSyncExternalStore(subscribe, getSnapshot, () => undefined);
}

const FACT_KINDS: { value: FactKind; label: string }[] = [
  { value: 'goal', label: 'Goal' },
  { value: 'interest', label: 'Interest' },
  { value: 'project', label: 'Project' },
  { value: 'role_signal', label: 'Role signal' },
  { value: 'other', label: 'Other' },
];

function factKindLabel(kind: string): string {
  return FACT_KINDS.find((k) => k.value === kind)?.label ?? kind;
}

interface IdentityFormState {
  displayName: string;
  email: string;
  role: string;
  domain: string;
  notes: string;
}

const emptyIdentityForm: IdentityFormState = {
  displayName: '',
  email: '',
  role: '',
  domain: '',
  notes: '',
};

function detailToForm(detail: PersonDetail | null): IdentityFormState {
  if (!detail) return emptyIdentityForm;
  const { person } = detail;
  return {
    displayName: person.displayName,
    email: person.email ?? '',
    role: person.role ?? '',
    domain: person.domain ?? '',
    notes: person.notes ?? '',
  };
}

function PersonDetailsContent() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const personId = searchParams.get('id');
  const [available] = useState(() => personService.isAvailable());
  const voiceprint = usePersonVoiceprint(personId);

  const [detail, setDetail] = useState<PersonDetail | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);

  const [form, setForm] = useState<IdentityFormState>(emptyIdentityForm);
  const [isSaving, setIsSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);

  const [manualFactText, setManualFactText] = useState('');
  const [manualFactKind, setManualFactKind] = useState<FactKind>('other');
  const [isAddingFact, setIsAddingFact] = useState(false);
  const [factActionId, setFactActionId] = useState<string | null>(null);
  const [needsReview, setNeedsReview] = useState<ProfileFact[]>([]);

  const load = useCallback(async () => {
    if (!personId) return;
    setIsLoading(true);
    setLoadError(null);
    try {
      const result = await personService.get(personId);
      setDetail(result);
      setForm(detailToForm(result));
      // Stale active facts that haven't been reaffirmed in a while (F2 decay). Best-effort:
      // a failure here must never block the profile from loading.
      try {
        setNeedsReview(await personService.factsNeedingReview(personId));
      } catch (reviewError) {
        console.warn('Failed to load facts needing review (non-blocking):', reviewError);
        setNeedsReview([]);
      }
    } catch (error) {
      console.error('Failed to load person:', error);
      setDetail(null);
      setLoadError('Ari Meeting could not read this person profile.');
    } finally {
      setIsLoading(false);
    }
  }, [personId]);

  useEffect(() => {
    if (!available || !personId) return;
    void load();
    // Warm the person's canonical voiceprint signature for the header ring.
    void voiceprintService.fetchPersonSignature(personId);
  }, [available, personId, load]);

  const saveIdentity = async () => {
    if (!personId) return;
    const displayName = form.displayName.trim();
    if (!displayName) return;

    setIsSaving(true);
    setSaveError(null);
    try {
      const payload: NewPerson = {
        id: personId,
        displayName,
        email: form.email.trim() || null,
        role: form.role.trim() || null,
        domain: form.domain.trim() || null,
        notes: form.notes.trim() || null,
      };
      await personService.upsert(payload);
      await load();
    } catch (error) {
      console.error('Failed to save person:', error);
      setSaveError(`Could not save changes: ${errorText(error)}`);
    } finally {
      setIsSaving(false);
    }
  };

  const addManualFact = async () => {
    if (!personId) return;
    const text = manualFactText.trim();
    if (!text) return;

    setIsAddingFact(true);
    try {
      await personService.addManualFact(personId, text, manualFactKind);
      setManualFactText('');
      setManualFactKind('other');
      await load();
    } catch (error) {
      console.error('Failed to add manual fact:', error);
    } finally {
      setIsAddingFact(false);
    }
  };

  const confirmFact = async (factId: string) => {
    setFactActionId(factId);
    try {
      await personService.confirmFact(factId);
      await load();
    } catch (error) {
      console.error('Failed to confirm fact:', error);
    } finally {
      setFactActionId(null);
    }
  };

  const rejectFact = async (factId: string) => {
    setFactActionId(factId);
    try {
      await personService.rejectFact(factId);
      await load();
    } catch (error) {
      console.error('Failed to reject fact:', error);
    } finally {
      setFactActionId(null);
    }
  };

  if (!available) {
    return (
      <div className="app-page">
        <PageHeader eyebrow="Person" title="Person" />
        <div className="mt-7">
          <AppState
            kind="disabled"
            title="Person profiles are available in the desktop app"
            description="Run Ari Meeting as a desktop app to view and edit person profiles."
          />
        </div>
      </div>
    );
  }

  if (!personId) {
    return (
      <div className="app-page">
        <h1 className="sr-only">Person unavailable</h1>
        <AppState
          kind="error"
          title="No person selected"
          description="Open a person from the People list."
          action={<Button variant="outline" onClick={() => router.push('/people')}>Back to People</Button>}
        />
      </div>
    );
  }

  if (isLoading) {
    return (
      <div className="app-page">
        <h1 className="sr-only">Loading person</h1>
        <AppState kind="loading" title="Opening person profile" description="Loading the saved profile and facts from this device." />
      </div>
    );
  }

  if (loadError || !detail) {
    return (
      <div className="app-page">
        <h1 className="sr-only">Person unavailable</h1>
        <AppState
          kind="error"
          title="Profile could not be opened"
          description={loadError ?? 'This person could not be found.'}
          action={<Button variant="outline" onClick={() => router.push('/people')}>Back to People</Button>}
        />
      </div>
    );
  }

  // Stale ACTIVE facts (F2 decay). Pending stale facts are already actionable in the
  // "Pending confirmation" section, so surface only the active ones here — and pull them
  // out of the plain "Active facts" list so each fact appears exactly once.
  const reviewIds = new Set(
    needsReview.filter((fact) => fact.status === 'active').map((fact) => fact.id),
  );
  const staleReviewFacts = detail.facts.filter((fact) => fact.status === 'active' && reviewIds.has(fact.id));
  const pendingFacts = detail.facts.filter((fact) => fact.status === 'pending');
  const activeFacts = detail.facts.filter((fact) => fact.status === 'active' && !reviewIds.has(fact.id));
  const otherFacts = detail.facts.filter((fact) => fact.status !== 'pending' && fact.status !== 'active');

  return (
    <div className="app-page">
      <PageHeader
        eyebrow={detail.person.isOwner ? 'You' : 'Person'}
        title={detail.person.displayName}
        description={
          detail.meetingCount > 0
            ? `Linked to ${detail.meetingCount} ${detail.meetingCount === 1 ? 'meeting' : 'meetings'}.`
            : 'Not yet linked to any meetings.'
        }
        leading={
          // A large "voice ring" of this person's enrolled voiceprint. Rendered
          // only when a real signature exists (No-Fake-State — never a placeholder).
          voiceprint ? (
            <VoiceprintGlyph
              personId={personId}
              size={120}
              title={`${detail.person.displayName}'s voiceprint`}
            />
          ) : undefined
        }
        actions={<Button variant="outline" onClick={() => router.push('/people')}>Back to People</Button>}
      />

      {!voiceprint && (
        <p className="mt-3 text-xs text-muted-foreground">
          No voiceprint yet — assign them in a meeting&apos;s Review speakers to enroll their voice.
        </p>
      )}

      <div className="mt-7 grid gap-6 lg:grid-cols-[22rem_1fr]">
        <section aria-label="Authored identity">
          <Surface className="p-4">
            <h2 className="text-sm font-semibold tracking-[-0.01em]">Identity</h2>
            <p className="mt-0.5 text-xs text-muted-foreground">What you know and have authored about this person.</p>

            {saveError && <p className="mt-3 text-xs text-destructive" role="alert">{saveError}</p>}

            <div className="mt-4 space-y-3">
              <div>
                <Label htmlFor="pd-name">Name</Label>
                <Input id="pd-name" className="mt-1" value={form.displayName} onChange={(e) => setForm((f) => ({ ...f, displayName: e.target.value }))} />
              </div>
              <div>
                <Label htmlFor="pd-email">Email</Label>
                <Input id="pd-email" className="mt-1" value={form.email} onChange={(e) => setForm((f) => ({ ...f, email: e.target.value }))} />
              </div>
              <div>
                <Label htmlFor="pd-role">Role</Label>
                <Input id="pd-role" className="mt-1" value={form.role} onChange={(e) => setForm((f) => ({ ...f, role: e.target.value }))} />
              </div>
              <div>
                <Label htmlFor="pd-domain">Domain / focus</Label>
                <Input id="pd-domain" className="mt-1" value={form.domain} onChange={(e) => setForm((f) => ({ ...f, domain: e.target.value }))} />
              </div>
              <div>
                <Label htmlFor="pd-notes">Notes</Label>
                <Textarea id="pd-notes" className="mt-1" value={form.notes} onChange={(e) => setForm((f) => ({ ...f, notes: e.target.value }))} />
              </div>
              <Button onClick={() => void saveIdentity()} disabled={isSaving || !form.displayName.trim()} className="w-full">
                {isSaving ? 'Saving…' : 'Save identity'}
              </Button>
            </div>
          </Surface>
        </section>

        <section aria-label="Inferred facts" className="space-y-5">
          {pendingFacts.length > 0 && (
            <div>
              <h3 className="app-eyebrow mb-2 px-1">Pending confirmation</h3>
              <Surface className="divide-y divide-border/70 overflow-hidden p-0">
                {pendingFacts.map((fact) => (
                  <FactRow
                    key={fact.id}
                    fact={fact}
                    actionsDisabled={factActionId === fact.id}
                    onConfirm={() => void confirmFact(fact.id)}
                    onReject={() => void rejectFact(fact.id)}
                  />
                ))}
              </Surface>
            </div>
          )}

          {staleReviewFacts.length > 0 && (
            <div>
              <h3 className="app-eyebrow mb-2 px-1">Needs review</h3>
              <p className="mb-2 px-1 text-xs text-muted-foreground">
                Confirmed facts you haven&apos;t reaffirmed in over four weeks. Reaffirm the ones
                still true, or dismiss the ones that have gone stale.
              </p>
              <Surface className="divide-y divide-border/70 overflow-hidden p-0">
                {staleReviewFacts.map((fact) => (
                  <FactRow
                    key={fact.id}
                    fact={fact}
                    actionsDisabled={factActionId === fact.id}
                    onConfirm={() => void confirmFact(fact.id)}
                    onReject={() => void rejectFact(fact.id)}
                    confirmLabel="Reaffirm"
                    rejectLabel="Dismiss"
                  />
                ))}
              </Surface>
            </div>
          )}

          <div>
            <h3 className="app-eyebrow mb-2 px-1">Active facts</h3>
            {activeFacts.length === 0 ? (
              <AppState kind="empty" title="No confirmed facts yet" description="Facts extracted from meetings, or added manually, will appear here once confirmed." compact />
            ) : (
              <Surface className="divide-y divide-border/70 overflow-hidden p-0">
                {activeFacts.map((fact) => <FactRow key={fact.id} fact={fact} />)}
              </Surface>
            )}
          </div>

          <div>
            <h3 className="app-eyebrow mb-2 px-1">Add a fact manually</h3>
            <Surface className="p-4">
              <div className="flex flex-col gap-3 sm:flex-row sm:items-start">
                <Textarea
                  value={manualFactText}
                  onChange={(e) => setManualFactText(e.target.value)}
                  placeholder="e.g. Leads the platform migration project"
                  className="min-h-[2.5rem] flex-1"
                />
                <div className="flex shrink-0 gap-2">
                  <Select value={manualFactKind} onValueChange={(value) => setManualFactKind(value as FactKind)}>
                    <SelectTrigger className="w-36"><SelectValue /></SelectTrigger>
                    <SelectContent>
                      {FACT_KINDS.map((kind) => (
                        <SelectItem key={kind.value} value={kind.value}>{kind.label}</SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                  <Button onClick={() => void addManualFact()} disabled={isAddingFact || !manualFactText.trim()}>
                    {isAddingFact ? 'Adding…' : 'Add'}
                  </Button>
                </div>
              </div>
            </Surface>
          </div>

          {otherFacts.length > 0 && (
            <div>
              <h3 className="app-eyebrow mb-2 px-1">Superseded / rejected</h3>
              <Surface className="divide-y divide-border/70 overflow-hidden p-0">
                {otherFacts.map((fact) => <FactRow key={fact.id} fact={fact} />)}
              </Surface>
            </div>
          )}
        </section>
      </div>
    </div>
  );
}

interface FactRowProps {
  fact: ProfileFact;
  actionsDisabled?: boolean;
  onConfirm?: () => void;
  onReject?: () => void;
  confirmLabel?: string;
  rejectLabel?: string;
}

const FACT_SOURCE_RELATION_LABEL: Record<FactSourceRelation, string> = {
  origin: 'first seen',
  reaffirmed: 'reaffirmed',
  carried: 'carried forward',
};

function factSourceMeetingLabel(source: ProfileFactSource): string {
  if (source.meetingTitle && source.meetingTitle.trim().length > 0) {
    return source.meetingTitle;
  }
  return source.meetingId ? 'Untitled meeting' : 'Manual entry';
}

function FactRow({
  fact,
  actionsDisabled,
  onConfirm,
  onReject,
  confirmLabel = 'Confirm',
  rejectLabel = 'Reject',
}: FactRowProps) {
  const [sourcesExpanded, setSourcesExpanded] = useState(false);
  const [sources, setSources] = useState<ProfileFactSource[] | null>(null);
  const [sourcesLoading, setSourcesLoading] = useState(false);

  const toggleSources = useCallback(() => {
    setSourcesExpanded((prev) => {
      const next = !prev;
      if (next && sources === null && !sourcesLoading) {
        setSourcesLoading(true);
        personService
          .factSources(fact.id)
          .then((loaded) => setSources(loaded))
          .catch((error) => {
            console.warn('Failed to load fact sources', error);
            setSources([]);
          })
          .finally(() => setSourcesLoading(false));
      }
      return next;
    });
  }, [fact.id, sources, sourcesLoading]);

  return (
    <div className="flex flex-wrap items-start justify-between gap-3 px-5 py-4">
      <div className="min-w-0 flex-1">
        <div className="flex flex-wrap items-center gap-2">
          <span className="rounded-full bg-secondary px-2 py-0.5 text-xs font-medium text-secondary-foreground">
            {factKindLabel(fact.factKind)}
          </span>
          <span
            className={cn(
              'rounded-full px-2 py-0.5 text-xs font-medium',
              fact.sourceKind === 'self_reported'
                ? 'bg-secondary text-secondary-foreground'
                : 'bg-secondary/60 text-muted-foreground',
            )}
          >
            {fact.sourceKind === 'self_reported' ? 'Self-reported' : 'Attributed'}
          </span>
          {fact.status !== 'active' && (
            <span className="rounded-full bg-secondary/60 px-2 py-0.5 text-xs font-medium text-muted-foreground">
              {fact.status}
            </span>
          )}
        </div>
        <p className="mt-1.5 text-sm leading-5">{fact.factText}</p>
        <div className="mt-1 flex flex-wrap items-center gap-x-3 gap-y-0.5 text-xs text-muted-foreground">
          {fact.sourceMeetingTitle && <span>From {fact.sourceMeetingTitle}</span>}
          <span>Confidence {Math.round(fact.confidence * 100)}%</span>
        </div>
        {fact.sourceCount > 1 && (
          <div className="mt-1.5">
            <button
              type="button"
              onClick={toggleSources}
              className="text-xs font-medium text-muted-foreground underline-offset-2 hover:underline"
            >
              {sourcesExpanded ? 'Hide' : `Seen in ${fact.sourceCount} meetings`}
            </button>
            {sourcesExpanded && (
              <div className="mt-1.5">
                {sourcesLoading && <p className="text-xs text-muted-foreground">Loading sources…</p>}
                {!sourcesLoading && sources && sources.length > 0 && (
                  <ul className="flex flex-col gap-1">
                    {sources.map((source) => (
                      <li
                        key={source.id}
                        className="flex flex-wrap items-center gap-x-2 gap-y-0.5 text-xs text-muted-foreground"
                      >
                        <span className="truncate text-foreground">{factSourceMeetingLabel(source)}</span>
                        <span className="rounded-full bg-secondary/60 px-2 py-0.5 font-medium">
                          {FACT_SOURCE_RELATION_LABEL[source.relation]}
                        </span>
                        <span>{Math.round(source.confidence * 100)}%</span>
                      </li>
                    ))}
                  </ul>
                )}
              </div>
            )}
          </div>
        )}
      </div>
      {(onConfirm || onReject) && (
        <div className="flex shrink-0 gap-2">
          {onReject && (
            <Button size="sm" variant="outline" disabled={actionsDisabled} onClick={onReject}>{rejectLabel}</Button>
          )}
          {onConfirm && (
            <Button size="sm" disabled={actionsDisabled} onClick={onConfirm}>{confirmLabel}</Button>
          )}
        </div>
      )}
    </div>
  );
}

export default function PersonDetailsPage() {
  return (
    <Suspense fallback={
      <div className="app-page">
        <h1 className="sr-only">Loading person</h1>
        <AppState kind="loading" title="Opening person profile" description="Loading local profile data." />
      </div>
    }>
      <PersonDetailsContent />
    </Suspense>
  );
}
