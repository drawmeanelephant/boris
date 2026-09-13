### Changed

- Author mode stops reading as an equal-card dashboard: Project is demoted to a
  file drawer under the writing page (no shared height, elevation, or heavy
  edge) instead of a peer card, the section nav leads with Project and Source
  while the Review destinations recede into a captioned, faint cluster that
  still switches modes and lands on activation, and Source takes page material
  rather than a wider dashboard tile — no card elevation, a focus-within edge,
  and a readable-measure cap centered in its column on wide windows, so the
  pane edge is the page edge and heading, editor, gutter, and status line share
  one column. The top band quiets too: the header drops its decorative eyebrow
  so the product mark and the live connection status share one row, the
  connection readout collapses to a compact state chip whose honest sentence is
  one activation away (the live region announces the short label rather than
  re-reading a sentence), the theme control states only its state, and Author
  takes a smaller product mark and tighter header/nav bands than Review. Links:
  [the editor
  guide](/content/guides/editor.md#density-modes-and-the-writing-surface),
  [#993](https://github.com/drawmeanelephant/boris/issues/993).

### Fixed

- Review corrections to the Author surface above. The Author app title step is
  its own link in the type chain (`--text-2xl-compact`) rather than the
  pane-title size, which had made `h1` exactly as large as the pane titles it
  outranks. The theme control drops `aria-pressed`: a pressed state presumes a
  name that does not change with it, and here the changing label *is* the
  state. The Author Source textarea keeps no focus ring of its own now that the
  shell owns one, so the page shows a single edge instead of a frame within a
  frame. The connection readout's live region is text-only, matching every other
  status region in the editor, with the disclosure chip as a sibling rather than
  a button nested inside an atomic region.

### Added

- Every ordered scale the editor declares — the type chain, the spacing rhythm,
  the corner steps, and the stacking ladder — now writes its order down exactly
  once, in a `--scale-*` list in `editor/ui/src/lib/tokens.css`, and nothing
  else keeps a copy. `--scale-space-base` declares the spacing rhythm's base
  instead of describing it in prose, and the six bare `z-index` values in
  `styles.css` became `--layer-*` names, so the ladder is the only authority on
  stacking order.
- `editor/ui/scripts/check-scales.mjs`, run by `npm run check`, holds the static
  half: every declared token of each family is classified, every listed name
  exists, each list ascends (numerically where a value is resolvable without a
  viewport, and reported as deferred where it is a `clamp`), spacing steps are
  whole multiples of the declared base, the layer ladder holds bare numbers,
  every scale token is declared once and only in `tokens.css`, every `var()`
  reference lands on a declared step, no `z-index` is a bare number, and each
  documented section names its scale's list without naming tokens that do not
  exist. It runs its own self-tests first, so the checker is checked.
- `editor/ui/tests/scales.spec.ts` holds the half that needs a viewport. It
  resolves the same lists out of the *applied* stylesheet at four widths, which
  is the only way to check a `clamp` step, a value overridden further down the
  cascade, or the rhythm's base — and it asserts that the sticky nav and the
  skip link carry the declared layer rather than a loose number. The rendered
  heading levels stay in `editor/ui/tests/reading-hierarchy.spec.ts`, now
  measured in both density modes.
- That last point is why any of this exists: the prior hierarchy suite pinned
  Review density only, so an Author-only override could flatten the app title
  onto the pane-title size with every suite green. Which is exactly what
  happened, and what these scales are now walked against.
