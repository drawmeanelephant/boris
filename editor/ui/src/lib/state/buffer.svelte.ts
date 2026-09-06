// editor/ui/src/lib/state/buffer.svelte.ts
// The open buffer: path, content, baseline, fingerprint, read-only state,
// undo/redo stacks, caret position, editing status, the external-change
// conflict, and the recovery-snapshot list with its debounced snapshot
// schedule. Edits only ever land here; the host is the sole other writer.

import { tick } from 'svelte';
import { api } from '../api';
import { connection } from './connection.svelte';
import type {
  BufferResponse,
  ErrorResponse,
  RecoveryList,
  RecoverySnapshot,
  Suggestion
} from '../types';

export const buffer = $state({
  activePath: '',
  content: '',
  baseline: '',
  fingerprint: '',
  readOnly: false,
  undoStack: [] as string[],
  redoStack: [] as string[],
  editorStatus: 'Choose a project file to begin editing.',
  saveInFlight: false,
  conflict: null as BufferResponse | null,
  deletedConflict: false,
  snapshots: [] as RecoverySnapshot[],
  cursor: { line: 1, column: 1 }
});

export function dirty(): boolean {
  return buffer.activePath !== '' && buffer.content !== buffer.baseline;
}

let recoveryTimer: ReturnType<typeof setInterval> | undefined;

export function loadBuffer(next: BufferResponse, status: string) {
  stopRecoveryTimer();
  buffer.activePath = next.path;
  buffer.content = next.content;
  buffer.baseline = next.content;
  buffer.fingerprint = next.fingerprint;
  buffer.readOnly = next.read_only;
  buffer.undoStack = [];
  buffer.redoStack = [];
  buffer.cursor = { line: 1, column: 1 };
  buffer.editorStatus = status;
}

// The empty-buffer reset used when a file is deleted or discarded outside
// the editor; keeps every field consistent with a freshly closed buffer.
export function resetBuffer() {
  buffer.activePath = '';
  buffer.content = '';
  buffer.baseline = '';
  buffer.fingerprint = '';
  buffer.undoStack = [];
  buffer.redoStack = [];
}

function pushUndo() {
  buffer.undoStack = [...buffer.undoStack.slice(-99), buffer.content];
  buffer.redoStack = [];
}

export function editSource(event: Event) {
  const next = (event.currentTarget as HTMLTextAreaElement).value;
  if (next === buffer.content) return;
  pushUndo();
  buffer.content = next;
  buffer.editorStatus = `Unsaved changes in ${buffer.activePath}.`;
  scheduleRecovery();
}

export function undo() {
  if (buffer.undoStack.length === 0 || buffer.readOnly) return;
  const previous = buffer.undoStack[buffer.undoStack.length - 1];
  buffer.undoStack = buffer.undoStack.slice(0, -1);
  buffer.redoStack = [...buffer.redoStack.slice(-99), buffer.content];
  buffer.content = previous;
  buffer.editorStatus = `Undid change in ${buffer.activePath}.`;
  scheduleRecovery();
}

export function redo() {
  if (buffer.redoStack.length === 0 || buffer.readOnly) return;
  const next = buffer.redoStack[buffer.redoStack.length - 1];
  buffer.redoStack = buffer.redoStack.slice(0, -1);
  pushUndo();
  buffer.content = next;
  buffer.editorStatus = `Redid change in ${buffer.activePath}.`;
  scheduleRecovery();
}

// Caret -> 1-based line/column, mirroring the problem position convention
// (`sourceOffset` walks lines then columns the same way).
export function trackCursor() {
  const editor = document.getElementById('source-editor') as HTMLTextAreaElement | null;
  if (!editor) return;
  const offset = editor.selectionStart;
  const before = buffer.content.slice(0, offset);
  const lines = before.split('\n');
  buffer.cursor = { line: lines.length, column: lines[lines.length - 1].length + 1 };
}

export async function insertSuggestion(suggestion: Suggestion | undefined) {
  if (!suggestion || !buffer.activePath || buffer.readOnly) return;
  const editor = document.querySelector<HTMLTextAreaElement>('#source-editor');
  if (!editor) return;
  const start = editor.selectionStart;
  const end = editor.selectionEnd;
  pushUndo();
  buffer.content = `${buffer.content.slice(0, start)}${suggestion.insert}${buffer.content.slice(end)}`;
  buffer.editorStatus = `Inserted ${suggestion.value} from Boris authoring vocabulary.`;
  scheduleRecovery();
  await tick();
  editor.focus();
  editor.setSelectionRange(start + suggestion.insert.length, start + suggestion.insert.length);
}

export async function clearRecovery(path: string) {
  const result = await api<ErrorResponse>('/api/recovery/clear', { method: 'POST', body: JSON.stringify({ path }) });
  if (result.response.ok) {
    buffer.snapshots = buffer.snapshots.filter(snapshot => snapshot.path !== path);
  } else {
    buffer.editorStatus = `Could not discard recovery for ${path}.`;
  }
}

export async function discardBuffer() {
  if (!buffer.activePath) return;
  const discardedPath = buffer.activePath;
  await clearRecovery(discardedPath);
  stopRecoveryTimer();
  buffer.content = buffer.baseline;
  buffer.undoStack = [];
  buffer.redoStack = [];
  buffer.editorStatus = `Discarded unsaved changes in ${discardedPath}.`;
}

export function scheduleRecovery() {
  if (!buffer.activePath || buffer.content === buffer.baseline) {
    stopRecoveryTimer();
    if (buffer.activePath) void clearRecovery(buffer.activePath);
    return;
  }
  if (!recoveryTimer) {
    // Snapshot on first dirty so a host or tab death before the 3s tick
    // is not silent loss. Later edits stay periodic until pagehide.
    void snapshotBuffer();
    recoveryTimer = setInterval(() => void snapshotBuffer(), 3000);
  }
}

export function stopRecoveryTimer() {
  if (recoveryTimer) clearInterval(recoveryTimer);
  recoveryTimer = undefined;
}

export async function snapshotBuffer(options: RequestInit = {}) {
  if (!buffer.activePath || buffer.content === buffer.baseline) return;
  const result = await api<ErrorResponse>('/api/recovery/snapshot', {
    method: 'POST',
    body: JSON.stringify({ path: buffer.activePath, content: buffer.content, fingerprint: buffer.fingerprint }),
    ...options
  });
  if ((result.data as ErrorResponse).error === 'host_unavailable') {
    // Mirrors the host-watch path: the connection line flips once, and the
    // editing-status message is rewritten only on that transition.
    const next = 'Local host unavailable. Restart boris-editor.';
    if (connection.status !== next) {
      connection.status = next;
      markBufferHostUnavailable();
    }
    return;
  }
  if (!result.response.ok) buffer.editorStatus = `Unsaved changes in ${buffer.activePath}; recovery snapshot failed.`;
}

export function flushRecovery() {
  void snapshotBuffer({ keepalive: true });
}

export async function loadRecovery(): Promise<{ skipped: number; ok: boolean }> {
  const result = await api<RecoveryList>('/api/recovery');
  if (result.response.ok) {
    buffer.snapshots = result.data.snapshots;
    return { skipped: result.data.skipped ?? 0, ok: true };
  }
  return { skipped: 0, ok: false };
}

// The host-unavailable editing-status half of the host watch; the
// connection-status half lives in connection.svelte.ts. Idempotent like the
// original single message.
export function markBufferHostUnavailable() {
  const next = 'The editor host stopped. Restart boris-editor and open the new launch URL. Unsaved work is kept only if a recovery snapshot was written.';
  if (buffer.editorStatus === next) return;
  buffer.editorStatus = next;
}
