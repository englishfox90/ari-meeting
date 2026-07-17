"use client"
import { useSidebar } from "@/components/Sidebar/SidebarProvider";
import { useState, useEffect, useCallback, useRef, Suspense } from "react";
import { Transcript, Summary } from "@/types";
import PageContent from "./page-content";
import { useRouter, useSearchParams } from "next/navigation";
import Analytics from "@/lib/analytics";
import { invoke } from "@tauri-apps/api/core";
import { useMeetingProcessing } from "@/contexts/MeetingProcessingContext";
import { usePaginatedTranscripts } from "@/hooks/usePaginatedTranscripts";
import { AppState } from "@/components/app-shell/AppState";
import { Button } from "@/components/ui/button";

interface MeetingDetailsResponse {
  id: string;
  title: string;
  created_at: string;
  updated_at: string;
  transcripts: Transcript[];
  folder_path?: string;
  transcription_provider?: string;
  transcription_model?: string;
  summary_provider?: string;
  summary_model?: string;
}

function MeetingDetailsContent() {
  const searchParams = useSearchParams();
  const meetingId = searchParams.get('id');
  const { currentMeeting, setCurrentMeeting, refetchMeetings, stopSummaryPolling } = useSidebar();
  // Per-meeting post-recording pipeline (diarize → summary). The orchestrator —
  // not this page — is the sole trigger for post-recording summaries now, so the
  // old racy `source=recording` auto-generation has been removed.
  const { states: processingStates } = useMeetingProcessing();
  const router = useRouter();
  const [meetingDetails, setMeetingDetails] = useState<MeetingDetailsResponse | null>(null);
  const [meetingSummary, setMeetingSummary] = useState<Summary | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState<boolean>(true);

  const processing = meetingId ? processingStates.get(meetingId) : undefined;
  // Always-fresh mirror so the unmount cleanup reads current phase, not a stale
  // snapshot captured when the effect was registered.
  const processingStatesRef = useRef(processingStates);
  processingStatesRef.current = processingStates;

  // Use pagination hook for efficient transcript loading
  const {
    metadata,
    segments,
    transcripts,
    isLoading: isLoadingTranscripts,
    isLoadingMore,
    hasMore,
    totalCount,
    loadedCount,
    loadMore,
    refetch,
    error: transcriptError,
  } = usePaginatedTranscripts({ meetingId: meetingId || '' });

  // Sync meeting metadata from pagination hook to meeting details state
  useEffect(() => {
    if (metadata && (!meetingId || meetingId === 'intro-call')) {
      // If invalid meeting ID, don't sync
      return;
    }

    if (metadata) {
      console.log('Meeting metadata loaded:', metadata);

      // Build meeting details from metadata and paginated transcripts
      setMeetingDetails({
        id: metadata.id,
        title: currentMeeting?.id === metadata.id ? currentMeeting.title : metadata.title,
        created_at: metadata.created_at,
        updated_at: metadata.updated_at,
        transcripts: transcripts, // Paginated transcripts from hook
        folder_path: metadata.folder_path, // For retranscription feature
        transcription_provider: metadata.transcription_provider, // Per-meeting STT provenance
        transcription_model: metadata.transcription_model,
        summary_provider: metadata.summary_provider, // Per-meeting LLM provenance
        summary_model: metadata.summary_model,
      });

      // Sync with sidebar context
      if (currentMeeting?.id !== metadata.id) {
        setCurrentMeeting({ id: metadata.id, title: metadata.title });
      }
    }
  }, [currentMeeting, metadata, transcripts, meetingId, setCurrentMeeting]);

  // Handle transcript loading errors
  useEffect(() => {
    if (transcriptError) {
      console.error('Error loading transcripts:', transcriptError);
      setError(transcriptError);
    }
  }, [transcriptError]);

  // Extract fetchMeetingDetails for use in child components (now refetches via hook)
  const fetchMeetingDetails = useCallback(async () => {
    if (!meetingId || meetingId === 'intro-call') {
      return;
    }

    // The usePaginatedTranscripts hook automatically refetches when meetingId changes
    // This function is kept for compatibility with onMeetingUpdated callback
    console.log('fetchMeetingDetails called - pagination hook will handle refetch');
  }, [meetingId]);

  // Load (or reload) the saved summary from the DB for the current meeting.
  // Hoisted so the background-processing completion effect can re-run it once
  // the pipeline finishes, without re-triggering the full "Opening meeting"
  // loading state.
  const fetchMeetingSummary = useCallback(async () => {
    if (!meetingId || meetingId === 'intro-call') return;
    try {
      const summary = await invoke('api_get_summary', {
        meetingId: meetingId,
      }) as any;

      console.log('FETCH SUMMARY: Raw response:', summary);

      // Check if the summary request failed with 404 or error status, or if no summary exists yet (idle)
      // Note: 'cancelled' and 'failed' statuses can still have data if backup was restored
      if (summary.status === 'idle' || (!summary.data && summary.status === 'error')) {
        console.warn('Meeting summary not found or no summary generated yet:', summary.error || 'idle');
        setMeetingSummary(null);
        return;
      }

      const summaryData = summary.data || {};

      // Parse if it's a JSON string (backend may return double-encoded JSON)
      let parsedData = summaryData;
      if (typeof summaryData === 'string') {
        try {
          parsedData = JSON.parse(summaryData);
        } catch (e) {
          parsedData = {};
        }
      }

      console.log('🔍 FETCH SUMMARY: Parsed data:', parsedData);

      // Priority 1: BlockNote JSON format
      if (parsedData.summary_json) {
        setMeetingSummary(parsedData as any);
        return;
      }

      // Priority 2: Markdown format
      if (parsedData.markdown) {
        setMeetingSummary(parsedData as any);
        return;
      }

      // Legacy format - apply formatting
      console.log('LEGACY FORMAT: Detected legacy format, applying section formatting');

      const { MeetingName, _section_order, ...restSummaryData } = parsedData;

      // Format the summary data with consistent styling - PRESERVE ORDER
      const formattedSummary: Summary = {};

      // Use section order if available to maintain exact order and handle duplicates
      const sectionKeys = _section_order || Object.keys(restSummaryData);

      console.log('LEGACY FORMAT: Processing sections:', sectionKeys);

      for (const key of sectionKeys) {
        try {
          const section = restSummaryData[key];
          // Comprehensive null checks to prevent the error
          if (section &&
            typeof section === 'object' &&
            'title' in section &&
            'blocks' in section) {
            const typedSection = section as { title?: string; blocks?: any[] };

            // Ensure blocks is an array before mapping
            if (Array.isArray(typedSection.blocks)) {
              formattedSummary[key] = {
                title: typedSection.title || key,
                blocks: typedSection.blocks.map((block: any) => ({
                  ...block,
                  color: 'default',
                  content: block?.content?.trim() || ''
                }))
              };
            } else {
              console.warn(`LEGACY FORMAT: Section ${key} has invalid blocks:`, typedSection.blocks);
              formattedSummary[key] = {
                title: typedSection.title || key,
                blocks: []
              };
            }
          } else {
            console.warn(`LEGACY FORMAT: Skipping invalid section ${key}:`, section);
          }
        } catch (error) {
          console.warn(`LEGACY FORMAT: Error processing section ${key}:`, error);
        }
      }

      console.log('LEGACY FORMAT: Formatted summary:', formattedSummary);
      setMeetingSummary(formattedSummary);
    } catch (error) {
      console.error('FETCH SUMMARY: Error fetching meeting summary:', error);
      // Don't set error state for summary fetch failure, set to null to show generate button
      setMeetingSummary(null);
    }
  }, [meetingId]);

  // Reset states when meetingId changes (prevent race conditions)
  useEffect(() => {
    setMeetingDetails(null);
    setMeetingSummary(null);
    setError(null);
    setIsLoading(true);
  }, [meetingId]);

  // Cleanup: Stop polling when navigating away — BUT NOT while a background
  // summary is still running for this meeting. The pipeline (owned by
  // MeetingProcessingContext) must keep polling even after the user leaves the
  // page, so we only stop an orphaned poll (no active `summarizing` pipeline).
  useEffect(() => {
    return () => {
      if (!meetingId) return;
      const st = processingStatesRef.current.get(meetingId);
      if (st?.phase === 'summarizing') {
        console.log('Leaving mid-summary; keeping background poll alive for:', meetingId);
        return;
      }
      console.log('Cleaning up: Stopping summary polling for meeting:', meetingId);
      stopSummaryPolling(meetingId);
    };
  }, [meetingId, stopSummaryPolling]);

  // Reload the summary from the DB once the background pipeline finishes the
  // summary step (the backend has persisted it by then).
  useEffect(() => {
    if (processing?.phase === 'complete' && processing.stage === 'summary') {
      console.log('Background summary complete; reloading from DB for:', meetingId);
      void fetchMeetingSummary();
    }
  }, [processing?.phase, processing?.stage, meetingId, fetchMeetingSummary]);

  useEffect(() => {
    console.log('MeetingDetails useEffect triggered - meetingId:', meetingId);

    if (!meetingId || meetingId === 'intro-call') {
      console.warn('No valid meeting ID in URL - meetingId:', meetingId);
      setError("No meeting selected");
      setIsLoading(false);
      Analytics.trackPageView('meeting_details');
      return;
    }

    console.log('Valid meeting ID found, fetching details for:', meetingId);

    setMeetingDetails(null);
    setMeetingSummary(null);
    setError(null);
    setIsLoading(true);

    const loadData = async () => {
      try {
        await fetchMeetingSummary();
      } finally {
        setIsLoading(false);
      }
    };

    loadData();
  }, [meetingId, fetchMeetingSummary]);

  if (error) {
    return (
      <div className="app-page">
        <h1 className="sr-only">Meeting unavailable</h1>
        <AppState
          kind="error"
          title="Meeting could not be opened"
          description={error}
          action={<Button variant="outline" onClick={() => router.push('/meetings')}>Back to saved meetings</Button>}
        />
      </div>
    );
  }

  // Show loading spinner while initial data loads
  if ((isLoading || isLoadingTranscripts) || !meetingDetails) {
    return <div className="app-page">
      <h1 className="sr-only">Opening meeting</h1>
      <AppState kind="loading" title="Opening meeting" description="Loading the saved transcript and summary from this device." />
    </div>;
  }

  return <PageContent
    meeting={meetingDetails}
    summaryData={meetingSummary}
    processing={processing}
    onMeetingUpdated={async () => {
      // Refetch meeting details to get updated title from backend
      await fetchMeetingDetails();
      // Refetch meetings list to update sidebar
      await refetchMeetings();
    }}
    onRefetchTranscripts={refetch}
    // Pagination props for efficient transcript loading
    segments={segments}
    hasMore={hasMore}
    isLoadingMore={isLoadingMore}
    totalCount={totalCount}
    loadedCount={loadedCount}
    onLoadMore={loadMore}
  />;
}

export default function MeetingDetails() {
  return (
    <Suspense fallback={
      <div className="app-page">
        <h1 className="sr-only">Opening meeting</h1>
        <AppState kind="loading" title="Opening meeting" description="Loading local meeting data." />
      </div>
    }>
      <MeetingDetailsContent />
    </Suspense>
  );
}
