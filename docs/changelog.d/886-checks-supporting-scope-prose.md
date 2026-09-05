### Fixed

- The [publication checks contract](/docs/contracts/publication-checks.md) now states the rendered-search evidence truthfully: the declared supporting scope (and its `supporting_sha256` digest, and the Touch Atlas `artifact-supports-check` edges) covers every committed `html-page` record — the selector vocabulary has no advertised dimension — while the search-document inspection set excludes unadvertised `status: draft` pages per #752. Contract prose only; emitted evidence was already self-consistent (#886).
