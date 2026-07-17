### Docs

- Re-audit Filed.fyi / Starlight archive image layout after PR #131: F-L1
  relative image → `{stem}.assets/` is **CLOSED** on the image-path and
  dogfood fixtures; missing/escape still fail loud with `EASSET`; F-L2 Unicode
  asset-filename sanitization remains separate and non-blocking. No product
  code changes.
  Links: [archive layout audit](/docs/dogfood/filed-fyi-archive-layout-audit.md),
  [migration-lab README](/tools/migration-lab/README.md),
  [image-path fixture](/tools/migration-lab/fixtures/image-path-starlight/README.md).
