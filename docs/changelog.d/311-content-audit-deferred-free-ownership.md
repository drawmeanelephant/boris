<!--
Filename: 311-content-audit-deferred-free-ownership.md
Keep exactly one category heading.
-->

### Fixed

- [`boris-content-audit`](/tools/content-audit/) fixes a deferred-free
  ownership error in the reproduction-command placeholder substitution used by
  the shell round-trip test: the intermediate replacement buffers were freed
  through a reassigned local, so both deferred frees acted on the final buffer
  while the first leaked. Each intermediate result is now a distinct constant
  with its own `defer`, making the helper correct under any allocator with an
  effective `free` (the arena allocator previously masked the error). A
  regression test runs the helper under the testing allocator, which detects
  the double free and leak the original code produced.
