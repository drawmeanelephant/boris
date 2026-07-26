### Fixed

- Confined `assemble.scrubStaleAtomicTemps` orphan temp cleanup strictly to the `.boris-cache/` namespace, removing heuristic recursive live-tree deletion so published assets named like `assets/0123456789abcdef` or `assets/worker.tmp` are preserved across failed rebuilds. Links: [HTML output contract](/docs/contracts/html-output.md).
