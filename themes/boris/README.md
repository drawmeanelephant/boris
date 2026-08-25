# Boris (default)

The product default. Orange accent, sticky rail, slightly-too-large type.
That oddness is the point — do not sand it into another calm docs skin.

- Layouts: `main.html`
- Assets: `assets/css/boris.css` (system UI stack; no webfont)
- Footer: `footer.html`
- Search: first-party inline consumer; nav remains the no-JS path
- Slots: title, head, nav, breadcrumb, toc, metadata, content, children, relations, backlinks, footer, asset-url

```bash
./zig-out/bin/boris --theme themes/boris --html-dir dist --quiet
```
