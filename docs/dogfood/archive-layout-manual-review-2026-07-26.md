# Archive-layout manual review evidence — 2026-07-26

**Mode:** evidence-only. This review does not change graph, HTML, CSS, or
layout behavior. It reviews the deterministic archive fixture at
`docs/contracts/fixtures/archive-layout-audit/` on `afterparty` base
`c87bee3`.

## Reproducible evidence

- Built the fixture into `test-output/archive-layout-audit/` with its documented
  archive and Trunk layout rules. The render produced 13 HTML files.
- The standalone generated-output link audit scanned those 13 files and found
  **0** missing local routes or fragments.
- `test/archive-layout-audit.sh` passed with an allowed Zig cache, including its
  clean-render byte comparison and source-level overflow guardrails.
- Static emitted-output inspection confirms the long title is present in both
  navigation and the 2024 child list, and the child list runs from
  `010-kickoff` through `080-last-light` in entity-id order.

## Findings

| ID | Page / viewport / repro | Expected | Actual evidence | Severity / type | Classification | Smallest remediation boundary |
|---|---|---|---|---|---|---|
| AR-M1 | `years/2024.html`; mobile (375px), tablet (768px), desktop (1440px). Open the retained output at each viewport and inspect the long child title, two-column-to-one-column transition, and table/code overflow. | No viewport-width overflow; readable wrapped child title; child list is one column at narrow widths. | **Unverified visual result.** Source CSS declares a viewport meta tag, `overflow-wrap: anywhere`, horizontal overflow for `pre, table`, and a `42rem` one-column media query; this is only a mechanical guardrail. No local browser automation/screenshot renderer was available to measure these viewports. | Unrated / visual layout | Insufficient evidence | Run this exact fixture in a browser with 375/768/1440px viewports; record actual overflow and screenshots only if project policy permits. Change CSS/layout only after a reproduced issue. |
| AR-M2 | `years/2024.html` and `years/2024/010-kickoff.html`; keyboard-only Tab / Shift+Tab at mobile, tablet, and desktop widths. | Logical focus traversal through navigation, breadcrumbs, children, and content links, with a visible focus indicator. | **Unverified browser result.** Emitted DOM has navigation before breadcrumbs, then child navigation (where present), then article content. Fixture CSS has no explicit `:focus` or `outline` rule, so browser-default focus treatment cannot be certified from static inspection. | Unrated / keyboard accessibility | Insufficient evidence | Browser keyboard pass on the retained output. If focus is not visibly perceivable or traversal is confusing, make the smallest fixture/layout CSS remediation and add a focused regression check. |
| AR-M3 | All generated fixture pages; run link audit against retained output. | Every local route and heading fragment resolves. | **Verified:** 13 HTML files scanned; 0 local-link findings. | None / generated-link integrity | Non-issue | No change. Preserve the black-box link-audit step in future archive-layout work. |
| AR-M4 | `years/2024.html`; inspect generated child navigation. | Direct children remain entity-id ordered; no accidental recursive/archive chronology claim. | **Verified:** emitted links begin at `2024/010-kickoff.html` and end at `2024/080-last-light.html`; fixture contract explicitly limits the list to direct children. | None / scope boundary | Non-issue | No change. Any chronological ordering proposal needs separate authored-order semantics and contract work. |

## Review boundary

This pass found no confirmed layout defect. AR-M1 and AR-M2 remain deliberately
unverified rather than inferred from CSS or a happy-path build. The next card is
a browser-assisted viewport and keyboard evidence pass against the retained
fixture; it is not permission to change layout behavior preemptively.
