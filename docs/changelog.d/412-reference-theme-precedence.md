### Changed

- The reference-theme example is now guarded by a black-box test
  (`zig build test-reference-theme-layout`, part of `zig build test`): it
  builds with the layout rules in both declaration orders and asserts the
  documented `data-layout` winners on every page, byte-identical output
  trees, and the published theme/page-local assets. The layout-rule
  precedence contract (fixed rank, order-independent) can no longer drift
  silently.
