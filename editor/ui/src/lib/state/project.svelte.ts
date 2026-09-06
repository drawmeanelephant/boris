// editor/ui/src/lib/state/project.svelte.ts
// Project file tree: /api/files state, the filter query, and the derived
// visible-file cap (mirroring the host's own limits). Reads the open buffer
// path so the active file always stays visible in the capped tree.

import { api } from '../api';
import { fileTreeAnnouncement } from '../utils';
import { visibleFileLimit } from '../types';
import type { FileEntry, FileList } from '../types';
import { buffer } from './buffer.svelte';

export const project = $state({
  files: [] as FileEntry[],
  fileQuery: ''
});

export function matchingFiles(): FileEntry[] {
  const needle = project.fileQuery.trim().toLocaleLowerCase();
  return needle ? project.files.filter(file => file.path.toLocaleLowerCase().includes(needle)) : project.files;
}

export function visibleFiles(): FileEntry[] {
  const capped = matchingFiles().slice(0, visibleFileLimit);
  if (buffer.activePath && !capped.some(file => file.path === buffer.activePath)) {
    const active = project.files.find(file => file.path === buffer.activePath);
    if (active) return [active, ...capped];
  }
  return capped;
}

export function fileTreeStatus(): string {
  return fileTreeAnnouncement(project.files.length, matchingFiles().length, visibleFiles().length, project.fileQuery);
}

export function themeAssets(): FileEntry[] {
  return project.files.filter(file => file.path.startsWith('themes/') && file.path.includes('/assets/'));
}

export async function refreshFiles() {
  const result = await api<FileList>('/api/files');
  if (result.response.ok) project.files = result.data.files;
}
