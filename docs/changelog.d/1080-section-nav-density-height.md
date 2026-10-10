### Fixed

- Editor: `--section-nav-h` now tracks the section nav's live height — a
  `ResizeObserver` on the band plus a re-measure before a mode-gated jump —
  so a pane landed after an Author → Review density switch parks below the
  nav instead of too tight under the stale margin (#1078). Links:
  [SectionNav.svelte](/editor/ui/src/components/SectionNav.svelte),
  [section-nav.spec.ts](/editor/ui/tests/section-nav.spec.ts).
