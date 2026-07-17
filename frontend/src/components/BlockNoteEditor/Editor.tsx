"use client";

import { useEffect, useRef } from "react";
import type { PartialBlock, Block } from "@blocknote/core";
import { useCreateBlockNote } from "@blocknote/react";
import { BlockNoteView } from "@blocknote/shadcn";
import { useTheme } from "@/contexts/ThemeContext";
import { useAudioPlayback } from "@/contexts/AudioPlaybackContext";
import { createRefBadgePlugin, refBadgePluginKey } from "@/lib/summary-ref-badge-plugin";
import "@blocknote/shadcn/style.css";

interface EditorProps {
  initialContent?: Block[];
  onChange?: (blocks: Block[]) => void;
  editable?: boolean;
}

export default function Editor({ initialContent, onChange, editable = true }: EditorProps) {
  const { resolvedTheme } = useTheme();
  console.log('📝 EDITOR: Initializing BlockNote editor with blocks:', {
    hasContent: !!initialContent,
    blocksCount: initialContent?.length || 0,
    editable
  });

  const editor = useCreateBlockNote({
    initialContent: initialContent as PartialBlock[] | undefined,
  });

  console.log('📝 EDITOR: BlockNote editor created successfully');

  // Inline "@ref(01:14)" / legacy "[01:14]" timestamp badges (decoration-only,
  // never touches the document — see summary-ref-badge-plugin.ts). Skipped
  // entirely when rendered outside an AudioPlaybackProvider.
  const player = useAudioPlayback();
  const durationRef = useRef(0);

  useEffect(() => {
    if (!player) return;
    const tiptap = editor._tiptapEditor;
    tiptap.registerPlugin(
      createRefBadgePlugin({
        getDurationSeconds: () => durationRef.current,
        onSeek: player.seekAndPlay,
      }),
    );
    return () => {
      tiptap.unregisterPlugin(refBadgePluginKey);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [editor, player?.seekAndPlay]);

  // Duration can arrive after the editor mounts (audio loads async).
  // registerPlugin only forces a decoration recompute once, at registration
  // time, so once duration changes we dispatch a no-op transaction — its only
  // job is to make ProseMirror re-run `props.decorations(state)`.
  useEffect(() => {
    durationRef.current = player?.duration ?? 0;
    const view = editor._tiptapEditor.view;
    if (view) view.dispatch(view.state.tr);
  }, [editor, player?.duration]);

  // Handle content changes
  useEffect(() => {
    if (!onChange) return;

    const handleChange = () => {
      console.log('📝 EDITOR: Content changed, notifying parent...', {
        blocksCount: editor.document.length
      });
      onChange(editor.document);
    };

    const unsubscribe = editor.onChange(handleChange);

    return () => {
      if (typeof unsubscribe === 'function') {
        console.log('📝 EDITOR: Cleaning up onChange listener');
        unsubscribe();
      }
    };
  }, [editor, onChange]);

  return <BlockNoteView editor={editor} editable={editable} theme={resolvedTheme} />;
}
