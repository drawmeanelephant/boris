// editor/ui/src/lib/state/project.svelte.ts
// Project file tree: /api/files state, the filter query, the derived
// visible-file cap (mirroring the host's own limits), and the collapsed-folder
// set. Reads the open buffer path so the active file always stays visible in
// the capped tree.
//
// The host's list is flat and stays flat: the tree, the cap, and the collapsed
// set are all presentation over the same paths, so nothing here can hold a
// directory model that disagrees with what Boris owns.

import { untrack } from 'svelte';
import { api } from '../api';
import { fileTreeAnnouncement } from '../utils';
import { visibleFileLimit } from '../types';
import type { FileEntry, FileList, ProjectTreeNode } from '../types';
import { buffer } from './buffer.svelte';

export const project = $state({
  files: [] as FileEntry[],
  fileQuery: '',
  // Directory paths (project-relative, no trailing slash) the author has
  // collapsed. Persisted per browser; see initProjectTree for the load-time
  // validation.
  collapsedDirs: [] as string[]
});

const TREE_STORAGE_KEY = 'boris-editor-project-collapsed';
const MAX_COLLAPSED_DIRS = 500;
const MAX_DIR_PATH_LENGTH = 512;

// Persisted folder state is untrusted input: it survives upgrades and is
// editable by hand, so every entry is validated as an author-owned relative
// directory path before it can affect what the tree renders. Anything that is
// not a plain relative path is dropped rather than repaired; the worst case is
// a folder that reads expanded again.
function storedCollapsedDirs(): string[] {
  try {
    const raw: unknown = JSON.parse(localStorage.getItem(TREE_STORAGE_KEY) ?? '[]');
    if (!Array.isArray(raw)) return [];
    const seen = new Set<string>();
    const out: string[] = [];
    for (const value of raw) {
      if (typeof value !== 'string' || value.length === 0 || value.length > MAX_DIR_PATH_LENGTH) continue;
      if (value.startsWith('/') || value.includes('\\') || value.includes('//')) continue;
      if (value.split('/').some(segment => segment === '' || segment === '.' || segment === '..')) continue;
      if (seen.has(value)) continue;
      seen.add(value);
      out.push(value);
      if (out.length >= MAX_COLLAPSED_DIRS) break;
    }
    return out;
  } catch {
    return [];
  }
}

function persistCollapsedDirs() {
  try {
    localStorage.setItem(TREE_STORAGE_KEY, JSON.stringify(project.collapsedDirs));
  } catch {
    // Persistence is best-effort; the in-session choice still applies.
  }
}

export function initProjectTree() {
  project.collapsedDirs = storedCollapsedDirs();
}

export function isDirCollapsed(path: string): boolean {
  return project.collapsedDirs.includes(path);
}

export function toggleDir(path: string) {
  project.collapsedDirs = project.collapsedDirs.includes(path)
    ? project.collapsedDirs.filter(dir => dir !== path)
    : [...project.collapsedDirs, path];
  persistCollapsedDirs();
}

// Ancestor directory paths of a file path, outermost first.
function ancestorsOf(path: string): string[] {
  const segments = path.split('/');
  segments.pop();
  const out: string[] = [];
  let prefix = '';
  for (const segment of segments) {
    if (segment === '') continue;
    prefix = prefix === '' ? segment : `${prefix}/${segment}`;
    out.push(prefix);
  }
  return out;
}

// Un-collapse every folder above `path`, so opening a file from anywhere —
// the tree, the command palette, a graph link, a problem — always lands on a
// visible row. Called when the active path *changes*, not on every render: an
// author who deliberately collapses the folder holding the open file keeps it
// collapsed until they move to another file.
//
// The read of collapsedDirs is untracked so this never becomes a dependency of
// the caller's effect; the effect depends on the active path alone.
export function revealPath(path: string): void {
  const ancestors = ancestorsOf(path);
  if (ancestors.length === 0) return;
  untrack(() => {
    const next = project.collapsedDirs.filter(dir => !ancestors.includes(dir));
    if (next.length === project.collapsedDirs.length) return;
    project.collapsedDirs = next;
    persistCollapsedDirs();
  });
}

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

type TreeDir = Extract<ProjectTreeNode, { kind: 'dir' }>;

// The visible files as a directory tree. Directories are derived from the path
// segments of the paths that actually survive the filter and the cap, so a
// directory never appears without a file under it and the tree can never
// disagree with the host's list. Directory rows are labels rather than
// controls: a directory holds no editor action of its own, and keeping them
// non-interactive leaves the tree's control count equal to its file count.
//
// Sibling order is directories first, then files, each alphabetically — the
// conventional tree reading, and stable regardless of the order the host
// happens to enumerate in.
export function fileTree(): ProjectTreeNode[] {
  const root: TreeDir = { kind: 'dir', name: '', path: '', children: [] };
  const dirs = new Map<string, TreeDir>([['', root]]);
  const seen = new Set<string>();

  for (const file of visibleFiles()) {
    if (seen.has(file.path)) continue;
    seen.add(file.path);
    const segments = file.path.split('/');
    const leaf = segments.pop() as string;
    let parent = root;
    for (const segment of segments) {
      const prefix = parent.path === '' ? segment : `${parent.path}/${segment}`;
      let dir = dirs.get(prefix);
      if (!dir) {
        dir = { kind: 'dir', name: segment, path: prefix, children: [] };
        dirs.set(prefix, dir);
        parent.children.push(dir);
      }
      parent = dir;
    }
    parent.children.push({ kind: 'file', name: leaf, path: file.path });
  }

  sortTree(root);
  return root.children;
}

function sortTree(dir: TreeDir): void {
  dir.children.sort((a, b) => {
    if (a.kind !== b.kind) return a.kind === 'dir' ? -1 : 1;
    return a.name.localeCompare(b.name);
  });
  for (const child of dir.children) {
    if (child.kind === 'dir') sortTree(child);
  }
}

export function fileTreeStatus(): string {
  return fileTreeAnnouncement(project.files.length, matchingFiles().length, visibleFiles().length, project.fileQuery);
}

export function themeAssets(): FileEntry[] {
  return project.files.filter(file => file.path.startsWith('themes/') && file.path.includes('/assets/'));
}

export async function refreshFiles(): Promise<boolean> {
  const result = await api<FileList>('/api/files');
  if (!result.response.ok) return false;
  project.files = result.data.files;
  return true;
}

function sortedWith(files: FileEntry[], path: string): FileEntry[] {
  if (files.some(file => file.path === path)) return files;
  return [...files, { path }].sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
}

// Keep the tree honest when a write succeeded but GET /api/files did not:
// insert, rename, or drop the known path instead of leaving buffer and list
// pointing at different realities.
export function rememberFile(path: string) {
  project.files = sortedWith(project.files, path);
}

export function rememberRenamedFile(oldPath: string, newPath: string) {
  const without = project.files.filter(file => file.path !== oldPath);
  project.files = sortedWith(without, newPath);
}

export function forgetFile(path: string) {
  project.files = project.files.filter(file => file.path !== path);
}
