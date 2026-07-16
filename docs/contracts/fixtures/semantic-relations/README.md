# Fixture: semantic relations

**Contract target:** IR `schemaVersion` `0.3.0` when a page declares semantic relations.

`guides/cache-v2` declares two bounded semantic relations. The target pages are
ordinary graph nodes; the relations are emitted separately from build edges and
are sorted deterministically. The fixture also exercises all four relation
kinds and includes a wiki-link/include build dependency to prove the arrays
remain separate.
