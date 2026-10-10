# Ledger

Dense early-web knowledge pages. Fake login, reputation, and search chrome
were removed before promotion. Navigation is the graph.

- Layouts: `main.html`
- Assets: `assets/ledger.css` (Verdana / Arial system stack)
- Sample site: [`examples/ledger-site/`](../../examples/ledger-site/)
- Accessibility: [`ACCESSIBILITY.md`](ACCESSIBILITY.md)

```bash
./zig-out/bin/boris \
  --input examples/ledger-site/content \
  --theme themes/ledger \
  --html-dir test-output/ledger \
  --quiet
```

## Named layouts

Single shape by design. In this voice every page is a node: the front page,
a trunk, and a satellite all share the node header, the "Writeups" list
(`{{children}}`), and the Node Tracker. The `garden` starter relies on that
flatness, with dense links between peers rather than a hierarchy of page
kinds. A distinct `home`, `section`, `blog`, or `archive` shape would break
it, and `@media print` already prints a node without the nodelets.

## Slot coverage

- The node header uses `{{page-status}}`, `{{parent}}`, and `{{tags}}`: a
  status flag (red on yellow for drafts), "Parent node:" as a link, and
  bracketed tags. Each piece emits nothing when the page has no value, and
  the bordered strip only draws when one of them is present.
- `{{relations}}` ("Node links") and `{{backlinks}}` ("Softlinks") render as
  a grid of link cells under the writeups. Both emit nothing on a page
  without semantic relations.

`{{metadata}}` is intentionally absent: the three hooks above render the same
Status / Parent / Tags fields, and the parent becomes a link instead of a raw
id.
