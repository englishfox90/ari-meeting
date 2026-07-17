import { useState, useEffect } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from './ui/select';
import { Input } from './ui/input';
import { Button } from './ui/button';
import { Label } from './ui/label';
import { Progress } from '@/components/ui/progress';
import { EyeIcon, EyeSlashIcon, LockClosedIcon, LockOpenIcon, CheckCircleIcon, ArrowPathIcon, XCircleIcon } from '@heroicons/react/24/outline';
import { ModelManager } from './WhisperModelManager';
import { ParakeetModelManager } from './ParakeetModelManager';
import { probeApple, ensureSpeechAssets, isTauriAvailable, type AppleProbeStatus } from '@/services/appleService';
import { toast } from 'sonner';


export interface TranscriptModelProps {
    provider: 'localWhisper' | 'parakeet' | 'deepgram' | 'elevenLabs' | 'groq' | 'openai' | 'apple';
    model: string;
    apiKey?: string | null;
}

export interface TranscriptSettingsProps {
    transcriptModelConfig: TranscriptModelProps;
    setTranscriptModelConfig: (config: TranscriptModelProps) => void;
    onModelSelect?: () => void;
}

export function TranscriptSettings({ transcriptModelConfig, setTranscriptModelConfig, onModelSelect }: TranscriptSettingsProps) {
    const [apiKey, setApiKey] = useState<string | null>(transcriptModelConfig.apiKey || null);
    const [showApiKey, setShowApiKey] = useState<boolean>(false);
    const [isApiKeyLocked, setIsApiKeyLocked] = useState<boolean>(true);
    const [isLockButtonVibrating, setIsLockButtonVibrating] = useState<boolean>(false);
    const [uiProvider, setUiProvider] = useState<TranscriptModelProps['provider']>(transcriptModelConfig.provider);

    // Apple on-device availability — a real probe (No-Fake-State). The Apple option
    // is only offered when Speech reports available, and the status block below
    // reflects genuine framework queries, never a faked capability.
    const [appleAvailable] = useState(() => isTauriAvailable());
    const [appleProbe, setAppleProbe] = useState<AppleProbeStatus | null>(null);
    const [appleChecking, setAppleChecking] = useState(false);
    const [installingSpeech, setInstallingSpeech] = useState(false);
    const [installProgress, setInstallProgress] = useState(0);
    const [installError, setInstallError] = useState<string | null>(null);

    // Sync uiProvider when backend config changes (e.g., after model selection or initial load)
    useEffect(() => {
        setUiProvider(transcriptModelConfig.provider);
    }, [transcriptModelConfig.provider]);

    useEffect(() => {
        if (
            transcriptModelConfig.provider === 'localWhisper' ||
            transcriptModelConfig.provider === 'parakeet' ||
            transcriptModelConfig.provider === 'apple'
        ) {
            setApiKey(null);
        }
    }, [transcriptModelConfig.provider]);

    // Probe Apple on-device availability on mount so the option is honestly gated.
    useEffect(() => {
        if (!appleAvailable) return;
        let cancelled = false;
        setAppleChecking(true);
        probeApple()
            .then((next) => { if (!cancelled) setAppleProbe(next); })
            .catch((err) => {
                if (!cancelled) {
                    setAppleProbe({
                        speechAvailable: false,
                        foundationAvailable: false,
                        osOk: false,
                        appleIntelligence: false,
                        speechAssetsInstalled: false,
                        error: err instanceof Error ? err.message : 'The on-device availability check failed.',
                    });
                }
            })
            .finally(() => { if (!cancelled) setAppleChecking(false); });
        return () => { cancelled = true; };
    }, [appleAvailable]);

    const handleInstallSpeech = async () => {
        setInstallingSpeech(true);
        setInstallProgress(0);
        setInstallError(null);
        try {
            const installed = await ensureSpeechAssets((fraction) => setInstallProgress(fraction));
            if (installed) {
                // Re-probe so the status flips to "ready" from a real query.
                setAppleProbe(await probeApple());
            } else {
                setInstallError('Speech models did not finish installing. Please try again.');
            }
        } catch (err) {
            setInstallError(err instanceof Error ? err.message : 'Installing speech models failed.');
        } finally {
            setInstallingSpeech(false);
        }
    };

    const fetchApiKey = async (provider: string) => {
        try {

            const data = await invoke('api_get_transcript_api_key', { provider }) as string;

            setApiKey(data || '');
        } catch (err) {
            console.error('Error fetching API key:', err);
            setApiKey(null);
        }
    };
    const modelOptions = {
        localWhisper: [], // Model selection handled by ModelManager component
        parakeet: [], // Model selection handled by ParakeetModelManager component
        deepgram: ['nova-2-phonecall'],
        elevenLabs: ['eleven_multilingual_v2'],
        groq: ['llama-3.3-70b-versatile'],
        openai: ['gpt-4o'],
        apple: [], // Single on-device system model — no model dropdown.
    };
    const requiresApiKey = transcriptModelConfig.provider === 'deepgram' || transcriptModelConfig.provider === 'elevenLabs' || transcriptModelConfig.provider === 'openai' || transcriptModelConfig.provider === 'groq';

    const handleInputClick = () => {
        if (isApiKeyLocked) {
            setIsLockButtonVibrating(true);
            setTimeout(() => setIsLockButtonVibrating(false), 500);
        }
    };

    const handleWhisperModelSelect = (modelName: string) => {
        // Always update config when model is selected, regardless of current provider
        // This ensures the model is set when user switches back
        setTranscriptModelConfig({
            ...transcriptModelConfig,
            provider: 'localWhisper', // Ensure provider is set correctly
            model: modelName
        });
        // Close modal after selection
        if (onModelSelect) {
            onModelSelect();
        }
    };

    const handleParakeetModelSelect = (modelName: string) => {
        // Always update config when model is selected, regardless of current provider
        // This ensures the model is set when user switches back
        setTranscriptModelConfig({
            ...transcriptModelConfig,
            provider: 'parakeet', // Ensure provider is set correctly
            model: modelName
        });
        // Close modal after selection
        if (onModelSelect) {
            onModelSelect();
        }
    };

    return (
        <div>
            <div>
                {/* <div className="flex justify-between items-center mb-4">
                    <h3 className="text-lg font-semibold text-foreground">Transcript Settings</h3>
                </div> */}
                <div className="space-y-4 pb-6">
                    <div>
                        <Label className="mb-1 block text-sm font-medium text-foreground">
                            Transcript model
                        </Label>
                        <div className="flex space-x-2 mx-1">
                            <Select
                                value={uiProvider}
                                onValueChange={(value) => {
                                    const provider = value as TranscriptModelProps['provider'];
                                    setUiProvider(provider);
                                    if (provider === 'apple') {
                                        // Apple has no model list and no API key — persist the
                                        // provider selection directly through the existing save path.
                                        setTranscriptModelConfig({ ...transcriptModelConfig, provider: 'apple', model: '', apiKey: null });
                                        invoke('api_save_transcript_config', { provider: 'apple', model: '', apiKey: null })
                                            .then(() => toast.success('Switched to Apple on-device transcription', { duration: 3000 }))
                                            .catch((err) => {
                                                console.error('Failed to save Apple transcript config:', err);
                                                toast.error('Could not save the Apple transcription setting. Try again.');
                                            });
                                    } else if (provider !== 'localWhisper' && provider !== 'parakeet') {
                                        fetchApiKey(provider);
                                    }
                                }}
                            >
                            <SelectTrigger className="focus:border-ring focus:ring-1 focus:ring-ring">
                                    <SelectValue placeholder="Select provider" />
                                </SelectTrigger>
                                <SelectContent>
                                    <SelectItem value="parakeet">Parakeet (recommended, real-time and accurate)</SelectItem>
                                    <SelectItem value="localWhisper">Local Whisper (high accuracy)</SelectItem>
                                    {appleProbe?.speechAvailable && (
                                        <SelectItem value="apple">Apple (on-device)</SelectItem>
                                    )}
                                    {/* <SelectItem value="deepgram">☁️ Deepgram (Backup)</SelectItem>
                                    <SelectItem value="elevenLabs">☁️ ElevenLabs</SelectItem>
                                    <SelectItem value="groq">☁️ Groq</SelectItem>
                                    <SelectItem value="openai">☁️ OpenAI</SelectItem> */}
                                </SelectContent>
                            </Select>

                            {uiProvider !== 'localWhisper' && uiProvider !== 'parakeet' && uiProvider !== 'apple' && (
                                <Select
                                    value={transcriptModelConfig.model}
                                    onValueChange={(value) => {
                                        const model = value as TranscriptModelProps['model'];
                                        setTranscriptModelConfig({ ...transcriptModelConfig, provider: uiProvider, model });
                                    }}
                                >
                                    <SelectTrigger className="focus:border-ring focus:ring-1 focus:ring-ring">
                                        <SelectValue placeholder="Select model" />
                                    </SelectTrigger>
                                    <SelectContent>
                                        {modelOptions[uiProvider].map((model) => (
                                            <SelectItem key={model} value={model}>{model}</SelectItem>
                                        ))}
                                    </SelectContent>
                                </Select>
                            )}

                        </div>
                    </div>

                    {uiProvider === 'localWhisper' && (
                        <div className="mt-6">
                            <ModelManager
                                selectedModel={transcriptModelConfig.provider === 'localWhisper' ? transcriptModelConfig.model : undefined}
                                onModelSelect={handleWhisperModelSelect}
                                autoSave={true}
                            />
                        </div>
                    )}

                    {uiProvider === 'parakeet' && (
                        <div className="mt-6">
                            <ParakeetModelManager
                                selectedModel={transcriptModelConfig.provider === 'parakeet' ? transcriptModelConfig.model : undefined}
                                onModelSelect={handleParakeetModelSelect}
                                autoSave={true}
                            />
                        </div>
                    )}

                    {uiProvider === 'apple' && (
                        <div className="mt-6 mx-1">
                            {appleChecking || appleProbe === null ? (
                                <p className="flex items-center gap-2 text-sm text-muted-foreground">
                                    <ArrowPathIcon className="size-4 animate-spin" aria-hidden />
                                    Checking on-device availability…
                                </p>
                            ) : appleProbe.speechAvailable ? (
                                appleProbe.speechAssetsInstalled ? (
                                    <p className="flex items-start gap-2 text-sm text-muted-foreground">
                                        <CheckCircleIcon className="mt-0.5 size-5 shrink-0 text-foreground" aria-hidden />
                                        <span>Apple on-device transcription ready — runs entirely on this Mac, no API key.</span>
                                    </p>
                                ) : (
                                    <div className="rounded-[10px] border bg-muted/30 p-3">
                                        {installingSpeech ? (
                                            <div className="space-y-2">
                                                <p className="flex items-center gap-2 text-sm text-muted-foreground">
                                                    <ArrowPathIcon className="size-4 animate-spin" aria-hidden />
                                                    Installing speech models… {Math.round(installProgress * 100)}%
                                                </p>
                                                <Progress value={Math.round(installProgress * 100)} aria-label="Speech model download progress" />
                                            </div>
                                        ) : (
                                            <div className="space-y-2">
                                                <p className="text-sm text-muted-foreground">
                                                    Speech models aren’t installed yet. On-device transcription needs a
                                                    one-time speech-model download for your language.
                                                </p>
                                                {installError && (
                                                    <p role="alert" className="text-sm text-destructive">{installError}</p>
                                                )}
                                                <Button variant="outline" size="sm" onClick={handleInstallSpeech}>
                                                    {installError ? 'Retry install' : 'Install speech models'}
                                                </Button>
                                            </div>
                                        )}
                                    </div>
                                )
                            ) : (
                                <p className="flex items-start gap-2 text-sm text-muted-foreground">
                                    <XCircleIcon className="mt-0.5 size-5 shrink-0 text-muted-foreground" aria-hidden />
                                    <span>
                                        {!appleProbe.osOk
                                            ? 'Requires macOS 26 or newer.'
                                            : !appleProbe.appleIntelligence
                                                ? 'Turn on Apple Intelligence in System Settings to enable this.'
                                                : appleProbe.error || 'On-device transcription is not available on this Mac.'}
                                    </span>
                                </p>
                            )}
                        </div>
                    )}


                    {requiresApiKey && (
                        <div>
                            <Label className="mb-1 block text-sm font-medium text-foreground">
                                API Key
                            </Label>
                            <div className="relative mx-1">
                                <Input
                                    type={showApiKey ? "text" : "password"}
                                    className={`pr-24 focus:border-ring focus:ring-1 focus:ring-ring ${isApiKeyLocked ? 'cursor-not-allowed bg-muted' : ''
                                        }`}
                                    value={apiKey || ''}
                                    onChange={(e) => setApiKey(e.target.value)}
                                    disabled={isApiKeyLocked}
                                    onClick={handleInputClick}
                                    placeholder="Enter your API key"
                                />
                                {isApiKeyLocked && (
                                    <div
                                        onClick={handleInputClick}
                                        className="absolute inset-0 flex cursor-not-allowed items-center justify-center rounded-md bg-muted/50"
                                    />
                                )}
                                <div className="absolute inset-y-0 right-0 pr-1 flex items-center">
                                    <Button
                                        type="button"
                                        variant="ghost"
                                        size="icon"
                                        onClick={() => setIsApiKeyLocked(!isApiKeyLocked)}
                                        className={`transition-colors duration-200 ${isLockButtonVibrating ? 'animate-vibrate text-destructive' : ''
                                            }`}
                                        title={isApiKeyLocked ? "Unlock to edit" : "Lock to prevent editing"}
                                    >
                                        {isApiKeyLocked ? <LockClosedIcon className="size-4" /> : <LockOpenIcon className="size-4" />}
                                    </Button>
                                    <Button
                                        type="button"
                                        variant="ghost"
                                        size="icon"
                                        onClick={() => setShowApiKey(!showApiKey)}
                                    >
                                        {showApiKey ? <EyeSlashIcon className="size-4" /> : <EyeIcon className="size-4" />}
                                    </Button>
                                </div>
                            </div>
                        </div>
                    )}
                </div>
            </div>
        </div >
    )
}




