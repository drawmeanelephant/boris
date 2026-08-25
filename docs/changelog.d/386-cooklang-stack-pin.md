### Changed

- Boris now consumes Oliver's Cooklang stack as a **second, separately pinned
  Oliver dependency** (`.oliver_cooklang`, Oliver `main`) while the renderer
  stays pinned to the `boris-markdown-extensions` branch. The two feature sets
  live on different Oliver revisions while [oliver#39] is embargoed; when it
  merges, the dual pin collapses to one and `.oliver_cooklang` is deleted. See
  [the Oliver renderer contract](/docs/contracts/oliver-renderer.md).
