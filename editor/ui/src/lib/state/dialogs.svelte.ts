// editor/ui/src/lib/state/dialogs.svelte.ts
// Dialog lifecycle state: the pending save-or-discard resolution, the create
// and rename path drafts, and the focus-restore memory that returns focus to
// a dialog's trigger on native close. Dialog element references stay in
// App.svelte (they are bound to rendered elements there); these helpers take
// the element as an argument.

import { commandLabel } from '../utils';
import type { PendingResolution } from '../types';

export const dialogs = $state({
  pendingResolution: null as PendingResolution | null,
  createPath: 'content/new-page.md',
  renamePath: '',
  lastDialogTrigger: null as HTMLElement | null,
  skipFocusRestore: false
});

export function resolutionPrompt(): string {
  return (() => {
  const pending = dialogs.pendingResolution;
  if (!pending) return '';
  if (pending.action === 'open') return `Save or discard the changes before opening ${pending.target}?`;
  if (pending.action === 'command') return `Boris commands read repository files from disk. Save or discard the changes before running ${commandLabel(pending.mode)}?`;
  if (pending.action === 'restore') return `Save or discard the changes before restoring ${pending.snapshot.path}?`;
  return 'Save or discard the changes before rebuilding the preview?';
})();
}

export function resolutionVerb(): string {
  return dialogs.pendingResolution?.action === 'open'
    ? 'switch'
    : dialogs.pendingResolution?.action === 'command'
      ? 'run'
      : dialogs.pendingResolution?.action === 'restore'
        ? 'restore'
        : 'rebuild';
}

export function rememberDialogTrigger(source: EventTarget | null = document.activeElement) {
  dialogs.lastDialogTrigger = source instanceof HTMLElement ? source : null;
  dialogs.skipFocusRestore = false;
}

export function openModal(dialog: HTMLDialogElement, trigger?: EventTarget | null) {
  rememberDialogTrigger(trigger === undefined ? document.activeElement : trigger);
  dialog.showModal();
}

export function restoreDialogFocus() {
  if (dialogs.skipFocusRestore) {
    dialogs.skipFocusRestore = false;
    return;
  }
  const trigger = dialogs.lastDialogTrigger;
  dialogs.lastDialogTrigger = null;
  if (!trigger || !document.contains(trigger) || document.querySelector('dialog[open]')) return;
  trigger.focus();
}
