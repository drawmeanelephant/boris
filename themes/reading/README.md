# Reading

A typesetting theme for pages that are not US-docs English. System font
stacks only. No shipped webfonts, no costume chrome.

`:lang(ja)`, `:lang(zh)`, and `:lang(ko)` raise line-height, set `line-break`,
and refuse italic-as-emphasis. Mark those passages in the content with a
`lang` attribute. The layout root stays `lang="en"`.

- Layouts: `main.html`
- Assets: `assets/reading.css`
- Sample site: [`examples/reading-site/`](../../examples/reading-site/)
- Accessibility: [`ACCESSIBILITY.md`](ACCESSIBILITY.md)

```bash
./zig-out/bin/boris \
  --input examples/reading-site/content \
  --theme themes/reading \
  --html-dir test-output/reading \
  --quiet
```

## Named layouts

Single shape by design. A typesetting theme sets one measure for running
text in any script. A `home`, `section`, `blog`, or `archive` shape would
add chrome around that text, and this theme exists to stay out of its way.
`@media print` already sets the same page for paper, so `print` is
declined too.

## Slot coverage

`{{relations}}` and `{{backlinks}}` sit under the article. Their visible
heading is the compiler's own `aria-label` (via `attr()`), so the theme adds
no English chrome of its own to a page that may not be in English. Both emit
nothing on a page without semantic relations.

Intentionally absent:

- `{{tags}}` — `{{metadata}}` already prints Tags above the article. A chip
  list would repeat it.
- `{{parent}}` — `{{breadcrumb}}` in the header already links the parent.
- `{{page-status}}` — a reading theme stays out of the way. Status is
  already text in `{{metadata}}`; no draft badge is added.
