'use client';

/**
 * AskAudioBridge — renders nothing. It lives INSIDE the meeting-details
 * AudioPlaybackProvider and registers that meeting's `seekAndPlay` into AskContext,
 * so the app-wide Ask overlay (which sits OUTSIDE the provider) can make @ref(MM:SS)
 * timestamp badges play the meeting audio when the thread is scoped to this meeting.
 *
 * Cross-meeting audio is intentionally NOT supported — only the currently open
 * meeting is bridged, and the registration is cleared on unmount.
 */

import { useEffect } from 'react';
import { useAsk } from '@/contexts/AskContext';
import { useAudioPlayback } from '@/contexts/AudioPlaybackContext';

export function AskAudioBridge({ meetingId }: { meetingId: string }) {
  const player = useAudioPlayback();
  const { setMeetingAudio, clearMeetingAudio } = useAsk();

  useEffect(() => {
    if (!player) return;
    setMeetingAudio(meetingId, (seconds: number) => player.seekAndPlay(seconds));
    return () => clearMeetingAudio(meetingId);
  }, [player, meetingId, setMeetingAudio, clearMeetingAudio]);

  return null;
}
