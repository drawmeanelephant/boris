# Ledger

Dense early-web knowledge pages. Fake login, reputation, and search chrome
were removed before promotion. Navigation is the graph.

- Layouts: `main.html`
- Assets: `assets/ledger.css` (Verdana / Arial system stack)
- Sample site: [`examples/ledger-site/`](../../examples/ledger-site/)

```bash
./zig-out/bin/boris \
  --input examples/ledger-site/content \
  --theme themes/ledger \
  --html-dir test-output/ledger \
  --quiet
```
