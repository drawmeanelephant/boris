### Fixed

- The section nav's scrollspy no longer hands `aria-current` to a pane in
  another column. Currency went to the last qualifying section in nav order,
  but the panes sit in three columns — Project and Source, with Graph and
  Publication nested inside Source, and Problems/Preview/Watch in the rail — so
  a jump to Graph settled on Preview, a section parked off the top of the rail.
  It now takes the qualifying section nearest the reading line, which agrees
  with the ordered rule whenever order matches the layout. Links:
  [the component](/editor/ui/src/components/SectionNav.svelte),
  [the spec](/editor/ui/tests/section-nav.spec.ts).
