// editor/ui/src/lib/state/focus.svelte.ts
// Focus writing-mode state: whether the full-screen writing overlay is open,
// which layout (write / split / preview) it shows, and the focus hand-off
// back to the workspace when it closes.
//
// The overlay reuses the shell's single source of truth for the document —
// `buffer` from state/buffer.svelte.ts — so a draft started here is the same
// draft the Source pane shows, with the same undo/redo/recovery machinery.
// This module only owns presentation: layout choice (persisted) and the
// element focus should return to after the overlay closes.

const STORAGE_KEY = 'boris-editor-focus-layout';
const TYPE_STORAGE_KEY = 'boris-editor-focus-type';
const ZEN_STORAGE_KEY = 'boris-editor-focus-zen';

export type FocusLayout = 'write' | 'split' | 'preview';

function storedLayout(): FocusLayout | null {
  try {
    const value = localStorage.getItem(STORAGE_KEY);
    return value === 'write' || value === 'split' || value === 'preview' ? value : null;
  } catch {
    return null;
  }
}

export const focusMode = $state({
  open: false,
  layout: 'write' as FocusLayout
});

export function initFocusLayout() {
  const stored = storedLayout();
  if (stored) focusMode.layout = stored;
}

export function setFocusLayout(layout: FocusLayout) {
  focusMode.layout = layout;
  try {
    localStorage.setItem(STORAGE_KEY, layout);
  } catch {
    // Persistence is best-effort; the in-session choice still applies.
  }
}

// --- Typography preferences -----------------------------------------------
// Text size, reading-measure (line width), and typeface for the focus
// surfaces, persisted together and validated field-by-field on load so a
// stale or corrupted entry falls back to the defaults per field.

export type FocusTypeSize = 's' | 'm' | 'l' | 'xl';
export type FocusMeasure = 'narrow' | 'medium' | 'wide';
export type FocusTypeFace = 'serif' | 'sans';

const TYPE_SIZES: FocusTypeSize[] = ['s', 'm', 'l', 'xl'];
const TYPE_MEASURES: FocusMeasure[] = ['narrow', 'medium', 'wide'];
const TYPE_FACES: FocusTypeFace[] = ['serif', 'sans'];

function storedType<T extends string>(field: string, allowed: T[], fallback: T): T {
  try {
    const raw = JSON.parse(localStorage.getItem(TYPE_STORAGE_KEY) ?? '{}') as Record<string, unknown>;
    const value = raw[field];
    return allowed.includes(value as T) ? (value as T) : fallback;
  } catch {
    return fallback;
  }
}

export const focusType = $state({
  size: 'm' as FocusTypeSize,
  measure: 'medium' as FocusMeasure,
  face: 'serif' as FocusTypeFace
});

export function initFocusType() {
  focusType.size = storedType('size', TYPE_SIZES, 'm');
  focusType.measure = storedType('measure', TYPE_MEASURES, 'medium');
  focusType.face = storedType('face', TYPE_FACES, 'serif');
}

function persistFocusType() {
  try {
    localStorage.setItem(TYPE_STORAGE_KEY, JSON.stringify({
      size: focusType.size,
      measure: focusType.measure,
      face: focusType.face
    }));
  } catch {
    // Persistence is best-effort; the in-session choice still applies.
  }
}

export function setFocusTypeSize(size: FocusTypeSize) {
  focusType.size = size;
  persistFocusType();
}

export function setFocusTypeMeasure(measure: FocusMeasure) {
  focusType.measure = measure;
  persistFocusType();
}

export function setFocusTypeFace(face: FocusTypeFace) {
  focusType.face = face;
  persistFocusType();
}

// --- Writing aids -----------------------------------------------------------
// Opt-in distraction aids for the writing surface: typewriter scrolling
// (keeps the caret line vertically centered) and paragraph focus dimming
// (darkens everything but the caret's paragraph). Both default off and
// persist together, validated field-by-field.

function storedBoolean(field: string): boolean {
  try {
    const raw = JSON.parse(localStorage.getItem(ZEN_STORAGE_KEY) ?? '{}') as Record<string, unknown>;
    return typeof raw[field] === 'boolean' ? (raw[field] as boolean) : false;
  } catch {
    return false;
  }
}

export const focusZen = $state({
  typewriter: false,
  dim: false
});

export function initFocusZen() {
  focusZen.typewriter = storedBoolean('typewriter');
  focusZen.dim = storedBoolean('dim');
}

function persistFocusZen() {
  try {
    localStorage.setItem(ZEN_STORAGE_KEY, JSON.stringify({
      typewriter: focusZen.typewriter,
      dim: focusZen.dim
    }));
  } catch {
    // Persistence is best-effort; the in-session choice still applies.
  }
}

export function setFocusZenTypewriter(on: boolean) {
  focusZen.typewriter = on;
  persistFocusZen();
}

export function setFocusZenDim(on: boolean) {
  focusZen.dim = on;
  persistFocusZen();
}

// Where keyboard focus should land when the overlay closes. App.svelte sets
// this on open (the triggering element) and restores it on close, so Enter on
// the entry button never strands the keyboard in document order.
export let focusReturnElement: HTMLElement | null = null;

export function setFocusReturn(element: HTMLElement | null) {
  focusReturnElement = element;
}

export function openFocusMode(trigger: HTMLElement | null) {
  focusReturnElement = trigger ?? (document.activeElement instanceof HTMLElement ? document.activeElement : null);
  focusMode.open = true;
}

export function closeFocusMode() {
  focusMode.open = false;
}
