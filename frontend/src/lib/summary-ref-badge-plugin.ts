/**
 * ProseMirror decoration plugin that renders inline summary timestamp
 * references (`@ref(01:14)` and the legacy `[01:14]` form — see
 * summary-timestamps.ts for the shared token matcher) as small clickable
 * "play" badges inside the BlockNote/TipTap editor, including inside
 * markdown table cells.
 *
 * This is decoration-only: it never touches the document. The raw token
 * text stays in the doc (and therefore round-trips through markdown export
 * unchanged) — we just hide it visually and overlay a widget in its place.
 *
 * No-Fake-State: if the recording duration isn't known yet (audio still
 * loading, or no recording at all), this plugin produces NO decorations —
 * raw text stays as plain text rather than showing a badge that can't play
 * anything. Duration is read through a getter (not baked in at plugin
 * creation) so decorations reflect the latest known duration; callers must
 * force a state recompute when duration changes (see registration call
 * sites in Editor.tsx / BlockNoteSummaryView.tsx).
 */

// Import from @tiptap/pm's re-exported subpaths (a direct dependency) rather
// than the bare `prosemirror-*` packages — those aren't hoisted as top-level
// node_modules deps here, only pinned via pnpm.overrides for version alignment.
import { Plugin, PluginKey } from '@tiptap/pm/state';
import { Decoration, DecorationSet } from '@tiptap/pm/view';
import type { Node as ProseMirrorNode } from '@tiptap/pm/model';
import { matchTimestampTokens } from '@/lib/summary-timestamps';

export const refBadgePluginKey = new PluginKey('summaryRefBadges');

// Matches the button classes in SummaryMoments.tsx, sized down slightly to
// sit comfortably inline within body/table text.
const BADGE_CLASSNAME =
  'inline-flex items-center gap-0.5 rounded-full border border-border bg-secondary ' +
  'px-1.5 py-0.5 font-mono text-xs tabular-nums text-foreground align-baseline ' +
  'transition-colors hover:border-accent hover:bg-accent hover:text-accent-foreground ' +
  'cursor-pointer select-none';

const PLAY_ICON_PATH =
  'M4.5 5.653c0-1.427 1.529-2.33 2.779-1.643l11.54 6.347c1.295.712 1.295 2.573 0 ' +
  '3.286L7.28 19.99c-1.25.687-2.779-.217-2.779-1.643V5.653Z';

function buildBadgeDOM(label: string, seconds: number, onSeek: (seconds: number) => void): HTMLElement {
  const badge = document.createElement('span');
  badge.className = BADGE_CLASSNAME;
  badge.setAttribute('data-seconds', String(seconds));
  badge.setAttribute('role', 'button');
  badge.setAttribute('tabindex', '0');
  badge.setAttribute('contenteditable', 'false');
  badge.setAttribute('aria-label', `Play recording from ${label}`);

  const svgNS = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(svgNS, 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('fill', 'currentColor');
  svg.setAttribute('aria-hidden', 'true');
  svg.classList.add('size-3');
  const path = document.createElementNS(svgNS, 'path');
  path.setAttribute('fill-rule', 'evenodd');
  path.setAttribute('clip-rule', 'evenodd');
  path.setAttribute('d', PLAY_ICON_PATH);
  svg.appendChild(path);
  badge.appendChild(svg);

  const text = document.createElement('span');
  text.textContent = label;
  badge.appendChild(text);

  const activate = (event: Event) => {
    event.preventDefault();
    event.stopPropagation();
    onSeek(seconds);
  };
  // mousedown (not click) so ProseMirror never gets a chance to move the
  // cursor / start a selection drag on this non-editable widget first.
  badge.addEventListener('mousedown', activate);
  badge.addEventListener('keydown', (event) => {
    if (event.key === 'Enter' || event.key === ' ') activate(event);
  });

  return badge;
}

export interface RefBadgePluginOptions {
  /** Latest known recording duration in seconds; <= 0 means "unknown". */
  getDurationSeconds: () => number;
  /** Seek the meeting audio player and start playback. */
  onSeek: (seconds: number) => void;
}

/**
 * Build decorations for one text node's matches, if any.
 */
function decorationsForTextNode(
  node: ProseMirrorNode,
  nodeStart: number,
  duration: number,
  onSeek: (seconds: number) => void,
): Decoration[] {
  const text = node.text;
  if (!text) return [];

  const decorations: Decoration[] = [];
  const maxSeconds = duration + 2; // small tolerance, mirrors extractSummaryMoments

  for (const token of matchTimestampTokens(text)) {
    if (token.seconds < 0 || token.seconds > maxSeconds) continue; // out-of-range → leave raw text (No-Fake-State)

    const from = nodeStart + token.index;
    const to = from + token.length;

    // Hide the raw token text… (inline `style` rather than only a CSS class so
    // it can't be defeated by a missing/overridden stylesheet rule — the badge
    // widget is overlaid in its place below).
    decorations.push(
      Decoration.inline(from, to, { class: 'ref-token-hidden', style: 'display: none !important' }),
    );
    // …and overlay a clickable badge in its place.
    decorations.push(
      Decoration.widget(
        from,
        () => buildBadgeDOM(token.label, token.seconds, onSeek),
        {
          side: -1,
          ignoreSelection: true,
          key: `refbadge-${from}-${token.seconds}`,
        },
      ),
    );
  }

  return decorations;
}

/**
 * Create the ProseMirror plugin. Register via
 * `editor._tiptapEditor.registerPlugin(createRefBadgePlugin(...))` and clean
 * up with `editor._tiptapEditor.unregisterPlugin(refBadgePluginKey)`.
 */
export function createRefBadgePlugin({ getDurationSeconds, onSeek }: RefBadgePluginOptions): Plugin {
  return new Plugin({
    key: refBadgePluginKey,
    props: {
      decorations(state) {
        const duration = getDurationSeconds();
        // No known duration → no badges at all; raw text stays (No-Fake-State).
        if (!Number.isFinite(duration) || duration <= 0) {
          return DecorationSet.empty;
        }

        const decorations: Decoration[] = [];
        state.doc.descendants((node, pos) => {
          if (!node.isText) return true;
          decorations.push(...decorationsForTextNode(node, pos, duration, onSeek));
          return true;
        });

        return decorations.length > 0 ? DecorationSet.create(state.doc, decorations) : DecorationSet.empty;
      },
    },
  });
}
