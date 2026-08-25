### Changed

- The `zig build test-doc-links` guard's whole-tree and link-level
  exclusions moved into an explicit manifest
  ([`scripts/doc-links-exclusions.txt`](/scripts/doc-links-exclusions.txt))
  with a comment per entry, and the guard fails hard on a missing or
  unparseable manifest — future exclusions are deliberate, reviewed acts
  rather than silent blind-spot widening. Also restored reference-style
  link checking on macOS CI (`\S` → POSIX character class).
