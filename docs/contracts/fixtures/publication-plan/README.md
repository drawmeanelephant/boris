# Publication-plan fixtures

These profiles exercise the first `boris plan --profile PATH` declaration
surface. The expected files are canonical bytes emitted from the normalized
`PublicationPlan`; they are not publication output or proof artifacts.

- `minimal/` covers one public HTML target with the managed Boris theme.
- `full/` covers canonical target and layout-rule ordering, public projections,
  and all three machine editions.
- `nostr/` covers a profile with a configured `nostr` section: the emitted
  declaration gains the closed conditional `nostr` object after `editions`
  (#885).
