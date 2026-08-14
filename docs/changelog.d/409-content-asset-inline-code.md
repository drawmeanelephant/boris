<!--
Filename: <pr-number>-<short-kebab-case-summary>.md
Note: renumber to the actual PR number before opening the PR.
-->

### Fixed

- Kept Markdown inline code spans literal during content-local image asset
  rewriting and Aside/Details component tokenization, so `![x](y)`-shaped and
  `<Tag>`-shaped syntax inside backticks (as in image-syntax and raw-HTML
  documentation) no longer fails `EASSET` or `ECOMPONENT`. A span is skipped
  only when a matching equal-length closer exists ahead (mirroring the
  existing wiki-link and include scanners), so an unmatched backtick cannot
  suppress scanning for the rest of the document and a line-start fence run
  cannot close the span state mid-document. Links:
  [content-local assets contract](/docs/contracts/content-local-assets.md),
  [components contract](/docs/contracts/components.md).
