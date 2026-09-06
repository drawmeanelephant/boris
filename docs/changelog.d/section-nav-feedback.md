## Editor: section navigation gives arrival feedback (#941)

The section nav is no longer seven silent hash anchors.

- **Arrival highlight**: activating a nav link focuses the target section and
  pulses it (border + ring) for ~1.6s; the cue reduces to a static highlight
  under `prefers-reduced-motion`.
- **Scrollspy**: `aria-current="true"` and an active pill follow the section
  at the reading top, with a bottom rule so the last section stays current
  where the page clamps at max scroll.
- **Sticky nav**: the nav sticks below the viewport top, and target sections
  carry a `scroll-margin-top` sized from the measured nav height
  (`--section-nav-h`), so landed sections sit just below the bar instead of
  flush under it.
- **Focus hand-off**: all nav targets are now programmatic focus targets
  (`tabindex="-1"`), and nav activation moves focus with the jump — the next
  Tab continues from the landed section. Modifier-clicks keep native
  hash-link behavior.
- **Edge affordance**: on narrow viewports the scrollable pill row shows edge
  bars for content beyond the clip, and the active pill auto-scrolls into
  the visible strip.

Also fixes the duplicate `id="graph"` between the Source pane's graph
empty-state (now `id="graph-empty"`) and the real GraphPane.
