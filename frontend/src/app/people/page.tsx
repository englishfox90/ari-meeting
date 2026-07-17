'use client';

import { useCallback, useEffect, useState, useSyncExternalStore } from 'react';
import { useRouter } from 'next/navigation';
import { AppState } from '@/components/app-shell/AppState';
import { PageHeader } from '@/components/app-shell/PageHeader';
import { Surface } from '@/components/app-shell/Surface';
import { MeetilyGlyph } from '@/components/app-shell/MeetilyGlyph';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogFooter, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { Textarea } from '@/components/ui/textarea';
import { Label } from '@/components/ui/label';
import { VisuallyHidden } from '@/components/ui/visually-hidden';
import { cn } from '@/lib/utils';
import { personService } from '@/services/personService';
import { voiceprintService } from '@/services/voiceprintService';
import { VoiceprintGlyph } from '@/components/MeetingDetails/VoiceprintGlyph';
import type { NewPerson, Person, PersonSummary, ProfileFactWithPerson } from '@/types/person';

/**
 * A small voice ring for a People-list row, shown only when the person has a
 * real enrolled voiceprint (No-Fake-State — nothing otherwise). Subscribes to
 * the shared voiceprint cache warmed by `fetchAllPersonSignatures`.
 */
function PersonRowGlyph({ personId }: { personId: string }) {
  const subscribe = useCallback(
    (onChange: () => void) => voiceprintService.subscribe(onChange),
    [],
  );
  const getSnapshot = useCallback(
    () => voiceprintService.getPersonSignature(personId),
    [personId],
  );
  const values = useSyncExternalStore(subscribe, getSnapshot, () => undefined);
  if (!values) return null;
  return <VoiceprintGlyph personId={personId} size={28} />;
}

// Tauri rejects an `invoke` with the command's `Err(String)` as a plain string;
// surface it verbatim so backend failures are diagnosable from the UI.
function errorText(error: unknown): string {
  if (typeof error === 'string') return error;
  if (error instanceof Error) return error.message;
  return JSON.stringify(error);
}

interface OwnerFormState {
  displayName: string;
  email: string;
  role: string;
  organization: string;
  domain: string;
  notes: string;
}

const emptyOwnerForm: OwnerFormState = {
  displayName: '',
  email: '',
  role: '',
  organization: '',
  domain: '',
  notes: '',
};

function ownerToForm(owner: Person | null): OwnerFormState {
  if (!owner) return emptyOwnerForm;
  return {
    displayName: owner.displayName,
    email: owner.email ?? '',
    role: owner.role ?? '',
    organization: owner.organization ?? '',
    domain: owner.domain ?? '',
    notes: owner.notes ?? '',
  };
}

export default function PeoplePage() {
  const router = useRouter();
  const [available] = useState(() => personService.isAvailable());

  const [owner, setOwner] = useState<Person | null>(null);
  const [ownerLoading, setOwnerLoading] = useState(true);
  const [ownerError, setOwnerError] = useState<string | null>(null);
  const [ownerDialogOpen, setOwnerDialogOpen] = useState(false);
  const [ownerForm, setOwnerForm] = useState<OwnerFormState>(emptyOwnerForm);
  const [savingOwner, setSavingOwner] = useState(false);

  const [people, setPeople] = useState<PersonSummary[] | null>(null);
  const [peopleError, setPeopleError] = useState<string | null>(null);
  const [peopleLoading, setPeopleLoading] = useState(true);

  const [pendingFacts, setPendingFacts] = useState<ProfileFactWithPerson[] | null>(null);
  const [pendingOpen, setPendingOpen] = useState(false);

  const loadOwner = useCallback(async () => {
    setOwnerLoading(true);
    setOwnerError(null);
    try {
      const result = await personService.getOwner();
      setOwner(result);
    } catch (error) {
      console.error('Failed to load owner profile:', error);
      setOwner(null);
      setOwnerError('Ari Meeting could not read your owner profile.');
    } finally {
      setOwnerLoading(false);
    }
  }, []);

  const loadPeople = useCallback(async () => {
    setPeopleLoading(true);
    setPeopleError(null);
    try {
      const results = await personService.list();
      setPeople(results.filter((person) => !person.isOwner));
    } catch (error) {
      console.error('Failed to load people:', error);
      setPeople(null);
      setPeopleError('Ari Meeting could not read your saved people.');
    } finally {
      setPeopleLoading(false);
    }
  }, []);

  const loadPendingFacts = useCallback(async () => {
    try {
      const results = await personService.pendingFacts();
      setPendingFacts(results);
    } catch (error) {
      console.error('Failed to load pending facts:', error);
      setPendingFacts(null);
    }
  }, []);

  useEffect(() => {
    if (!available) return;
    void loadOwner();
    void loadPeople();
    void loadPendingFacts();
    // Warm every enrolled person's voice ring for the list in one call.
    void voiceprintService.fetchAllPersonSignatures();
  }, [available, loadOwner, loadPeople, loadPendingFacts]);

  const openOwnerDialog = async () => {
    const base = ownerToForm(owner);
    setOwnerForm(base);
    setOwnerDialogOpen(true);
    // Organization is a global config, not a per-person field — load it separately.
    try {
      const config = await personService.getAppConfig();
      setOwnerForm((f) => ({ ...f, organization: config.organization }));
    } catch (error) {
      console.error('Failed to load organization config:', error);
    }
  };

  const saveOwner = async () => {
    const displayName = ownerForm.displayName.trim();
    if (!displayName) return;

    setSavingOwner(true);
    try {
      const payload: NewPerson = {
        id: owner?.id ?? null,
        displayName,
        email: ownerForm.email.trim() || null,
        role: ownerForm.role.trim() || null,
        domain: ownerForm.domain.trim() || null,
        notes: ownerForm.notes.trim() || null,
      };
      // Organization is global — persist it to app config, not the person record.
      await personService.setOrganization(ownerForm.organization.trim());
      const saved = await personService.setOwner(payload);
      setOwner(saved);
      setOwnerDialogOpen(false);
    } catch (error) {
      console.error('Failed to save owner profile:', error);
      setOwnerError(`Could not save your owner profile: ${errorText(error)}`);
    } finally {
      setSavingOwner(false);
    }
  };

  const confirmFact = async (factId: string) => {
    try {
      await personService.confirmFact(factId);
      await Promise.all([loadPendingFacts(), loadPeople()]);
    } catch (error) {
      console.error('Failed to confirm fact:', error);
    }
  };

  const rejectFact = async (factId: string) => {
    try {
      await personService.rejectFact(factId);
      await Promise.all([loadPendingFacts(), loadPeople()]);
    } catch (error) {
      console.error('Failed to reject fact:', error);
    }
  };

  if (!available) {
    return (
      <div className="app-page">
        <PageHeader eyebrow="People" title="People" description="Persistent profiles for the people you meet with." />
        <div className="mt-7">
          <AppState
            kind="disabled"
            title="People is available in the desktop app"
            description="Run Ari Meeting as a desktop app to read and manage person profiles."
          />
        </div>
      </div>
    );
  }

  const pendingCount = pendingFacts?.length ?? 0;

  return (
    <div className="app-page">
      <PageHeader
        eyebrow="People"
        title="People"
        description="Profiles built from calendar attendees and meeting facts — nothing is inferred without a source."
      />

      <section aria-label="Owner profile" className="mt-7">
        {ownerLoading ? (
          <AppState kind="loading" title="Loading your profile" description="Reading your owner profile from the local database." compact />
        ) : ownerError ? (
          <AppState kind="error" title="Owner profile could not be loaded" description={ownerError} compact action={<Button variant="outline" size="sm" onClick={() => void loadOwner()}>Try again</Button>} />
        ) : (
          <Surface className="p-4">
            <div className="flex flex-wrap items-start justify-between gap-4">
              <div className="flex min-w-0 items-start gap-3">
                <span className="grid size-10 shrink-0 place-items-center rounded-md bg-secondary text-muted-foreground">
                  <MeetilyGlyph name="people" className="size-5" />
                </span>
                <div className="min-w-0">
                  <p className="app-eyebrow">You</p>
                  {owner ? (
                    <>
                      <h2 className="mt-1 truncate text-sm font-semibold tracking-[-0.01em]">{owner.displayName}</h2>
                      <p className="mt-0.5 text-xs text-muted-foreground">
                        {owner.role || 'No role set yet'}
                      </p>
                    </>
                  ) : (
                    <>
                      <h2 className="mt-1 text-sm font-semibold tracking-[-0.01em]">No owner profile yet</h2>
                      <p className="mt-0.5 text-xs text-muted-foreground">
                        Set up your profile so summaries can be written with you in mind.
                      </p>
                    </>
                  )}
                </div>
              </div>
              <Button variant="outline" size="sm" onClick={openOwnerDialog}>
                {owner ? 'Edit owner profile' : 'Set up profile'}
              </Button>
            </div>
          </Surface>
        )}
      </section>

      {pendingCount > 0 && (
        <section aria-label="Pending facts" className="mt-4">
          <Surface className="p-0 overflow-hidden">
            <button
              type="button"
              onClick={() => setPendingOpen((open) => !open)}
              className="flex w-full items-center justify-between gap-3 px-4 py-3 text-left"
            >
              <span className="flex items-center gap-2 text-sm font-medium">
                <span className="grid size-6 place-items-center rounded-full bg-accent text-[0.6875rem] font-semibold text-accent-foreground">
                  {pendingCount}
                </span>
                Review pending {pendingCount === 1 ? 'fact' : 'facts'}
              </span>
              <MeetilyGlyph name={pendingOpen ? 'chevron-left' : 'chevron-right'} className="size-4 -rotate-90 text-muted-foreground" />
            </button>
            {pendingOpen && (
              <div className="divide-y divide-border/70 border-t border-border/70">
                {pendingFacts!.map((item) => (
                  <div key={item.fact.id} className="flex flex-wrap items-start justify-between gap-3 px-4 py-3">
                    <div className="min-w-0">
                      <button
                        type="button"
                        onClick={() => router.push(`/person-details?id=${item.personId}`)}
                        className="text-xs font-semibold text-foreground underline-offset-2 hover:underline"
                      >
                        {item.personDisplayName}
                      </button>
                      <p className="mt-0.5 text-sm leading-5">{item.fact.factText}</p>
                      {item.fact.sourceMeetingTitle && (
                        <p className="mt-0.5 text-xs text-muted-foreground">From {item.fact.sourceMeetingTitle}</p>
                      )}
                    </div>
                    <div className="flex shrink-0 gap-2">
                      <Button size="sm" variant="outline" onClick={() => void rejectFact(item.fact.id)}>Reject</Button>
                      <Button size="sm" onClick={() => void confirmFact(item.fact.id)}>Confirm</Button>
                    </div>
                  </div>
                ))}
              </div>
            )}
          </Surface>
        </section>
      )}

      <section aria-label="People" className="mt-6">
        {peopleLoading ? (
          <AppState kind="loading" title="Loading people" description="Reading saved person profiles from the local database." />
        ) : peopleError ? (
          <AppState kind="error" title="People could not be loaded" description={peopleError} action={<Button variant="outline" onClick={() => void loadPeople()}>Try again</Button>} />
        ) : !people || people.length === 0 ? (
          <AppState
            kind="empty"
            title="No people yet"
            description="They'll appear here as you sync calendar events and link meetings."
          />
        ) : (
          <Surface className="divide-y divide-border/70 overflow-hidden p-0">
            {people.map((person) => (
              <button
                key={person.id}
                type="button"
                onClick={() => router.push(`/person-details?id=${person.id}`)}
                className="flex w-full items-center justify-between gap-4 px-5 py-4 text-left transition-colors hover:bg-secondary/60"
              >
                <div className="flex min-w-0 items-center gap-3">
                  <PersonRowGlyph personId={person.id} />
                  <div className="min-w-0">
                    <p className="truncate text-sm font-semibold tracking-[-0.01em]">{person.displayName}</p>
                    <p className="mt-0.5 truncate text-xs text-muted-foreground">
                      {person.role || person.email || 'No details yet'}
                    </p>
                  </div>
                </div>
                <div className="flex shrink-0 items-center gap-2">
                  {person.pendingFactCount > 0 && (
                    <span className="rounded-full bg-accent/15 px-2 py-0.5 text-xs font-medium text-accent-foreground">
                      {person.pendingFactCount} pending
                    </span>
                  )}
                  {person.activeFactCount > 0 && (
                    <span className={cn('rounded-full bg-secondary px-2 py-0.5 text-xs font-medium text-secondary-foreground')}>
                      {person.activeFactCount} {person.activeFactCount === 1 ? 'fact' : 'facts'}
                    </span>
                  )}
                  <MeetilyGlyph name="chevron-right" className="size-4 text-muted-foreground" />
                </div>
              </button>
            ))}
          </Surface>
        )}
      </section>

      <Dialog open={ownerDialogOpen} onOpenChange={setOwnerDialogOpen}>
        <DialogContent className="sm:max-w-[30rem]">
          <VisuallyHidden><DialogTitle>Edit owner profile</DialogTitle></VisuallyHidden>
          <div className="space-y-3 py-2">
            <h2 className="text-sm font-semibold tracking-[-0.01em]">Your profile</h2>
            <div>
              <Label htmlFor="owner-name">Name</Label>
              <Input id="owner-name" className="mt-1" value={ownerForm.displayName} onChange={(e) => setOwnerForm((f) => ({ ...f, displayName: e.target.value }))} />
            </div>
            <div>
              <Label htmlFor="owner-email">Email</Label>
              <Input id="owner-email" className="mt-1" value={ownerForm.email} onChange={(e) => setOwnerForm((f) => ({ ...f, email: e.target.value }))} />
            </div>
            <div className="grid grid-cols-2 gap-3">
              <div>
                <Label htmlFor="owner-role">Role</Label>
                <Input id="owner-role" className="mt-1" value={ownerForm.role} onChange={(e) => setOwnerForm((f) => ({ ...f, role: e.target.value }))} />
              </div>
              <div>
                <Label htmlFor="owner-org">Organization</Label>
                <Input id="owner-org" className="mt-1" value={ownerForm.organization} onChange={(e) => setOwnerForm((f) => ({ ...f, organization: e.target.value }))} />
                <p className="mt-1 text-xs text-muted-foreground">Applies to everyone — this is a workspace-wide setting.</p>
              </div>
            </div>
            <div>
              <Label htmlFor="owner-domain">Domain / focus</Label>
              <Input id="owner-domain" className="mt-1" value={ownerForm.domain} onChange={(e) => setOwnerForm((f) => ({ ...f, domain: e.target.value }))} />
            </div>
            <div>
              <Label htmlFor="owner-notes">Notes</Label>
              <Textarea id="owner-notes" className="mt-1" value={ownerForm.notes} onChange={(e) => setOwnerForm((f) => ({ ...f, notes: e.target.value }))} />
            </div>
          </div>
          <DialogFooter>
            <button type="button" onClick={() => setOwnerDialogOpen(false)} className="min-h-10 rounded-lg px-4 text-sm font-medium text-muted-foreground hover:bg-secondary hover:text-foreground">Cancel</button>
            <Button onClick={() => void saveOwner()} disabled={savingOwner || !ownerForm.displayName.trim()}>
              {savingOwner ? 'Saving…' : 'Save'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
