### Changed

- Reuse caller-owned path and link buffers while rendering [navigation and wiki-links](/docs/contracts/includes-and-wiki-links.md), reducing temporary allocations without changing rendered bytes, escaping, fragments, or nested relative links.
