### Changed

- Seven personal-voice themes (press, cozy, journal, ledger, field-notes,
  cards, reading) now style every authored construct in their own voice:
  all five Aside kinds are told apart, and Details, definition lists,
  footnotes, figures and captions, blockquotes, `hr`, `h4`, and Markdown
  table alignment no longer fall back to browser defaults. Images no longer
  overflow the column in journal, ledger, cards, and reading. Visited and
  current-page link states are styled to match each voice. Breadcrumbs in
  cozy, journal, and ledger are inline trails instead of numbered lists.
  journal and cozy no longer put the site name in an `h1`, so the page
  title is each page's only `h1`. cards keeps nested navigation below
  42rem. Children panels in press, cozy, ledger, field-notes, and cards
  hide when the page has no children. reading still adds no English of its
  own and keeps its `:lang(ja|zh|ko)` rules. Each theme's
  `ACCESSIBILITY.md` records the new contrast figures. Links:
  [theme catalog](/themes/README.md),
  [theme slot contract](/docs/contracts/templating-and-themes.md),
  [#1049](https://github.com/drawmeanelephant/boris/issues/1049).
