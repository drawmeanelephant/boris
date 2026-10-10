# HTML 4.01 Strict compatibility theme

Select with `--theme themes/html4-strict --target-profile default=html4-strict`.
The layout supplies the complete Strict DOCTYPE, head, and body; it uses only
HTML 4.01 vocabulary. Boris checks the *assembled page*, including every slot,
before publication. See [the profile contract](../../docs/contracts/html4-strict.md).

This compatibility theme deliberately omits the JavaScript search UI and native
HTML5 disclosure behavior. Aside and Details remain visible, but Details are
always expanded. HTML5 landmarks and ARIA labels are not emitted in this mode.
The default theme and ordinary HTML/XHTML outputs are unchanged.

Accessibility guarantees: [`ACCESSIBILITY.md`](ACCESSIBILITY.md).

## Accessibility floor: what the profile forces

Each floor item was checked against [the profile contract](../../docs/contracts/html4-strict.md).
That contract constrains the **markup** in the assembled page. It does not
constrain the stylesheet, so CSS features are not contract-forced.

| Floor item | Classification | Resolution |
|---|---|---|
| Skip link | Was a defect: HTML 4.01 has `<a href="#id">` and `id` on `div` | Added `div.skip > a` to `#boris.main`, the `div.page` wrapper |
| Focusable skip target | **Contract-forced** | HTML 4.01 allows `tabindex` only on `a`, `area`, `button`, `input`, `object`, `select`, and `textarea`, so the target cannot take `tabindex="-1"`. Browsers still move the sequential-focus start point to the fragment target |
| Landmarks / ARIA labels | **Contract-forced** | Strict chrome replaces `nav`/`section`/`aside` with classed `div` and omits ARIA (contract §Authoring tradeoffs) |
| `:focus-visible` | Was a defect (CSS only) | Added `a:focus-visible`; the legacy `a:focus` rule stays separate so old browsers that drop the unknown selector keep a focus outline |
| `@media print` | Was a defect (CSS only) | Added: hides the skip link, navigation, and TOC; removes width caps; wraps code |
| `prefers-reduced-motion` | Not a defect: the theme emits no motion | Added a guard anyway so later edits cannot add motion for users who asked for none |
| `data-boris-search-*` hooks | **Contract-forced** | `data-*` attributes are outside the Strict vocabulary, and the theme ships no script |
| Search-index hygiene | **Contract-forced** (documented limitation) | See [Rendered-search limitation](#rendered-search-limitation) |

The skip target id is `boris.main`, not `main-content`. Oliver's GFM heading
ids are lowercase slugs without periods, so no auto-generated heading id can
collide with it. A collision would otherwise fail the build with
`EHTML4STRICT` (duplicate document id).

### Rendered-search limitation

Other themes wrap relations/backlinks and layout chrome in
`data-boris-search-exclude`. Here that attribute fails the build with
`EHTML4STRICT` (unsupported attribute). HTML 4.01 also has no `main`,
`nav`, `header`, `aside`, or `footer`, so the extractor falls back to
`<body>`. The compiler drops `dl.page-metadata`, `ul.page-tags`, and
`div.page-parent` by class
([rendered-search contract](../../docs/contracts/rendered-search.md)). The
Strict `div` shapes of `{{nav}}`, `{{breadcrumb}}`, `{{toc}}`,
`{{children}}`, `{{relations}}`, and `{{backlinks}}`, and the skip link, are
indexed as page text. A search index built from this target is therefore
noisier than one built from an HTML5 theme. The layout cannot fix this; it
needs a compiler-side rule.

## Intentionally absent slots

- `{{tags}}` — `{{metadata}}` already prints Tags in the page's `dl`.
- `{{parent}}` — `{{breadcrumb}}` precedes the page and already links the
  parent.
- `{{page-status}}` — Strict forbids `data-status`; a `class` token would
  work, but Status is already text in `{{metadata}}`, and a draft badge is
  not part of this compatibility theme's job.

`{{relations}}` and `{{backlinks}}` are present. Strict chrome drops their
`aria-label` and `data-relation-kind`, so the theme labels them with CSS
generated text ("Related", "Linked from"). The relation kind survives only
as a `semantic-relation--<kind>` class. Kinds are an open vocabulary, so a
stylesheet cannot name every one, and the theme does not print them.
