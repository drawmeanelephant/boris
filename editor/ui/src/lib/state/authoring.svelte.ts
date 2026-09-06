// editor/ui/src/lib/state/authoring.svelte.ts
// Boris authoring vocabulary: /api/authoring payload (frontmatter schema +
// completion index), the completion combobox state, and the derived
// suggestion list for the current kind/query.

import { tick } from 'svelte';
import { api } from '../api';
import { completionSuggestions } from '../utils';
import type { AuthoringPayload, CompletionKind, Suggestion } from '../types';

export const authoring = $state({
  payload: null as AuthoringPayload | null,
  status: 'Loading Boris authoring vocabulary…',
  completionKind: 'frontmatter_key' as CompletionKind,
  completionQuery: '',
  selectedSuggestion: 0,
  completionOpen: false
});

export function suggestions(): Suggestion[] {
  return completionSuggestions(authoring.payload, authoring.completionKind, authoring.completionQuery);
}

export function closedLayoutSlots(): string[] {
  return authoring.payload?.completion?.layout_slots ?? [];
}

export function setAuthoring(payload: AuthoringPayload) {
  authoring.payload = payload;
  if (payload.completion_status === 'unsupported') {
    authoring.status = 'completion.json is stale or unsupported. Build diagnostics to replace it. Frontmatter schema remains available.';
    return;
  }
  authoring.status = payload.completion
    ? `Boris completion index ready from ${payload.completion.compiler_id}.`
    : 'Frontmatter schema ready. Build diagnostics to create graph completion data.';
}

export async function refreshAuthoring() {
  authoring.status = 'Refreshing Boris completion…';
  const result = await api<AuthoringPayload>('/api/authoring');
  if (result.response.ok) setAuthoring(result.data);
  else authoring.status = 'The Boris build succeeded, but completion.json could not be adapted.';
}

export async function changeCompletionKind() {
  authoring.completionQuery = '';
  authoring.selectedSuggestion = 0;
  authoring.completionOpen = true;
  await tick();
  document.getElementById('completion-query')?.focus();
}
