'use client';

import { useCallback, useRef, useEffect, useState, memo } from "react";
import { useVirtualizer } from "@tanstack/react-virtual";
import { useAutoScroll } from "@/hooks/useAutoScroll";
import { useTranscriptStreaming } from "@/hooks/useTranscriptStreaming";
import { ConfidenceIndicator } from "./ConfidenceIndicator";
import { Tooltip, TooltipContent, TooltipTrigger } from "./ui/tooltip";
import { RecordingStatusBar } from "./RecordingStatusBar";
import { motion, AnimatePresence } from "framer-motion";
import { TranscriptSegmentData } from "@/types";
import { SpeakerChip } from "./MeetingDetails/SpeakerChip";
import { SpeakerReassignMenu, type SpeakerReassignOption } from "./MeetingDetails/SpeakerReassignMenu";
import type { EnrollmentState } from "@/services/speakerService";

/** Resolved, display-ready speaker info for one segment. */
export interface ResolvedSpeaker {
    displayName: string;
    state: EnrollmentState;
}

export interface VirtualizedTranscriptViewProps {
    /** Transcript segments to display */
    segments: TranscriptSegmentData[];
    /** Whether recording is in progress */
    isRecording?: boolean;
    /** Whether recording is paused */
    isPaused?: boolean;
    /** Whether processing/finalizing transcription */
    isProcessing?: boolean;
    /** Whether stopping */
    isStopping?: boolean;
    /** Enable streaming effect for latest segment */
    enableStreaming?: boolean;
    /** Show confidence indicators */
    showConfidence?: boolean;
    /** Completely disable auto-scroll behavior (for meeting details page) */
    disableAutoScroll?: boolean;
    /** Hide the legacy inline status bar when the parent workspace owns recording status. */
    showRecordingStatus?: boolean;

    // Pagination props (infinite scroll)
    hasMore?: boolean;
    isLoadingMore?: boolean;
    totalCount?: number;
    loadedCount?: number;
    onLoadMore?: () => void;

    /** When provided, segment timestamps become clickable and jump audio to that time. */
    onSeekTo?: (seconds: number) => void;
    /** Id of the segment currently playing, for highlight. */
    activeSegmentId?: string | null;

    // ── Speaker attribution (F1) — all optional; live recording omits them ──
    /** Resolve a segment's speakerId to display-ready info. Returns null when unknown. */
    resolveSpeaker?: (speakerId: string) => ResolvedSpeaker | null;
    /** The speaker currently selected (their lines highlight amber). */
    selectedSpeakerId?: string | null;
    /** Called when a speaker chip is clicked (toggle selection / open review). */
    onSelectSpeaker?: (speakerId: string) => void;
    /** Every speaker diarization found in this meeting, for the per-line reassign picker. */
    reassignOptions?: SpeakerReassignOption[];
    /** Manually reassign one transcript line's speaker (`null` clears it). Omit to hide the affordance. */
    onReassignSpeaker?: (transcriptId: string, speakerId: string | null) => void;
}

// Threshold for enabling virtualization (below this, use simple rendering)
const VIRTUALIZATION_THRESHOLD = 10;

// Helper function to format seconds as recording-relative time [MM:SS]
function formatRecordingTime(seconds: number | undefined): string {
    if (seconds === undefined) return '[--:--]';

    const totalSeconds = Math.floor(seconds);
    const minutes = Math.floor(totalSeconds / 60);
    const secs = totalSeconds % 60;

    return `[${minutes.toString().padStart(2, '0')}:${secs.toString().padStart(2, '0')}]`;
}

// Helper function to remove filler words and repetitions
function cleanStopWords(text: string): string {
    const stopWords = ['uh', 'um', 'er', 'ah', 'hmm', 'hm', 'eh', 'oh'];

    let cleanedText = text;
    stopWords.forEach(word => {
        const pattern = new RegExp(`\\b${word}\\b[,\\s]*`, 'gi');
        cleanedText = cleanedText.replace(pattern, ' ');
    });

    return cleanedText.replace(/\s+/g, ' ').trim();
}

// Memoized transcript segment component
const TranscriptSegment = memo(function TranscriptSegment({
    id,
    timestamp,
    text,
    confidence,
    isStreaming,
    showConfidence,
    onSeek,
    isActive,
    speakerId,
    speaker,
    isSpeakerSelected,
    onSelectSpeaker,
    reassignOptions,
    onReassignSpeaker,
}: {
    id: string;
    timestamp: number;
    text: string;
    confidence?: number;
    isStreaming: boolean;
    showConfidence: boolean;
    onSeek?: (seconds: number) => void;
    isActive?: boolean;
    speakerId?: string | null;
    speaker?: ResolvedSpeaker | null;
    isSpeakerSelected?: boolean;
    onSelectSpeaker?: (speakerId: string) => void;
    reassignOptions?: SpeakerReassignOption[];
    onReassignSpeaker?: (transcriptId: string, speakerId: string | null) => void;
}) {
    const displayText = cleanStopWords(text) || (text.trim() === '' ? '[Silence]' : text);
    const timeLabel = formatRecordingTime(timestamp);

    const timeNode = onSeek ? (
        <button
            type="button"
            onClick={() => onSeek(timestamp)}
            aria-label={`Play recording from ${timeLabel.replace(/[[\]]/g, '')}`}
            className="mt-1 min-w-[50px] flex-shrink-0 text-left font-mono text-xs text-muted-foreground transition-colors hover:text-accent"
        >
            {timeLabel}
        </button>
    ) : (
        <span className="mt-1 min-w-[50px] flex-shrink-0 text-xs text-muted-foreground">
            {timeLabel}
        </span>
    );

    // Amber (the ≤8% signal) marks the ONE selected speaker's lines; the softer
    // audio-playback highlight is used only when no speaker is selected here.
    const highlightClass = isSpeakerSelected
        ? 'border-l-2 border-accent bg-accent-soft'
        : isActive
            ? 'bg-accent-soft'
            : 'border-l-2 border-transparent';

    return (
        <div
            id={`segment-${id}`}
            className={`mb-3 -mx-2 rounded-md px-2 transition-colors ${highlightClass}`}
        >
            <div className="flex items-start gap-2">
                <Tooltip>
                    <TooltipTrigger asChild>
                        {timeNode}
                    </TooltipTrigger>
                    <TooltipContent>
                        {confidence !== undefined && showConfidence && (
                            <ConfidenceIndicator confidence={confidence} showIndicator={showConfidence} />
                        )}
                    </TooltipContent>
                </Tooltip>
                <div className="flex-1">
                    {(speaker && speakerId) || (onReassignSpeaker && reassignOptions && reassignOptions.length > 0) ? (
                        <div className="mb-1 flex items-center gap-1">
                            {speaker && speakerId ? (
                                <SpeakerChip
                                    speakerId={speakerId}
                                    displayName={speaker.displayName}
                                    state={speaker.state}
                                    selected={Boolean(isSpeakerSelected)}
                                    onClick={onSelectSpeaker ? () => onSelectSpeaker(speakerId) : undefined}
                                />
                            ) : onReassignSpeaker ? (
                                <span className="text-[0.6875rem] text-muted-foreground">No speaker</span>
                            ) : null}
                            {onReassignSpeaker && reassignOptions && reassignOptions.length > 0 ? (
                                <SpeakerReassignMenu
                                    speakers={reassignOptions}
                                    currentSpeakerId={speakerId ?? null}
                                    onSelect={(newSpeakerId) => onReassignSpeaker(id, newSpeakerId)}
                                />
                            ) : null}
                        </div>
                    ) : null}
                    {isStreaming ? (
                        <div className="border border-border bg-muted/60 px-3 py-2">
                            <p className="text-base leading-relaxed text-foreground">{displayText}</p>
                        </div>
                    ) : (
                        <p className="text-base leading-relaxed text-foreground">{displayText}</p>
                    )}
                </div>
            </div>
        </div>
    );
});

export const VirtualizedTranscriptView: React.FC<VirtualizedTranscriptViewProps> = ({
    segments,
    isRecording = false,
    isPaused = false,
    isProcessing = false,
    isStopping = false,
    enableStreaming = false,
    showConfidence = true,
    disableAutoScroll = false,
    showRecordingStatus = true,
    hasMore = false,
    isLoadingMore = false,
    totalCount = 0,
    loadedCount = 0,
    onLoadMore,
    onSeekTo,
    activeSegmentId = null,
    resolveSpeaker,
    selectedSpeakerId = null,
    onSelectSpeaker,
    reassignOptions,
    onReassignSpeaker,
}) => {
    // Create scroll ref first - shared between virtualizer and auto-scroll hook
    const scrollRef = useRef<HTMLDivElement>(null);
    // Wrapper around the content, observed by auto-scroll to keep the live line
    // pinned as the current segment grows (not only when a new segment arrives).
    const contentRef = useRef<HTMLDivElement>(null);
    // Ref for infinite scroll trigger element
    const loadMoreTriggerRef = useRef<HTMLDivElement>(null);

    // Setup virtualizer for efficient rendering of large lists
    const virtualizer = useVirtualizer({
        count: segments.length,
        getScrollElement: () => scrollRef.current,
        estimateSize: () => 60, // Estimated height per segment
        overscan: 10, // Render extra items above/below viewport
    });

    // Custom hook for auto-scrolling (supports both virtualized and non-virtualized)
    useAutoScroll({
        scrollRef,
        contentRef,
        segments,
        isRecording,
        isPaused,
        virtualizer,
        virtualizationThreshold: VIRTUALIZATION_THRESHOLD,
        disableAutoScroll,
    });

    // Streaming text effect hook (typewriter animation for new transcripts)
    const { streamingSegmentId, getDisplayText } = useTranscriptStreaming(
        segments,
        isRecording,
        enableStreaming
    );

    // Infinite scroll: IntersectionObserver to trigger loading more
    useEffect(() => {
        if (!onLoadMore || !hasMore || isLoadingMore || isRecording || segments.length === 0) {
            return;
        }

        const triggerElement = loadMoreTriggerRef.current;
        if (!triggerElement) return;

        const observer = new IntersectionObserver(
            (entries) => {
                if (entries[0].isIntersecting && hasMore && !isLoadingMore) {
                    onLoadMore();
                }
            },
            {
                root: null,
                rootMargin: '100px',
                threshold: 0,
            }
        );

        observer.observe(triggerElement);

        return () => observer.disconnect();
    }, [hasMore, isLoadingMore, onLoadMore, isRecording, segments.length]);

    // Scroll-based fallback for fast scrolling
    useEffect(() => {
        if (!onLoadMore || !hasMore || isLoadingMore || isRecording) return;

        const scrollElement = scrollRef.current;
        if (!scrollElement) return;

        let ticking = false;

        const handleScroll = () => {
            if (ticking || isLoadingMore || !hasMore) return;

            ticking = true;
            requestAnimationFrame(() => {
                const { scrollTop, scrollHeight, clientHeight } = scrollElement;
                const scrollBottom = scrollHeight - scrollTop - clientHeight;

                // Trigger load when within 200px of bottom
                if (scrollBottom < 200 && hasMore && !isLoadingMore) {
                    onLoadMore();
                }
                ticking = false;
            });
        };

        scrollElement.addEventListener('scroll', handleScroll, { passive: true });
        return () => scrollElement.removeEventListener('scroll', handleScroll);
    }, [onLoadMore, hasMore, isLoadingMore, isRecording]);

    // Use simple rendering for small lists, virtualization for large lists
    const useVirtualization = segments.length >= VIRTUALIZATION_THRESHOLD;

    return (
        <div ref={scrollRef} className="flex flex-col h-full overflow-y-auto px-4 py-2">
            {/* Recording Status Bar - Sticky at top, always visible when recording */}
            <AnimatePresence>
                {isRecording && showRecordingStatus && (
                    <div className="sticky top-0 z-10 bg-card pb-2">
                        <RecordingStatusBar isPaused={isPaused} />
                    </div>
                )}
            </AnimatePresence>

            {/* Content - add padding when recording to prevent overlap */}
            <div ref={contentRef} className={isRecording ? 'pt-2' : ''}>
            {segments.length === 0 ? (
                // Empty state
                <motion.div
                    initial={{ opacity: 0 }}
                    animate={{ opacity: 1 }}
                    className="mt-8 text-center text-muted-foreground"
                >
                    {isRecording ? (
                        <>
                            <div className="flex items-center justify-center mb-3">
                                <div className={`h-3 w-3 rounded-full ${isPaused ? 'bg-warning' : 'bg-accent animate-pulse'}`}></div>
                            </div>
                            <p className="text-sm text-foreground">
                                {isPaused ? 'Recording paused' : 'Listening for speech...'}
                            </p>
                            <p className="mt-1 text-xs text-muted-foreground">
                                {isPaused ? 'Click resume to continue recording' : 'Speak to see live transcription'}
                            </p>
                        </>
                    ) : (
                        <>
                            <p className="text-lg font-semibold">Welcome to meetily!</p>
                            <p className="text-xs mt-1">Start recording to see live transcription</p>
                        </>
                    )}
                </motion.div>
            ) : useVirtualization ? (
                // Virtualized rendering for large lists
                <>
                    <div
                        style={{
                            height: virtualizer.getTotalSize(),
                            width: "100%",
                            position: "relative",
                        }}
                    >
                        {virtualizer.getVirtualItems().map((virtualRow) => {
                            const segment = segments[virtualRow.index];
                            const isStreaming = streamingSegmentId === segment.id;

                            return (
                                <div
                                    key={segment.id}
                                    data-index={virtualRow.index}
                                    ref={virtualizer.measureElement}
                                    style={{
                                        position: "absolute",
                                        top: 0,
                                        left: 0,
                                        width: "100%",
                                        transform: `translateY(${virtualRow.start}px)`,
                                    }}
                                >
                                    <TranscriptSegment
                                        id={segment.id}
                                        timestamp={segment.timestamp}
                                        text={getDisplayText(segment)}
                                        confidence={segment.confidence}
                                        isStreaming={isStreaming}
                                        showConfidence={showConfidence}
                                        onSeek={onSeekTo}
                                        isActive={segment.id === activeSegmentId}
                                        speakerId={segment.speakerId}
                                        speaker={segment.speakerId && resolveSpeaker ? resolveSpeaker(segment.speakerId) : null}
                                        isSpeakerSelected={Boolean(segment.speakerId) && segment.speakerId === selectedSpeakerId}
                                        onSelectSpeaker={onSelectSpeaker}
                                        reassignOptions={reassignOptions}
                                        onReassignSpeaker={onReassignSpeaker}
                                    />
                                </div>
                            );
                        })}
                    </div>

                    {/* Infinite scroll trigger and loading indicator */}
                    {(hasMore || isLoadingMore) && !isRecording && segments.length > 0 && (
                        <div ref={loadMoreTriggerRef} className="flex justify-center items-center py-4 mt-2">
                            {isLoadingMore ? (
                                <div className="flex items-center gap-2 text-muted-foreground">
                                    <div className="h-4 w-4 animate-spin rounded-full border-2 border-border border-t-foreground" />
                                    <span className="text-sm">Loading more...</span>
                                </div>
                            ) : hasMore && totalCount > 0 ? (
                                <span className="text-sm text-muted-foreground">
                                    Showing {loadedCount} of {totalCount} segments
                                </span>
                            ) : null}
                        </div>
                    )}

                    {/* Listening indicator when recording */}
                    {!isStopping && isRecording && !isPaused && !isProcessing && segments.length > 0 && (
                        <motion.div
                            initial={{ opacity: 0 }}
                            animate={{ opacity: 1 }}
                            exit={{ opacity: 0 }}
                            className="mt-4 flex items-center gap-2 text-muted-foreground"
                        >
                            <div className="h-2 w-2 animate-pulse rounded-full bg-accent"></div>
                            <span className="text-sm">Listening...</span>
                        </motion.div>
                    )}
                </>
            ) : (
                // Simple rendering for small lists (better animations)
                <>
                    <div className="space-y-1">
                        {segments.map((segment) => {
                            const isStreaming = streamingSegmentId === segment.id;

                            return (
                                <motion.div
                                    key={segment.id}
                                    initial={{ opacity: 0, y: 5 }}
                                    animate={{ opacity: 1, y: 0 }}
                                    transition={{ duration: 0.15 }}
                                >
                                    <TranscriptSegment
                                        id={segment.id}
                                        timestamp={segment.timestamp}
                                        text={getDisplayText(segment)}
                                        confidence={segment.confidence}
                                        isStreaming={isStreaming}
                                        showConfidence={showConfidence}
                                        onSeek={onSeekTo}
                                        isActive={segment.id === activeSegmentId}
                                        speakerId={segment.speakerId}
                                        speaker={segment.speakerId && resolveSpeaker ? resolveSpeaker(segment.speakerId) : null}
                                        isSpeakerSelected={Boolean(segment.speakerId) && segment.speakerId === selectedSpeakerId}
                                        onSelectSpeaker={onSelectSpeaker}
                                        reassignOptions={reassignOptions}
                                        onReassignSpeaker={onReassignSpeaker}
                                    />
                                </motion.div>
                            );
                        })}
                    </div>

                    {/* Infinite scroll trigger (for small lists that grow) */}
                    {(hasMore || isLoadingMore) && !isRecording && segments.length > 0 && (
                        <div ref={loadMoreTriggerRef} className="flex justify-center items-center py-4 mt-2">
                            {isLoadingMore ? (
                                <div className="flex items-center gap-2 text-muted-foreground">
                                    <div className="h-4 w-4 animate-spin rounded-full border-2 border-border border-t-foreground" />
                                    <span className="text-sm">Loading more...</span>
                                </div>
                            ) : hasMore && totalCount > 0 ? (
                                <span className="text-sm text-muted-foreground">
                                    Showing {loadedCount} of {totalCount} segments
                                </span>
                            ) : null}
                        </div>
                    )}

                    {/* Listening indicator when recording */}
                    {!isStopping && isRecording && !isPaused && !isProcessing && segments.length > 0 && (
                        <motion.div
                            initial={{ opacity: 0 }}
                            animate={{ opacity: 1 }}
                            exit={{ opacity: 0 }}
                            className="mt-4 flex items-center gap-2 text-muted-foreground"
                        >
                            <div className="h-2 w-2 animate-pulse rounded-full bg-accent"></div>
                            <span className="text-sm">Listening...</span>
                        </motion.div>
                    )}
                </>
            )}
            </div>
        </div>
    );
};
