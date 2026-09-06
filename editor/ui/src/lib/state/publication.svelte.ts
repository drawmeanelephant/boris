// editor/ui/src/lib/state/publication.svelte.ts
// Publication state: /api/publication payload (profiles + local Proof Pack),
// the selected profile for boris plan, and the last normalized plan returned
// by a plan command.

import { api } from '../api';
import type { PublicationPayload, PublicationPlan } from '../types';

export const publication = $state({
  payload: null as PublicationPayload | null,
  status: 'Loading publication profiles…',
  selectedProfile: '',
  lastPlan: null as PublicationPlan | null
});

export function setPublication(payload: PublicationPayload) {
  publication.payload = payload;
  if (payload.profiles.length === 0) {
    publication.status = 'No publication profile found at the project root.';
    publication.selectedProfile = '';
    return;
  }
  if (!payload.profiles.some(profile => profile.path === publication.selectedProfile)) {
    publication.selectedProfile = payload.profiles[0].path;
  }
  if (payload.proof_status === 'unsupported') {
    publication.status = 'Local Proof Pack is stale or unsupported. Build HTML to replace it.';
    return;
  }
  publication.status = payload.proof
    ? `Local Proof Pack present for target ${payload.proof.target} (${payload.proof.overall_presentation_status}).`
    : `Ready to plan with ${payload.profiles.length === 1 ? payload.profiles[0].path : `${payload.profiles.length} profiles`}.`;
}

export async function refreshPublication() {
  const result = await api<PublicationPayload>('/api/publication');
  if (result.response.ok) setPublication(result.data);
  else publication.status = 'Publication profiles could not be loaded.';
}
