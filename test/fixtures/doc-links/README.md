# Documentation-link HTML fixture

This focused fixture exercises graph-backed Markdown documentation-link
rewriting through the real HTML compiler path.

`content/guides/start.md` includes:

- a nested Markdown link to `reference.md`, rewritten relative to the output;
- a page-local SVG image copied from `start.assets/`;
- a fenced Markdown example whose `.md` link remains literal; and
- a raw HTML anchor whose `.md` destination remains unchanged.

The golden HTML and copied asset under `expected/` are the contract. The
compile test also renders the fixture twice and compares every expected output
byte-for-byte.
