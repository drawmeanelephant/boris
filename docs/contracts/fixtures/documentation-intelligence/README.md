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

The first implementation slice is covered by focused analysis and CLI parser
tests plus the release-gate build. Checked-in JSON and human-output goldens are
the next hardening task before this contract is promoted from planned to a
fully release-gated feature.
