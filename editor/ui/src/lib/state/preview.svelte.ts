// editor/ui/src/lib/state/preview.svelte.ts
// Preview state: /api/preview/state payload, the human status line, and the
// chosen preview viewport width. The status line only ever restates a phase
// message the host actually sent — never a fabricated build state.

import type { PreviewState } from '../types';

export type PreviewWidth = 'full' | '375' | '768' | '1440';

export const preview = $state({
  data: null as PreviewState | null,
  status: 'Preview is not running.',
  width: 'full' as PreviewWidth
});

export function setPreview(state: PreviewState) {
  preview.data = state;
  preview.status = state.message;
}
