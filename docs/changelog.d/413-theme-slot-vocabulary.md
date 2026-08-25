### Fixed

- The theme slot contract now states the multiplicity and empty-output rules
  explicitly: the ten slot markers are single-use (`{{content}}` exactly
  once), the `{{asset-url PATH}}` helper is **repeatable**, and a slot that
  is omitted or empty for a page emits no wrapper of its own. The
  reference-theme and static-theme-showcase example docs teach the same
  contract their layouts already exhibit. See
  [`templating-and-themes.md`](../contracts/templating-and-themes.md) §3.
