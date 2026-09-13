// editor/ui/src/lib/state/density.svelte.ts
// Editor density modes (#990): the calm Author writing view or the full
// Review chrome. This is disposable UI state — a per-browser preference, not
// project truth — so it persists beside the other editor prefs and is
// validated on load. Focus writing mode stays a separate overlay.

export type DensityMode = 'author' | 'review';

const STORAGE_KEY = 'boris-editor-density';

function storedMode(): DensityMode | null {
  try {
    const value = localStorage.getItem(STORAGE_KEY);
    return value === 'author' || value === 'review' ? value : null;
  } catch {
    return null;
  }
}

export const density = $state({
  mode: 'author' as DensityMode
});

export function initDensity() {
  density.mode = storedMode() ?? 'author';
}

export function setDensity(mode: DensityMode) {
  density.mode = mode;
  try {
    localStorage.setItem(STORAGE_KEY, mode);
  } catch {
    // Persistence is best-effort; the in-session choice still applies.
  }
}

export function toggleDensity() {
  setDensity(density.mode === 'author' ? 'review' : 'author');
}
