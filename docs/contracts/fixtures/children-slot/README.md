# Children-slot fixture

Acceptance fixture for the bounded `{{children}}` layout slot in
[HTML output](/docs/contracts/html-output.md). The Trunk `index` has direct
Satellites `alpha` and `zeta`; their canonical entity-id order, escaped
title-or-id labels, and page-relative links are the required output behavior.

`satellite.html` is intentionally absent: a Satellite never has direct
children in the one-level Trunk/Satellite graph, so its slot emits empty.
