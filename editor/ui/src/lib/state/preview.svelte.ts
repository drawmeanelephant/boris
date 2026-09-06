// editor/ui/src/lib/state/preview.svelte.ts
// Preview state: /api/preview/state payload, the human status line, the
// chosen preview viewport width, and the watch-daemon refusal note. The
// status line only ever restates a phase message the host actually sent —
// never a fabricated build state. A refused rebuild (409
// `watch_daemon_active` while the managed watch daemon owns the dist/ writer
// seat) is surfaced honestly and points at the Watch pane.

import { api } from '../api';
import type { PreviewState } from '../types';

export type PreviewWidth = 'full' | '375' | '768' | '1440';

export const preview = $state({
  data: null as PreviewState | null,
  status: 'Preview is not running.',
  width: 'full' as PreviewWidth,
  // True after the host refused a rebuild with watch_daemon_active. Cleared
  // by a fresh authoritative preview payload or by the watch state module
  // when the daemon is observed stopping.
  watchRefusal: false
});

export function setPreview(state: PreviewState) {
  preview.data = state;
  preview.status = state.message;
  preview.watchRefusal = false;
}

export function noteWatchRefusal() {
  preview.watchRefusal = true;
  preview.status = 'Preview rebuild was refused: the watch daemon owns the dist/ writer while it runs. Stop the watch daemon in the Watch pane to rebuild manually.';
}

export function clearWatchRefusal() {
  preview.watchRefusal = false;
}

// Re-reads the authoritative preview payload; used by the watch state module
// when the daemon starts or stops so `watch_active` follows the daemon
// without waiting for the next rebuild.
export async function refreshPreviewState() {
  const result = await api<PreviewState>('/api/preview/state');
  if (result.response.ok) setPreview(result.data as PreviewState);
}
