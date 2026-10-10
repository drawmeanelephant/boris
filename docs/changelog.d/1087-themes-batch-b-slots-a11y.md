### Changed

- Twelve shipped themes (boris, field-notes, cards, cozy, ledger, reading,
  semantic, columns, civic, tokens, lab, html4-strict) now reach the
  accessibility floor and style every slot they emit. field-notes, cards, and
  cozy gain relations and backlinks. field-notes and ledger replace the flat
  metadata list with the status, parent, and tags hooks. cozy adds a draft
  stamp. Light-mode focus rings below 3:1 are fixed in five themes. ledger and
  html4-strict gain print styles, and html4-strict gains a skip link and
  `:focus-visible`. Each theme now ships `ACCESSIBILITY.md`, and its README
  lists the slots it leaves out and why. Links:
  [theme slot contract](/docs/contracts/templating-and-themes.md),
  [HTML 4.01 Strict profile](/docs/contracts/html4-strict.md),
  [#1047](https://github.com/drawmeanelephant/boris/issues/1047),
  [#1048](https://github.com/drawmeanelephant/boris/issues/1048).
- Eleven of those themes (all but html4-strict) keep layout text out of the
  rendered-search index. Relations and backlinks sit in a `graph-links`
  wrapper marked `data-boris-search-exclude`, as in the other ten themes.
  Children panels, kickers, sidebar headings, and layout title `h1`s are
  excluded too. A page's search entry now holds only its authored text.
  html4-strict cannot carry the attribute, so its README documents that its
  index includes navigation and relation link text. Link:
  [rendered-search contract](/docs/contracts/rendered-search.md).
