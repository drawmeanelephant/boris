# Additive theme metadata hooks fixture (#1007)

Exercises the F9.1 follow-on hooks that let a theme style page metadata
without JavaScript, alongside the frozen `{{metadata}}` `<dl>`:

- `{{page-status}}` — repeatable, argument-free token emitting the closed
  status name (`draft` / `published` / `archived`) or the empty string;
  attribute-safe by construction (here `data-status` on `<html>` and a
  `status-*` class on `<body>`).
- `{{tags}}` — once-per-layout slot emitting
  `<ul class="page-tags"><li>…</li></ul>` from closed `tags` frontmatter;
  empty when the page has no tags. The emitted list is compiler chrome and is
  excluded from the rendered-search index (`rendered-search.md`).
- `{{parent}}` — once-per-layout slot emitting a direct-parent
  `<nav class="page-parent">` link with the resolved title-or-id label,
  resolved from the frozen graph; empty for Trunks. The raw parent id stays in
  the frozen `{{metadata}}` `<dl>`.

```text
content/index.md                    Trunk: no status/tags/parent (empty states)
content/guides.md                   Trunk: status published, no tags
content/guides/getting-started.md   Satellite: draft, two tags, parent guides
layouts/main.html                   uses all three hooks plus {{metadata}}
```

Expected output (`guides/getting-started.html`):

- `<html data-status="draft">` and `<body class="status-draft">`
- `<nav class="page-parent" aria-label="Parent"><a href="../guides.html">Guides</a></nav>`
- `<ul class="page-tags"><li>guides</li><li>onboarding</li></ul>`
- the unchanged `<dl class="page-metadata">` with the raw parent id

Empty states (`index.html`): `data-status=""`, no `.page-tags` or
`.page-parent` element, and no `.page-metadata` block at all.
