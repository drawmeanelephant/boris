# Documentation Intelligence fixtures

This fixture family exercises the read-only `boris check` and `boris impact`
commands without publishing HTML, IR, RAG, or cache artifacts.

The acceptance tree must include:

- one root Trunk with two Satellites;
- a valid root page with no inbound `reference` edge;
- a shared include referenced by multiple pages;
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
and single-page inputs. The integration test also verifies that analysis does
not create build artifacts or publish a report after invalid input.

The release gate additionally covers source-endpoint impact, missing and
malformed targets, invalid-input publication safety, and empty/single-page
trees. These cases exercise the contract's error boundaries rather than only
the happy-path page report.
