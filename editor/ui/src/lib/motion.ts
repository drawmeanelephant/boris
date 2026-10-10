// Svelte transitions run in JS, so they read their durations from the same
// `--motion-*` tokens the stylesheet uses (lib/tokens.css stays the only copy)
// and collapse to zero under prefers-reduced-motion.

import { prefersReducedMotion } from 'svelte/motion';

export type MotionStep = 'fast' | 'base' | 'slow';

export function motionMs(step: MotionStep): number {
  if (prefersReducedMotion.current) return 0;
  const raw = getComputedStyle(document.documentElement).getPropertyValue(`--motion-${step}`).trim();
  const value = Number.parseFloat(raw);
  if (!Number.isFinite(value)) return 0;
  return raw.endsWith('ms') ? value : value * 1000;
}
