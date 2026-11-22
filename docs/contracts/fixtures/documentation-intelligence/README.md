# Documentation Intelligence fixtures

This fixture family exercises the read-only `boris check` and `boris impact`
commands without publishing HTML, IR, RAG, or cache artifacts.

The acceptance tree must include:

- one root Trunk with two Satellites;
- a valid root page with no inbound `reference` edge;
- a shared include referenced by multiple pages;
- an include-consumed page outside the reserved `includes/` library, proving
  composition counts as inbound use and is never flagged unreferenced;
- a multi-hop reference/include impact chain;
- deterministic output after shuffled fixture creation order;
- invalid graph and missing-target cases proving analysis does not run on an
  unfrozen graph.

The checked-in content tree is the deterministic acceptance input. From the
repository root, the expected commands are:

```text
boris check --input docs/contracts/fixtures/documentation-intelligence/content --format json
boris impact guides/reference --input docs/contracts/fixtures/documentation-intelligence/content --format json
```

The corresponding JSON and human-output goldens, including source-endpoint
impact, are committed beside this README. The `edge-cases/` trees cover empty
and single-page inputs, `flat/` (a multi-page corpus with no `parent`,
`include`, or `reference` edges that exercises `flat_graph`, `unlinked_page`,
`zero_includes`, `zero_relations`, and their `--fail-on-*` opt-ins),
`draft/` (a linked corpus with one `status: draft` page alongside `published`,
`archived`, and unset-status pages, plus committed JSON and human goldens,
exercising `draft_page` and `--fail-on-draft`), and `stale/` (a linked corpus
mixing an aged `published_at` page, an exact-boundary page, a fresh page, a
future-dated page, and an undated page, plus committed JSON and human goldens
for `--as-of 2026-06-01 --max-age-days 90`, exercising `stale_page` and
`--fail-on-stale`). The integration test also verifies that analysis does
not create build artifacts or publish a report after invalid input.

The same frozen graph is rendered by `boris graph`, with both outputs pinned
beside those goldens:

```text
boris graph --input docs/contracts/fixtures/documentation-intelligence/content
boris graph --input docs/contracts/fixtures/documentation-intelligence/content --format dot
```

`expected/graph.mmd` and `expected/graph.dot` are byte-exact goldens; the
integration test re-renders them in-process. The render contract is
[`graph-formats.md`](../../graph-formats.md).

The release gate additionally covers source-endpoint impact, missing and
malformed targets, invalid-input publication safety, and empty/single-page
trees. These cases exercise the contract's error boundaries rather than only
the happy-path page report.
