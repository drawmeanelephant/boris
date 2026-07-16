# Fixture: missing wiki heading fragment

`index.md` links `[[guides/target#does-not-exist]]`. Compile must fail with
`EREFERENCEMISSING` and must **not** emit a page-only href.

Normative: `docs/contracts/heading-ids.md`.
