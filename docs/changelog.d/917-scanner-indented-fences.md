### Fixed

- Fence-aware scanners honor CommonMark-indented (`≤3`-space) fenced code blocks: wiki-links (#858), include directives (#859), and content-local images (#869) inside indented fences — including unterminated fences — stay literal instead of failing the build or corrupting published code samples. The image scanner additionally leaves top-level 4-space indented code blocks literal while still validating list-nested images ([includes-and-wiki-links](/docs/contracts/includes-and-wiki-links.md), [content-local-assets](/docs/contracts/content-local-assets.md)).
