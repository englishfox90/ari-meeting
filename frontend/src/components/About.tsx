import React, { useState, useEffect } from "react";
import { invoke } from '@tauri-apps/api/core';
import { getVersion } from '@tauri-apps/api/app';
import { AriMark } from "./app-shell/AriMark";
import { UpdateDialog } from "./UpdateDialog";
import { updateService, UpdateInfo } from '@/services/updateService';
import { Button } from './ui/button';
import { ArrowPathIcon, ArrowTopRightOnSquareIcon, CheckCircleIcon } from '@heroicons/react/24/outline';
import { toast } from 'sonner';
import { APP_VERSION } from '@/lib/app-version';


export function About() {
    const [currentVersion, setCurrentVersion] = useState<string>(APP_VERSION);
    const [updateInfo, setUpdateInfo] = useState<UpdateInfo | null>(null);
    const [isChecking, setIsChecking] = useState(false);
    const [showUpdateDialog, setShowUpdateDialog] = useState(false);

    useEffect(() => {
        // Get current version on mount
        getVersion().then(setCurrentVersion).catch(console.error);
    }, []);

    const handleUpstreamClick = async () => {
        try {
            await invoke('open_external_url', { url: 'https://github.com/Zackriya-Solutions/meetily' });
        } catch (error) {
            console.error('Failed to open link:', error);
        }
    };

    const handleCheckForUpdates = async () => {
        setIsChecking(true);
        try {
            const info = await updateService.checkForUpdates(true);
            setUpdateInfo(info);
            if (info.available) {
                setShowUpdateDialog(true);
            } else {
                toast.success('You are running the latest version');
            }
        } catch (error: any) {
            console.error('Failed to check for updates:', error);
            toast.error('Failed to check for updates: ' + (error.message || 'Unknown error'));
        } finally {
            setIsChecking(false);
        }
    };

    return (
        <div className="max-h-[80vh] space-y-5 overflow-y-auto p-5">
            <div className="border-b border-border pb-5 text-center">
                <AriMark className="mx-auto h-10 w-auto text-[hsl(var(--accent))]" />
                <h1 className="app-display mt-3 text-2xl">Ari Meeting</h1>
                <span className="mt-1 block text-xs text-muted-foreground">v{currentVersion}</span>
                <p className="mx-auto mt-3 max-w-md text-sm leading-6 text-muted-foreground">
                    Private, on-device meeting intelligence for macOS. Ari records and transcribes your meetings, then writes summaries that understand who was in the room, who owns the conversation, and what kind of meeting it is.
                </p>
                <div className="mt-3">
                    <Button
                        onClick={handleCheckForUpdates}
                        disabled={isChecking}
                        variant="outline"
                        size="sm"
                        className="text-xs"
                    >
                        {isChecking ? (
                            <>
                                <ArrowPathIcon className="mr-2 h-3 w-3 animate-spin motion-reduce:animate-none" />
                                Checking...
                            </>
                        ) : (
                            <>
                                <CheckCircleIcon className="mr-2 h-3 w-3" />
                                Check for Updates
                            </>
                        )}
                    </Button>
                    {updateInfo?.available && (
                        <div className="mt-2 text-xs text-accent">
                            Update available: v{updateInfo.version}
                        </div>
                    )}
                </div>
            </div>

            <div className="space-y-3">
                <h2 className="text-sm font-semibold text-foreground">Where Ari is headed</h2>
                <div className="grid grid-cols-2 gap-2">
                    <div className="border border-border bg-muted/40 p-3">
                        <h3 className="mb-1 text-sm font-semibold text-foreground">Context-aware summaries</h3>
                        <p className="text-xs leading-relaxed text-muted-foreground">Meetings aren&apos;t anonymous events. Ari weaves in the owner, the people present, and the meeting type so each summary fits the conversation.</p>
                    </div>
                    <div className="border border-border bg-muted/40 p-3">
                        <h3 className="mb-1 text-sm font-semibold text-foreground">A connected record</h3>
                        <p className="text-xs leading-relaxed text-muted-foreground">Recurring people and recurring formats carry forward across meetings, with calendar awareness grounding who and what.</p>
                    </div>
                    <div className="border border-border bg-muted/40 p-3">
                        <h3 className="mb-1 text-sm font-semibold text-foreground">Private and on-device</h3>
                        <p className="text-xs leading-relaxed text-muted-foreground">Capture, transcription, and summarization run locally on your Mac. Nothing leaves the machine unless you configure a remote provider.</p>
                    </div>
                    <div className="border border-border bg-muted/40 p-3">
                        <h3 className="mb-1 text-sm font-semibold text-foreground">Honest by design</h3>
                        <p className="text-xs leading-relaxed text-muted-foreground">Recording is always prompted, never silent. Summaries and recall cite real transcripts — no invented activity or fabricated sources.</p>
                    </div>
                </div>
            </div>

            <div className="border border-accent/30 bg-accent-soft p-3">
                <p className="text-sm leading-5 text-foreground">
                    <span className="font-semibold">Upstream attribution.</span> Ari Meeting is an independent fork of Meetily by Zackriya Solutions. The original application and MIT license remain credited in this project.
                </p>
            </div>

            <div className="space-y-2 border-t border-border pt-4 text-center">
                <button
                    onClick={handleUpstreamClick}
                    className="inline-flex items-center gap-2 bg-primary px-3 py-2 text-sm font-semibold text-primary-foreground transition-colors hover:bg-primary/90"
                >
                    View upstream Meetily <ArrowTopRightOnSquareIcon className="size-3.5" />
                </button>
            </div>

            {/* Update Dialog */}
            <UpdateDialog
                open={showUpdateDialog}
                onOpenChange={setShowUpdateDialog}
                updateInfo={updateInfo}
            />
        </div>

    )
}
