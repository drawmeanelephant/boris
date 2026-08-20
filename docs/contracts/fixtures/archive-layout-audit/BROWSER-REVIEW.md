# Archive-layout browser review

**Scope:** real-browser evidence pass over the retained fixture (STATUS roadmap
item 2 — the manual review that `REPORT.md` still requires). The evidence-gated
presentation fix it led to (roadmap item 3) accompanies this document in the
same change set and is recorded under Finding 1.

**Date:** 2026-08-20 · **Build:** merged `afterparty` tip (`121a13ac`), `boris/0.8.1`.
**Fixture build:** the exact command in this directory's `README.md` (id:archive →
`archive.html`, role:trunk → `section.html`, Satellites → main fallback) into the
gitignored `test-output/archive-layout-audit-review/`.

**Method:** the built site was served over loopback HTTP and rendered in a real
Chromium browser (the Freebuff preview browser). A same-origin harness embedded
the page under review in fixed-width iframes at **375px, 768px, and 1440px** so
the theme's media queries applied at exact phone/tablet/desktop widths.
Measurements came from live DOM geometry (`scrollWidth`/`clientWidth`,
`getBoundingClientRect`, computed styles). Keyboard traversal was a programmatic
focus walk over every focusable element in document order (a Tab proxy; see the
residual note below).

## Results

| Page | 375px | 768px | 1440px |
|---|---|---|---|
| `years/2024.html` (long child list) | 1-col child grid; **0** px doc overflow | 2-col grid; **0** px | 2-col grid; **0** px |
| `years/2024/010-kickoff.html` (TOC/table/code/Aside/Details/SVG) | **0** px doc overflow (fixed) | 0 px | 0 px |
| `years/2024/060-table-scraps.html` | **0** px doc overflow (fixed) | 0 px | 0 px |
| `years/2024/070-code-observation.html` (`pre`) | 0 px | — | 0 px |
| `archive.html` (empty children) | 0 px; no child nav | — | 0 px |
| `topics/field-notes.html` (empty children) | 0 px; no child nav | — | — |

All widths: `masthead`, `site-nav`, `crumbs`, long ASCII and Unicode titles, and
`pre` blocks wrap or scroll internally with **no horizontal page overflow**.
The child grid collapses 2 columns → 1 column below the theme's `42rem`
breakpoint as intended, and childless pages render no empty child navigation.

## Finding 1 — Confirmed defect: table pages overflow horizontally at phone width

At a 375px viewport, any page containing a `<table>` breaks the page layout
with horizontal document overflow (measured `body.scrollWidth` 512 vs 375,
i.e. **137–145 px** of overflow). The table renders 512 px wide inside a 359 px
container instead of scrolling internally.

**Locus:** `theme/assets/archive-audit.css`:

```css
table { min-width: 32rem; border-collapse: collapse; }   /* 32rem = 512 px */
pre, table { display: block; max-width: 100%; overflow-x: auto; }
```

**Root cause:** `min-width: 32rem` (512 px) beats the table's own
`max-width: 100%` (min-width wins when it exceeds max-width), and because
`overflow-x: auto` sits on the table element itself, the *page* scrolls
horizontally at any viewport narrower than ~529 px rather than the table
scrolling internally. `pre` has the same overflow rule but no `min-width`, so
it shrinks to the container and behaves correctly — confirming the min-width is
the trigger.

**Impact:** both table-bearing entry pages (`010-kickoff`, `060-table-scraps`)
are affected at phone widths; tablets/desktop are unaffected. The mechanical
audit harness (`test/archive-layout-audit.sh`) only checks that an
`overflow-x` rule exists at source level, so it passes while this page-level
break goes unseen — exactly the "not a claim of cross-browser visual
certification" caveat `REPORT.md` records.

**Resolution (roadmap item 3, 2026-08-20):** the horizontal overflow moved to
the table's parent — `article { max-width: 72ch; overflow-x: auto; }` in
`theme/assets/archive-audit.css`. The table keeps its readable 512 px minimum
and scrolls internally within the article at phone widths while the page stays
fixed. Re-verified in the same browser harness after the change:

| Page | 375px | 768px | 1440px |
|---|---|---|---|
| `010-kickoff` | page overflow **0**; article scrolls internally (512 px table) | 0; table fits | 0; fits |
| `060-table-scraps` | page overflow **0**; article scrolls internally | 0; fits | 0; fits |
| `years/2024.html` (no table) | 0; **no spurious scrollbar** | 0 | 0 |

`test/archive-layout-audit.sh` still passes. Note for a future reviewer: the
mechanical harness still cannot see this class of page-level break — only a
real-browser pass (this harness or a browser test) covers it.

## Finding 2 — Recorded observation: no theme-defined focus treatment

The fixture theme defines **no** `:focus`/`:focus-visible`/`outline` rules
(verified in `archive-audit.css`). All 21 focusable elements on
`years/2024.html` accept focus in document order with no `tabindex` anywhere
(natural Tab order), and every focused element stays inside the viewport
horizontally at 375px and 1440px. Visible focus therefore relies entirely on
the browser's default focus ring. Not a defect for an acceptance fixture, but
recorded: if this theme is ever promoted to a shipping surface, an explicit
`focus-visible` treatment should be added and keyboard-certified.

## Residual

- A real trusted-key Tab traversal and screen-reader order audit still need a
  human (or a raw-input test tool): programmatic focus cannot trigger the
  browser's `:focus-visible` keyboard heuristic, so the default ring's actual
  appearance was not observed here.
- Color-contrast review of the fixture palette (REPORT.md item) remains a
  human/vision pass.
