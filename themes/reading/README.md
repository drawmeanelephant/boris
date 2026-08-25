# Reading

A typesetting theme for pages that are not US-docs English. System font
stacks only. No shipped webfonts, no costume chrome.

`:lang(ja)`, `:lang(zh)`, and `:lang(ko)` raise line-height, set `line-break`,
and refuse italic-as-emphasis. Mark those passages in the content with a
`lang` attribute. The layout root stays `lang="en"`.

- Layouts: `main.html`
- Assets: `assets/reading.css`
- Sample site: [`examples/reading-site/`](../../examples/reading-site/)

```bash
./zig-out/bin/boris \
  --input examples/reading-site/content \
  --theme themes/reading \
  --html-dir test-output/reading \
  --quiet
```
