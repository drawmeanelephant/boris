---
title: "`src/html_body.zig` evidence and cases"
id: docs/boris/src/html_body/evidence-and-cases
parent: docs/boris/src/html_body
status: draft
tags: [boris, zig, source-reference, evidence, html_body]
---

# `src/html_body.zig` evidence and cases

## Tested declarations and entry points

| Declaration or test | Kind | Purpose | Inputs or setup | Expected result | Contract exercised |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `test "component diagnostics use ECOMPONENT and full-source locator"` | Unit test | Verify that `componentDiagnostic` produces the correct `diag.Code`, line number, and formatted string for a component error at a known source offset | Inline source string with frontmatter (3 header lines + blank + heading + blank = body starts at line 4); `aside.Diagnostic` with `line=4, column=1` | `code == .ECOMPONENT`, `line == 7` (4 header lines + 3 body lines), `column == 1`, formatted text matches exact string | Line-number reconstruction across the frontmatter/body boundary; `ECOMPONENT` code assignment; `diag.formatText` integration |
| `test "shared body pipeline preserves include wiki Aside render order"` | Integration test | Verify that all six pipeline stages run in the documented order by checking byte-offset ordering of known output tokens | Real `tmpDir` with an `includes/fragment.md` file; source with `&#123;&#123;include&#125;&#125;`, `&#91;&#91;wiki-link&#93;&#93;`, `&lt;Aside kind="tip">`, surrounding prose | `before < included < wiki < aside_at < after` in the HTML output | Pipeline stage ordering contract; all six stages must execute and produce recognisable output |


***
