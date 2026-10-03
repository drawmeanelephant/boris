- Added opt-in [compiler-owned head metadata](/docs/contracts/head-metadata.md):
  target-local canonical/description, real OpenGraph and explicit Twitter tags,
  exact-page overrides, image preflight, Strict omission/refusal, draft exclusion,
  and shared build/validate semantics. The bounded single-target RSS rider emits
  autodiscovery; article publication dates use existing frontmatter, modification
  dates require explicit configuration. New declarations negotiate plan schema 3;
  existing configurations and profile execution limits otherwise stay unchanged.
