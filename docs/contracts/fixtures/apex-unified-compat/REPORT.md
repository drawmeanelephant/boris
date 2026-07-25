# Apex Unified compatibility audit report

**Date:** 2026-07-21
**Branch:** `afterparty`
**Base:** fresh `origin/main`  
**Scope:** Read-only compatibility matrix for ApexMarkdown Unified features
documented in `vendor/apex-markdown/pages/index.md`, exercised **through Boris**
(not a second renderer).  
**Non-goals:** No product-code fixes; no Textile branch changes.

| Artifact | Path |
|----------|------|
| Matrix | [`MATRIX.md`](MATRIX.md) |
| Fixtures | `content/`, `theme/`, `assets/` |
| Host ABI contract | [`../../apex-abi.md`](../../apex-abi.md) |
| Fidelity unit tests | `src/apex.zig` (U1–U18) |

---

## Method

1. Checked out `origin/main` onto `grok/apex-feature-matrix`.
2. Built the product binary (`zig build`).
3. Added a dependency-free Trunk/Satellite fixture site under this directory.
4. Compiled with Boris HTML mode (minimal theme layout, content-only body).
5. Inspected emitted HTML markers; ran isolated single-page probes under
   `test-output/apex-probes/` for surprising cases.
6. Cross-checked host options (`vendor/apex/apex.c` → `boris_apex_options`) and
   existing Apex fidelity tests.
7. Classified every material feature as **1–4** (see matrix legend). Did not
   patch defects.

### Compile command used for the fixture site

```bash
zig build

./zig-out/bin/boris \
  --input docs/contracts/fixtures/apex-unified-compat/content \
  --theme docs/contracts/fixtures/apex-unified-compat/theme \
  --html-dir test-output/apex-unified-compat \
  --quiet
# exit 0
```

---

## Gate results

| Gate | Result | Notes |
|------|--------|-------|
| `zig build` | **PASS** | Pre-audit binary build |
| Fixture HTML compile (command above) | **PASS** (exit **0**) | 1 trunk + 14 feature pages |
| `zig build test` | **PASS** | **2511/2511** tests; includes Apex U-fidelity |
| `zig build test-apex-hostile` | **PASS** | Host ABI status-first hostile engine |

Exact commands and outcomes from this audit session:

```text
$ zig build
# exit 0

$ ./zig-out/bin/boris --input docs/contracts/fixtures/apex-unified-compat/content \
    --theme docs/contracts/fixtures/apex-unified-compat/theme \
    --html-dir test-output/apex-unified-compat --quiet
# exit 0

$ zig build test --summary all
# Build Summary: 49/49 steps succeeded; 2511/2511 tests passed

$ zig build test-apex-hostile
# exit 0
```

---

## Primary findings (do not fix in this PR)

### Confirmed surprising / broken (class 4)

1. **Per-cell table alignment markers corrupt text**  
   Input cell `:Center:` / `:center:` becomes the literal text **`cancer`**
   (emoji shortcode / autocorrect path). Alignment attributes are not applied.
   Probe: `test-output/apex-probes/per-cell/`, cell variant loop in audit session.

2. **Table caption association leaks**  
   A trailing `Table: …` caption correctly wraps the preceding table in
   `<figure><figcaption>`, but also sets `data-caption="…"` on an **earlier**
   table on the same page. Probe: `test-output/apex-probes/caption/`.

3. **Headerless tables are unreliable**  
   Separator-first tables produce empty tables or odd `th scope=row` shapes
   depending on surrounding content; body rows may fall out as paragraphs on
   multi-section pages.

4. **Image IAL attributes drop after a plain image**  
   Pandoc/Kramdown image IAL (`{width=120px .class}`, `{: width="50%"}`) applies
   correctly when IAL images appear first. After any plain `![alt](src)` on the
   same page, later IAL images lose `width` / `class` / `style`. Fixture page
   `features/images` encodes this ordering probe.

5. **IMPORTANT / CAUTION callout kinds alias**  
   `> [!IMPORTANT]` → `callout-tip`; `> [!CAUTION]` → `callout-warning`. Titles
   become `tip` / `warning`, not distinct kinds.

6. **Definition-list nested blocks escape `<dd>`**  
   A list indented under a definition becomes a sibling `<ul>`, not children of
   the `<dd>`.

7. **Multiple Apex TOC marker dialects on one page**  
   Isolated `<!--TOC-->`, `{{TOC}}`, `{{TOC:2-3}}`, and `{:toc}` each work.
   Combined on one page, MMD forms may remain literal `<p>{{TOC}}</p>` and a
   raw `<!--TOC-->` comment can remain. Product layout TOC remains Boris
   `{{toc}}` (Feature 6), independent of these markers.

8. **Duplicate heading ids**  
   Two identical heading texts share one `id` (no disambiguating suffix). Matches
   existing `docs/contracts/heading-ids.md` observation; still author-surprising.

### Supported and tested (class 1) — highlights

- Basic GFM tables, rowspan/colspan, relaxed tables  
- Footnotes (reference + inline forms)  
- Math delimiters (KaTeX-style spans)  
- Task lists, smart typography, autolinks, raw HTML  
- Heading auto-ids + IAL  
- Fenced divs + `::: >aside` block types  
- Callouts NOTE/TIP/WARNING + collapsible details  
- Image basic + figcaption when captions enabled  
- Single-syntax Apex TOC markers; `{:.no_toc}` exclusion  
- Strikethrough, sup/sub, spans, abbreviations, emoji, critic markup (probes)

### Intentionally disabled / non-goals (class 3)

| Item | Why |
|------|-----|
| Apex file includes | Host forces `enable_file_includes=false` |
| Plugins / highlighters | Host off; AGENTS forbids MD subprocess tools |
| Grid tables | Engine default off; host does not enable |
| Python-Markdown `!!!` callouts | `enable_py_callouts=false` |
| Apex wiki links | Engine default off; Boris pre-Apex wiki |
| Citations + bibliography packaging | No host `bibliography_files`; closed FM rejects unknown keys |
| Apex metadata variables / option metadata | Closed frontmatter product grammar |
| Non-Unified modes / Apex CLI combiners | Not host ABI surface |

### Supported but unverified (class 2)

CSV/TSV table conversion, indices, ARIA/header-anchor options, hard-break
option — engine flags exist under Unified defaults or opt-in, but this audit did
not build durable fixtures for them.

---

## Classification counts (primary exercise rows)

Approximate roll-up of the primary exercise table in `MATRIX.md` (some features
split into multiple rows):

| Class | Rough count | Role in product narrative |
|------:|------------:|---------------------------|
| 1 | majority of docs-site constructs | Safe to author today |
| 3 | grid tables, py-callouts, citations/bib packaging, includes/plugins | Documented non-goals |
| 4 | advanced table edge cases, image IAL ordering, callout aliases, multi-TOC | Audit debt — do not silently market as complete |
| 2 | CSV/TSV, indices, obscure options | Future probe cards |

---

## Reproduce

```bash
# From repository root on this branch:
zig build

./zig-out/bin/boris \
  --input docs/contracts/fixtures/apex-unified-compat/content \
  --theme docs/contracts/fixtures/apex-unified-compat/theme \
  --html-dir test-output/apex-unified-compat \
  --quiet

# Inspect a class-4 probe page:
#   test-output/apex-unified-compat/features/tables.html
#   test-output/apex-unified-compat/features/images.html
#   test-output/apex-unified-compat/features/callouts.html
#   test-output/apex-unified-compat/features/toc-markers.html

zig build test
zig build test-apex-hostile
```

---

## Summary

Boris’s host adapter correctly selects **ApexMarkdown Unified** and delivers the
core documentation-site surface (tables, footnotes, math, callouts, task lists,
definition lists, smart typography, autolinks, raw HTML, heading attributes,
fenced divs) with existing unit goldens for high-value constructs.

This audit does **not** claim full parity with every bullet in
`vendor/apex-markdown/pages/index.md`. Class **4** rows are real author-visible
surprises under the current pin; class **3** rows match deliberate host/product
boundaries. Remediation is out of scope for this documentation-only change set.
