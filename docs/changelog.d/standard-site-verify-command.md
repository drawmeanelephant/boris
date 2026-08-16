- `boris standard-site verify --profile PATH [--dist DIR] [--out PATH]`
  cross-checks the built output against the freshly rendered projection
  offline: each eligible page's `site.standard.document` head link and the
  well-known file (or its base-path sideband) are compared byte-for-byte.
  Missing or mismatched surfaces fail with exit code 8 and zero writes; the
  result is a deterministic `boris-standard-site-verify` (schema v1) artifact.
  No discovery, OAuth, transport, or mutation.
