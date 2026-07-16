# Documentation Intelligence fixtures (planned acceptance)

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

The corresponding JSON and human-output goldens are committed beside this
README. The integration test also verifies that analysis does not create build
artifacts.
