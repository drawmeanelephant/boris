// editor/ui/src/lib/theme.svelte.ts
// Theme state for the editor UI. The `data-theme` attribute on <html> drives
// the token palette in lib/tokens.css. Until the author picks a theme
// explicitly (persisted in localStorage), the editor follows
// prefers-color-scheme, including live OS scheme changes.

export type ThemeName = 'light' | 'dark';

const STORAGE_KEY = 'boris-editor-theme';

function storedTheme(): ThemeName | null {
  try {
    const value = localStorage.getItem(STORAGE_KEY);
    return value === 'light' || value === 'dark' ? value : null;
  } catch {
    return null;
  }
}

function schemeTheme(): ThemeName {
  return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}

export const theme = $state<{ current: ThemeName }>({ current: 'light' });

function applyTheme() {
  document.documentElement.dataset.theme = theme.current;
}

let started = false;

// Called once from main.ts before mount so the first paint already carries
// the resolved theme instead of flashing the default palette.
export function initTheme() {
  if (started) return;
  started = true;
  theme.current = storedTheme() ?? schemeTheme();
  applyTheme();
  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
    if (storedTheme() !== null) return;
    theme.current = schemeTheme();
    applyTheme();
  });
}

export function toggleTheme() {
  theme.current = theme.current === 'dark' ? 'light' : 'dark';
  try {
    localStorage.setItem(STORAGE_KEY, theme.current);
  } catch {
    // Persistence is best-effort; the in-session toggle still applies.
  }
  applyTheme();
}
