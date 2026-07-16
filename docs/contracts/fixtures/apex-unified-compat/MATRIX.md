# ApexMarkdown Unified · Boris compatibility matrix

**As of:** 2026-07-15 · Boris product path · ApexMarkdown pin **v1.1.11** · host
adapter Unified (`APEX_MODE_UNIFIED`, fragment HTML, `unsafe=true`).  
**Source inventory:** `vendor/apex-markdown/pages/index.md`  
**Evidence:** fixture HTML under `test-output/apex-unified-compat/` (local),
`src/apex.zig` U-tests, host options in `vendor/apex/apex.c`.

Class codes:

| Code | Meaning |
|------|---------|
| **1** | supported and tested |
| **2** | supported but unverified |
| **3** | intentionally disabled/non-goal |
| **4** | broken or behaviorally surprising |

---

## Primary exercise set (user-requested)

| Feature | Class | Through Boris (HTML) | Automated pin | Notes |
|---------|:-----:|----------------------|---------------|-------|
| GFM pipe tables (basic + align row) | **1** | `<table>` + thead/tbody | U1 golden | Works |
| Advanced rowspan (`^^`) / colspan (`<<`) | **1** | `rowspan` / `colspan` attrs | fixture | Works on short pages |
| Table captions (`Table:` / `: Caption`) | **4** | figcaption on target **and** `data-caption` leak onto earlier table | fixture + probe | Surprising multi-table association |
| Per-cell alignment (`:Left` / `Right:` / `:Center:`) | **4** | No alignment attrs; `:Center:` → text **`cancer`** | fixture + probe | Collides with emoji shortcode path |
| Headerless tables (separator-first) | **4** | Empty or odd row/`th scope=row` shapes depending on isolation | fixture + probe | Unreliable vs Apex docs |
| Relaxed tables (no separator) | **1** | Valid `<table>` body rows | fixture | Host inherits Unified `relaxed_tables` |
| Grid tables (Pandoc `+---+`) | **3** | Literal monospaced paragraph | fixture | `enable_grid_tables=false` in engine defaults; host does not enable |
| Footnotes (reference) | **1** | `footnote-ref` + `section.footnotes` | U7 golden | Works |
| Footnotes (Kramdown `^[…]` / MMD `[^…]` inline) | **1** | Inline refs + definitions | fixture | Works |
| Definition lists | **1** | `<dl><dt><dd>` | U8 + fixture | Nested list under `: def` **escapes** the `<dd>` → see **4** sub-note |
| Definition list nested block content | **4** | List after `dd` is a sibling `<ul>`, not inside `<dd>` | fixture + probe | Surprising nesting |
| Math `$…$` / `$$…$$` | **1** | `span.math.inline` / `.display` with `\(...\)` / `\[…\]` | U9 golden | Markup only; no KaTeX CSS in default layout |
| Callouts `> [!NOTE]` family | **1** | `div.callout.callout-*` | U10 golden | NOTE/TIP/WARNING OK |
| Callouts IMPORTANT / CAUTION | **4** | Map to `callout-tip` / `callout-warning` (not distinct classes) | fixture + probe | Surprising kind aliasing |
| Collapsible callouts (`-` / `+`) | **1** | `<details>` / `<details open>` | fixture | Works |
| Python-Markdown `!!!` callouts | **3** | Left as prose | fixture | `enable_py_callouts=false` |
| Task lists | **1** | `input type=checkbox` checked/disabled | U6 + fixture | Works |
| Images (basic) | **1** | `<img>` inside `<figure>` | fixture | Relative + remote src |
| Image captions (alt/title → figcaption) | **1** | `<figcaption>` | fixture | Default Unified `enable_image_captions` |
| Image IAL (width/class/style) | **4** | Works when IAL images appear **before** any plain image; **attrs dropped** for IAL images after a plain image on the same page | fixture | High-impact surprise |
| Raw HTML | **1** | Pass-through `p`/`div`/`script` | fixture | Host `unsafe=true` (trusted authors) |
| Autolinks (URL + email) | **1** | `<a href=https…>` / `mailto:` | fixture | Works |
| Smart typography | **1** | Curly quotes, em/en dashes, ellipsis | fixture | Works |
| Heading auto ids | **1** | GFM-style `id` on `h1`–`h6` | heading-ids contract + fixture | Works |
| Heading IAL (`{#id .class}`) | **1** | Custom id + class | U11 + fixture | Pandoc + Kramdown brace forms |
| Duplicate heading ids | **4** | Same `id` on both headings (no `-1` suffix) | fixture + contract | Documented Apex observation; still surprising for authors |
| Fenced divs `:::` | **1** | `<div class=…>` | U12 + fixture | Short pages OK |
| Fenced div block types `::: >aside` | **1** | `<aside class=…>` | fixture | Works |
| Apex TOC `<!--TOC-->` | **1** | `<nav class="toc">` | isolated probe | Works alone |
| Apex TOC `{{TOC}}` / `{{TOC:2-3}}` | **1** | nav (range respected) | isolated probe | Alone works; co-presence issues → **4** |
| Apex TOC `{:toc}` | **1** | `<nav class="toc">` | isolated probe | Works alone |
| Multiple TOC marker syntaxes on one page | **4** | First HTML/Kram form expands; MMD forms may stay literal; leftover `<!--TOC-->` comment | fixture | Surprising co-presence |
| TOC `{:.no_toc}` exclusion | **1** | Heading omitted from nav | misc probe | Works |
| Citations `[@key]` / `[#key]` | **3** | Markers left literal without bibliography | fixture | Unified flag on, but no host bib packaging / closed FM blocks metadata keys |
| Bibliography generation | **3** | No bibliography block | fixture | Product non-goal until packaging exists |

Definition-list base syntax is **1**; nested block content under a definition is **4**.

---

## Broader Unified inventory (from Apex index)

| Feature (Apex docs) | Class | Evidence / reason |
|---------------------|:-----:|-------------------|
| Compatibility modes (CommonMark/GFM/MMD/Kramdown) | **3** | Product is Unified-only; no mode CLI |
| Strikethrough `~~` | **1** | U5 |
| Nested lists / blockquotes / fenced code | **1** | U2–U4 |
| Superscript / subscript | **1** | misc probe (`<sup>` / `<sub>`) |
| Bracketed spans `[text]{IAL}` | **1** | misc probe |
| Paragraph trailing IAL | **1** | misc probe |
| Abbreviations `*[ABBR]:` | **1** | misc probe (`<abbr title>`) |
| GitHub emoji shortcodes | **1** | misc probe (`:tada:` → 🎉); table cells strip to names |
| Critic Markup | **1** | misc probe (`ins`/`del`/`mark.critic`) |
| Syntax highlighting (Pygments/Skylighting) | **3** | Host `code_highlighter=NULL`; AGENTS no MD subprocess |
| Apex wiki links `[[Page]]` | **3** | Engine default `enable_wiki_links=false`; Boris owns `[[entity-id]]` pre-Apex |
| Apex file includes | **3** | Host `enable_file_includes=false`; Boris expands `{{include}}` |
| Plugins / external plugin detection | **3** | Host plugins off; no CWD probe |
| Metadata variables `[%key]` / transforms | **3** | Closed Boris frontmatter ≠ Apex metadata dialect |
| Metadata control of options | **3** | Same |
| CSV/TSV auto tables | **2** | Engine-capable; not exercised through Boris fixture |
| Indices (mmark / TextIndex / Leanpub) | **2** | Unified enables flags; no product dogfood / no fixture |
| Markdown combiner / mmd-merge CLI | **3** | Apex CLI features; not host ABI surface |
| Standalone / pretty HTML / CSS flags | **3** | Host forces fragment + `pretty=false` |
| Header anchor tags (vs ids) | **2** | Default is ids; anchors option not exposed |
| ARIA table/TOC options | **2** | Not product-exposed |
| Hard breaks option | **2** | Default off; not product-exposed |
| Feature toggle CLI matrix | **3** | Host freezes options; no per-build toggles |
| Quarto / Python-Markdown dialects | **3** | Off in Unified defaults used by host |

---

## Host boundary (always class 3 or ABI)

| Boundary setting | Value | Class |
|------------------|-------|:-----:|
| Mode | `APEX_MODE_UNIFIED` | **1** (product default) |
| `standalone` | false | **3** (layout owns chrome) |
| `pretty` | false | **3** (stable compact HTML) |
| `unsafe` | true | **1** for trusted authors |
| File includes | false | **3** |
| Plugins / external detection | false | **3** |
| External highlighters | off | **3** |

---

## Fixture map

| Page id | Feature family |
|---------|----------------|
| `index` | Trunk hub |
| `features/tables` | Tables + advanced forms + grid probe |
| `features/footnotes` | Footnote syntaxes |
| `features/definition-lists` | Definition lists |
| `features/math` | Math delimiters |
| `features/callouts` | Engine callouts + `!!!` |
| `features/task-lists` | Task lists |
| `features/images` | Images + IAL ordering probe |
| `features/raw-html` | Raw HTML |
| `features/autolinks` | Autolinks |
| `features/smart-typography` | Smart typography |
| `features/heading-attributes` | Heading ids / IAL / duplicates |
| `features/fenced-divs` | Fenced divs + block types |
| `features/toc-markers` | In-body TOC markers |
| `features/citations` | Citation markers without bib |
