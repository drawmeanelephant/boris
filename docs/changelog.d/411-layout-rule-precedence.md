### Fixed

- The reference-theme example now states the authoritative layout-rule
  precedence: fixed rank (exact `id:` → most-specific `glob:` → `role:` →
  fallback), order-independent, with equal-specificity matching globs
  rejected as ambiguous. This matches the executable behavior, the
  normative contract in [`templating-and-themes.md`](../contracts/templating-and-themes.md)
  §4.2, and the static-theme-showcase example; the previous
  "declaration order; first match wins" claim was incorrect.
