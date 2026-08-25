# Archive-layout audit report

**Scope:** deterministic fixture audit only. No graph or layout behavior is
changed by this fixture.

## Automated evidence

| Surface | Evidence |
|---|---|
| Effective layout | `archive.html` is `archive`; `years/2024.html`, `years/2025.html`, and `topics/field-notes.html` are `section`; all direct Satellites are `entry`. |
| Parent and child presentation | `years/2024.html` contains eight direct-child links in entity-id order; `topics/field-notes.html` has no `page-children` wrapper. |
| Navigation and breadcrumbs | All layouts include graph navigation; Satellite pages include the direct parent in a breadcrumb. |
| Nested output links | Child links from `years/2024.html` resolve below `years/2024/`; the SVG sibling asset is published at the matching page-local path. |
| Long lists and titles | Eight 2024 entries include long ASCII and Unicode titles; CSS uses wrapping and a narrow-screen single-column child list. |
| Page content richness | The kickoff page exercises a TOC, table, fenced code, Aside, Details, and a content-local SVG. |
| Empty children | The root archive and `topics/field-notes` are childless Trunks; their layouts render no empty child navigation. |
| Local links | The generated-output link audit reports zero missing local routes or fragments. |
| Determinism | Two clean renders are byte-identical, including copied assets. |

## Mechanical mobile/overflow guardrails

The fixture is not a browser-layout test. The audit harness verifies that the
theme declares a viewport, has a narrow-screen media query, collapses the
child grid to one column, permits long title wrapping, and gives code/table
containers horizontal overflow handling. These are source-level risk guards,
not a claim of cross-browser visual certification.

## Manual review still required

- Inspect the actual visual rhythm of the long 2024 child list at phone,
  tablet, and desktop widths.
- Check keyboard focus order and visible focus treatment in the emitted
  navigation and child lists.
- Validate color contrast if the fixture theme palette changes.
- Decide whether an archive needs an authored chronological order beyond the
  current canonical entity-id ordering; this fixture intentionally does not
  add a sorting feature.
