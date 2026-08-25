### Fixed

- Touch Atlas graph construction (`buildNodesAndEdges` and the expected-graph
  validation helpers) now releases every completed node ID and edge endpoint
  allocation when a later allocation fails, so an out-of-memory path is
  leak-free under a general-purpose allocator. Emitted `touches.json` bytes are
  byte-identical to the PR #294 first slice; new deterministic
  failing-allocator tests and a byte-identity golden pin the unchanged output.
  Links:
  [publication Touch Atlas contract](/docs/contracts/publication-touches.md).
