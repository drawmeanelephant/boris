### Performance

- The output link audit now scans each tag once: href/src/meta-content are
  collected from a single attribute pass instead of re-scanning the tag per
  attribute name, and the next-tag search uses the vectorized stdlib scan.
  Route resolution also skips the decode copy entirely when a target carries
  no percent escapes or separators to normalize. On a 2000-page ReleaseFast
  build the `link_audit` phase dropped ~1.53 s → ~1.03 s (~33%) with
  identical diagnostics and findings.
