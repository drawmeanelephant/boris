### Fixed

- The section nav's scrollspy no longer hands `aria-current` to the wrong pane
  when the panes are laid out in columns that disagree with nav order. Currency
  went to the last qualifying section in nav order, so a jump to Graph settled
  on Preview — a pane parked off the top of the rail and clipped — and the
  reading line sat a nav height *below* where a jump actually parks a pane,
  which let a neighbouring pane score as nearer the line at some widths. It now
  takes the qualifying section nearest the line, measured at that pane's own
  scroll-margin-top, and the pane a jump just landed on wins a tie against one
  sharing its offset in another column. The e2e suite pins the resulting
  contract across the desktop three-column, narrow two-column, and mobile
  single-column layouts, so a pane that reintroduces the order-versus-layout
  divergence fails loudly instead of silently mislabelling the active pane.
  Links:
  [the component](/editor/ui/src/components/SectionNav.svelte),
  [the spec](/editor/ui/tests/section-nav.spec.ts).
