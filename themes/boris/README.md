# Boris (default)

The product default. Orange accent, sticky rail, slightly-too-large type.
That oddness is the point — do not sand it into another calm docs skin.

- Layouts: `main.html`
- Assets: `assets/css/boris.css` (system UI stack; no webfont)
- Footer: `footer.html`
- Search: first-party inline consumer; nav remains the no-JS path
- Slots: title, head, nav, breadcrumb, toc, metadata, content, children, relations, backlinks, footer, asset-url
- Accessibility: [`ACCESSIBILITY.md`](ACCESSIBILITY.md)
- Specimens: the repository's own [`content/`](https://github.com/drawmeanelephant/boris/tree/main/content/) docs site
  (the command below, run from the repository root), and the shared
  [`examples/studies-site/`](https://github.com/drawmeanelephant/boris/tree/main/examples/studies-site/) corpus

```bash
./zig-out/bin/boris --theme themes/boris --html-dir dist --quiet
```

## Named layouts

Single shape by design. `layouts/main.html` is the product default, the
last fallback in layout selection
([contract §4.2](https://github.com/drawmeanelephant/boris/blob/main/docs/contracts/templating-and-themes.md#42-precedence)),
so it has to serve every page of any graph, from a one-page tree to this
repository's docs. The sticky rail, search, and outline already work at
every depth. Docs sites that want `home` / `section` shapes have
`reference`, `engineering`, and `semantic`. This theme is also what
`boris init --type docs` ships
([#1063](https://github.com/drawmeanelephant/boris/issues/1063)), so the
starter gets the same single shape.

## Intentionally absent slots

- `{{tags}}` — `{{metadata}}` already prints Tags in the page header. A second
  per-tag list would repeat it on every tagged page.
- `{{parent}}` — `{{breadcrumb}}` sits directly above `main` and already links
  the parent.
- `{{page-status}}` — `{{metadata}}` prints Status as text. The product default
  does not add a draft badge on top of that.
