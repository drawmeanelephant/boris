### Changed

- Strengthened the developer-only Starlight migration-lab proof
  ([`tools/migration-lab/`](tools/migration-lab/), `--mode=starlight`): content-root
  discovery now supports both `src/content/docs/{locale}/` and default-locale
  files under `src/content/docs/` (no i18n/translation linking); candidate
  selection is deterministic without preferred-section allowlists; link review
  rows cover unresolved routes, fragments, attribute links, MDX, unsupported
  frontmatter, and assets; local asset inventory records existence + SHA-256 when
  a source file is proven (no Boris core asset copy). Added synthetic
  [`mini-starlight-root`](tools/migration-lab/fixtures/mini-starlight-root/) fixture
  alongside [`mini-starlight`](tools/migration-lab/fixtures/mini-starlight/). Real-site
  smoke uses a pinned [withastro/starlight](https://github.com/withastro/starlight)
  docs tree under `/tmp` (read-only; never committed).
