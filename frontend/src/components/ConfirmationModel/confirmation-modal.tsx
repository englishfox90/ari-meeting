import React from 'react';
import { createPortal } from 'react-dom';

interface ConfirmationModalProps {
  onConfirm: () => void;
  onCancel: () => void;
  text: string;
  isOpen: boolean;
}

export function ConfirmationModal({ onConfirm, onCancel, text, isOpen }: ConfirmationModalProps) {
  const [mounted, setMounted] = React.useState(false);

  React.useEffect(() => {
    setMounted(true);
  }, []);

  if (!isOpen || !mounted) return null;

  // Render into <body> via a portal so the overlay escapes any ancestor
  // containing block (the sidebar sets `backdrop-blur-xl`, whose backdrop-filter
  // otherwise anchors `fixed` children to the sidebar box, clipping the modal).
  return createPortal(
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-foreground/45 p-4 backdrop-blur-sm">
      <div className="mx-4 w-full max-w-md border border-border bg-card p-6 shadow-[0_24px_80px_hsl(var(--shadow-color)/0.28)]">
        <h2 className="app-display mb-4 text-xl">Confirm Delete</h2>
        <p className="mb-6 text-muted-foreground">{text}</p>
        <div className="flex justify-end space-x-4">
          <button
            onClick={onCancel}
            className="rounded-[3px] px-4 py-2 text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
          >
            Cancel
          </button>
          <button
            onClick={onConfirm}
            className="rounded-[3px] bg-destructive px-4 py-2 text-destructive-foreground transition-colors hover:bg-destructive/90"
          >
            Delete
          </button>
        </div>
      </div>
    </div>,
    document.body
  );
}
