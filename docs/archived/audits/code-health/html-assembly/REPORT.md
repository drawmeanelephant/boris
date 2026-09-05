# Code-health audit report — HTML assembly, themes, and assets

**Card:** #813 (milestone [Code health pass](https://github.com/drawmeanelephant/boris/milestone/2), epic #807)
**Authority:** review only — no product-code changes on this card. Findings
filed individually: #866, #867, #868, #869 (Confirmed), #870 (Likely).
**Commit audited:** `main` @ `e1e646d4` (branch `audit/813-html-assembly`)
**Zig:** 0.16.0 (homebrew), macOS arm64 (darwin)
**Gate:** `zig build test` green before probes and re-run green after (exit 0).

## Setup

- Fresh branch `audit/813-html-assembly` from `origin/main` tip `e1e646d4`
  (merge of PR #865); `git status` clean except the report itself.
- `zig build test` → exit 0 before any probe work; re-run exit 0 after.
- Black-box probes: `zig build` binary `zig-out/bin/boris` run against
  `boris init`-scaffolded trees in `/var/folders/.../T/opencode/` with replaced
  `content/` (sibling dirs `p1-layouts` … `p6-fence`); exit codes and full
  output pasted below.
- Contracts read first (normative): `docs/contracts/html-output.md`,
  `templating-and-themes.md`, `content-local-assets.md`.
- Locus files read in full: `src/html_body.zig` (510), `src/html_nav.zig` (501),
  `src/html_toc.zig` (403), `src/assemble.zig` (1156), `src/compile.zig` (3731),
  `src/theme.zig` (688), `src/layout_select.zig` (524), `src/content_asset.zig`
  (1466). Drift checked both directions (undocumented-but-present and
  documented-but-missing).

## Falsification table

| # | Probe | Commands (abridged) | Result | Classification | Evidence |
|---|-------|---------------------|--------|----------------|----------|
| P1a | Exact beats glob; declaration order irrelevant | two competing rules for `reference/config` (`id:` vs `glob:reference/*`), both argv orders; marker `<title>` per layout | `L:exact` wins both orders, exit 0; other pages fallback | Non-issue (contract-conformant) | templating-and-themes.md §4.2; layout_select.zig:241-295; unit `selectLayout precedence exact > glob > role > fallback` |
| P1b | Glob beats role; most-specific glob wins | `role:satellite` vs `glob:guides/*`; `glob:reference/*` vs `glob:reference/deep/*` | `L:glob` for guides/g1; `L:deep` for reference/deep/d; exit 0 | Non-issue | layout_select.zig:259-278 (literal-segment count); unit `more literal segments wins among globs` |
| P1c | Equal-specificity glob tie | `glob:reference/*` vs `glob:*/config` for `reference/config` | `error: AmbiguousGlob`, exit 2 before discovery | Non-issue | layout_select.zig:275; conformance c05 `ambiguous-glob.stderr` |
| P1d | Duplicate selector, equal paths | two `id:reference/config` rules | exit 2; but with `--html-layout` also present the line reads `error: duplicate option: --html-layout` — a flag present exactly once; without it: `duplicate option: --layout-rule`, still never naming the selector | **Confirmed defect → #867** | cli.zig:2073 bare `error.DuplicateFlag`; cli.zig:2649 `findBadArg` blames first non-exempt argv flag |
| P1e | Winning rule layout missing | `id:reference/config layouts/nope.html` + glob rule | `failed to load layout layouts/nope.html: FileNotFound`, exit 3 — no silent fallback to the glob rule | Non-issue | templating §4.2 "fails without silent fallback"; compile.zig:1432-1447 |
| P2a | Content-local passthrough + inventory kinds | page with `intro.assets/diagram.svg`; `boris --quiet` | exit 0; `dist/guides/intro.assets/diagram.svg` published; artifacts.json kinds `html-page`, `theme-asset`, `content-asset`, `rendered-search` | Non-issue | content-local-assets.md §1/§3; content_asset.zig:248-358; compile.zig:3204-3241 |
| P2b | Unsafe SVG, referenced and unreferenced | `evil.svg` with `<script>` (unreferenced by page) | `error: EASSET ... active SVG <script> element (file not referenced by any page)`, exit 1 | Non-issue | content-local-assets.md §1(5); content_asset.zig:324-338, 403-416 |
| P2c | Page output vs content-local collision | entity id `foo.assets/bar` page + page `foo` asset `foo.assets/bar.html` | exit 1 `AssetCollision` — but no EASSET diagnostic and neither colliding path named | **Confirmed defect → #868** | content-local-assets.md §5 table promises EASSET for "published-path collision"; compile.zig:2263-2307 has no diagnostic; c07 golden bakes the bare line |
| P2d | Theme asset URL depth + copy | `--theme theme` with `asset-url`; nested page href | `href="../assets/css/weird_name.css"` from `guides/intro.html`, `href="assets/..."` from root; byte-identical copy | Non-issue | templating §3.2/§5; compile.zig:813-820; assemble.zig writePage asset-url test |
| P3a | Nav forest shape (c05-shaped tree) | layout with `{{nav}}{{breadcrumb}}{{toc}}{{children}}` | byte shape matches html-output.md §"Site nav HTML": `site-nav__trunk`/`__satellite`, `is-current`/`is-ancestor`, `aria-current="page"`, site-relative hrefs, id-ascending trunks | Non-issue | html_nav.zig:68-158; unit `navigation chrome has deterministic landmarks...` |
| P3b | Draft gating (#738) | `status: draft` satellite in nav/children tree | draft page emitted at its route; pruned from nav and children on every other page; breadcrumb unchanged; own page renders normally | Non-issue | html-output.md §"Status gating"; html_nav.zig:32-34, 106-125, 170-177 |
| P3c | TOC shape | h1/h2/h3 with Oliver ids; page with no qualifying headings | `page-toc__l1..l3` levels, `#id` anchors matching body ids, tags stripped, no double-escape; empty fragment (no wrapper) when no headings | Non-issue | html-output.md §"In-page {{toc}}"; html_toc.zig:231-257 |
| P3d | Children shape | direct children only | `page-children` nav landmark, id-ascending, draft omitted, childless page emits empty fragment | Non-issue | html-output.md §"Direct-children HTML"; html_nav.zig:162-197 |
| P4 | Risk note: zero-page site | empty `content/`; `boris --quiet` and `--timings` | warning `no pages found under 'content'` prints under `--quiet`, exit 0; timings counters all 0 | Non-issue (risk note conforms) | html-output.md §"Zero-page sites" (#775); compile.zig:948-952, 1007 |
| P5a | Static passthrough full rebuild | `--static-dir static` with `robots.txt`, `embed.html`, `.well-known/security.txt` | full build: `embed.html` committed + inventoried (`static-file`, required) then **deleted from dist**; exit 0 with `artifact-integrity` check `incomplete` warning; incremental rebuild keeps the file | **Confirmed defect → #866** | html-output.md §"Static passthrough" (#804); compile.zig:3402-3419 walker has no static-entry skip; compile.zig:3661 call site |
| P5b | Static collision guard | static `index.html` vs page route (unit) | `StaticPathCollision` usage error (compile_static_files_test.zig:135-150) | Non-issue | html-output.md §"Declared collisions" |
| P6a | Indented fenced code, terminated | 2-space fence wrapping an image-looking line with an out-of-tree dest (see P6 transcript) | builds exit 0, renders `<pre><code>` literal (escapes via inline-code-span pairing) | Non-issue (this exact case) | content_asset.zig:638-654 |
| P6b | Indented code block (4-space) / unterminated indented fence | same image-looking text in 4-space indented block; and 2-space fence without closer | `error: EASSET ... invalid or out-of-tree content-local image path: ../escape.svg`, exit 1 — text Oliver renders as literal code | **Confirmed defect → #869** | content-local-assets.md §2 "Fence-aware: ... left literal"; content_asset.zig:558-579 fence detection is indentation-blind |
| P7 | Theme asset filename containing `\` | `theme/assets/css/weird\name.css` referenced as `assets/css/weird/name.css` | `error: target 'default' compilation failed: FileNotFound`, exit 3 — no path named; file exists on disk | **Likely defect → #870** | theme.zig:193-204 normalization before read; content_asset.zig:305-315 same pattern |
| W1 | Layout load/marker grammar vs assemble tests | full unit run (`zig build test`) | missing/duplicate/unknown markers, nav-depth malformed args, asset-url grammar/bounds (16/32), UTF-8 at split, hold-until-flush ordering, temp cleanup — all green | Non-issue | assemble.zig:227-406, 718-1148; compile.zig:405-452 |
| W2 | Fingerprint/chrome material vs contract | reading + unit run | site-nav digest includes `(id, title, parent, role, status)` (status load-bearing); layout path+bytes+theme material per selected layout; asset bytes excluded from page fingerprints; content-local images revalidated every build | Non-issue | html-output.md §"Incremental fingerprints"; compile.zig:2608-2706; html_nav.zig:41-59 |
| W3 | Metadata/footer/head slots | reading + unit run | metadata `<dl class="page-metadata">` Status/Parent/Tags escaped; footer from theme or empty; `{{head}}` compiler-owned, warning when layout omits it while verification configured | Non-issue | templating §3.1; compile.zig:531-562, 852-868, 2134-2197 |
| W4 | `compileHtmlToSink` ignores `layout_rules` | reading | embed-only path (`src/embed.zig:75`), unreachable from CLI rules; nav-material condition still consults rules | Non-issue (no CLI surface) | compile.zig:456-515 |

## Probe transcripts (full output, abridged where noted)

### P1 — layout precedence

```text
$ boris --quiet --html-layout layouts/global.html \
    --layout-rule default 'id:reference/config' layouts/exact.html \
    --layout-rule default 'glob:reference/*' layouts/glob.html
exit=0
  index.html -> L:global
  guides/g1.html -> L:global
  reference/config.html -> L:exact
  reference/deep/d.html -> L:global
(swapping the two --layout-rule arguments: byte-identical results)

$ boris --quiet --html-layout layouts/global.html \
    --layout-rule default 'glob:reference/*' layouts/glob.html \
    --layout-rule default 'glob:*/config' layouts/globb.html
error: target 'default' layout selection failed for 'reference/config': AmbiguousGlob
error: invalid target configuration: AmbiguousGlob
configured targets (canonical order):
  target default: out=dist layout=layouts/global.html rules=2
exit=2

$ boris --quiet --layout-rule default 'id:reference/config' layouts/nope.html \
    --layout-rule default 'glob:reference/*' layouts/glob.html
error: target 'default' failed to load layout layouts/nope.html: FileNotFound [Fix the layout template and retry the build]
exit=3
```

### P2 — assets

```text
$ boris --quiet        # guides/intro.md + intro.assets/diagram.svg (safe)
exit=0
dist/guides/intro.assets/diagram.svg
inventory: [('_boris/search/search-index.json','rendered-search'),
 ('assets/css/boris.css','theme-asset'),
 ('guides/intro.assets/diagram.svg','content-asset'),
 ('guides/intro.html','html-page'), ('index.html','html-page')]

$ boris --quiet        # + intro.assets/evil.svg containing <script>
error: EASSET: guides/intro.assets/evil.svg:1:1: content-local SVG contains active content: active SVG <script> element (file not referenced by any page) [Remove the named active construct or publish an inert SVG; Boris does not sanitize assets]
error: target 'default' compilation failed: AssetUnsafeSvg
exit=1

$ boris --quiet        # page id: foo.assets/bar + foo.assets/bar.html asset
error: target 'default' compilation failed: AssetCollision
error: one or more HTML targets failed due to I/O or a system error
exit=1
```

### P3 — nav/TOC vs archive shape

```text
$ boris --quiet --html-layout layouts/all.html     # {{nav}}{{breadcrumb}}{{toc}}{{children}}{{content}}
exit=0
index.html nav excerpt:
<li class="site-nav__trunk is-current"><a href="index.html" aria-current="page">Home</a>
<ul>
<li class="site-nav__satellite"><a href="guides/g1.html">G1</a></li>
<li class="site-nav__satellite"><a href="reference/config.html">Config</a>
<ul>
<li class="site-nav__satellite"><a href="reference/deep/d.html">D</a></li>
...
guides/g1.html: <li class="site-nav__trunk is-ancestor"><a href="../index.html">
  breadcrumb: <li><a href="../index.html">Home</a></li><li aria-current="page">G1</li>
  toc: page-toc__l1 #g1, page-toc__l2 #sub-one, page-toc__l3 #deep-three
draft guides/hidden.md: dist/guides/hidden.html exists; zero mentions of
"hidden" in dist/index.html and dist/guides/g1.html; its own page renders.
```

### P4 — zero-page risk note

```text
$ boris --quiet          # empty content/
warning: no pages found under 'content'; published output contains proof/search assets only
exit=0
$ boris --quiet --timings
counters: page_reads 0, include_reads 0, hash_bytes 0, link_resolutions 0, fast_path_hits 0
exit=0
```

### P5 — static passthrough

```text
$ boris --quiet --static-dir static      # static/{robots.txt, embed.html, .well-known/security.txt}
warning: publication check 'artifact-integrity' for target 'default' reported status 'incomplete'; ...
exit=0
dist after full build: .well-known/security.txt, robots.txt, index.html, assets/..., _boris/...
  (embed.html ABSENT)
inventory declares: ('embed.html', 'static-file')
$ boris --quiet --incremental --static-dir static
exit=0 ; dist/embed.html PRESENT
$ boris --quiet --static-dir static      # full rebuild again
exit=0 ; dist/embed.html ABSENT
```

### P6 — fence awareness

```text
$ boris --quiet    # 4-space indented code block containing ![x](../escape.svg)
error: EASSET: fenced.md:7:5: invalid or out-of-tree content-local image path: ../escape.svg [Use a relative path under this page's <stem>.assets/ tree; no absolute paths, .., or backslashes]
error: target 'default' compilation failed: AssetFailed
exit=1
$ boris --quiet    # 2-space indented fence, terminated -> exit 0, <pre><code> literal
$ boris --quiet    # 2-space indented fence, unterminated -> EASSET, exit=1
```

### P7 — backslash-named theme asset

```text
$ boris --quiet --theme theme    # theme/assets/css/weird\name.css
error: target 'default' compilation failed: FileNotFound
error: one or more HTML targets failed due to I/O or a system error
exit=3
control (weird_name.css): exit=0, dist/assets/css/weird_name.css present
```

## Findings

1. **#866 Confirmed defect (medium):** a declared `--static-dir` file ending in
   `.html` is committed, inventoried as a required `static-file`, then deleted
   by the full-rebuild stale-output walker; the build still exits 0 with only a
   publication-check warning. Locus `src/compile.zig:3402-3419`, call site
   `src/compile.zig:3661`.
2. **#867 Confirmed defect (low):** duplicate `--layout-rule` selector usage
   error blames the first non-exempt argv flag — it can name `--html-layout`,
   a flag present exactly once, and never names the duplicated selector.
   Locus `src/cli.zig:2073` + `src/cli.zig:2649-2661`.
3. **#868 Confirmed defect (low):** published-path collision produces no EASSET
   diagnostic and names neither colliding path, against the §5 diagnostics
   table of `content-local-assets.md`; the c07 conformance golden bakes in the
   bare line. Locus `src/compile.zig:2263-2307`.
4. **#869 Confirmed defect (low):** the content-local image scanner is
   indentation-blind: image-looking text inside a 4-space indented code block
   or an unterminated indented fence fails the build with EASSET though Oliver
   renders it literal. Locus `src/content_asset.zig:558-579`.
5. **#870 Likely defect (low):** the theme/content asset walks rewrite literal
   `\` in POSIX filenames to `/`, then read the renamed path — the build dies
   with a bare `FileNotFound` that names no file. Locus `src/theme.zig:193-204`,
   `src/content_asset.zig:305-315`.

Non-issue observations recorded for the record (no action):

- Layout precedence is fully deterministic and matches templating-and-themes.md
  §4.2 end to end (P1a–P1e), including no-fallback on a missing winning layout
  and AmbiguousGlob as usage (exit 2) before discovery.
- Nav/breadcrumb/TOC/children byte shapes match the html-output.md normative
  shapes exactly, including draft gating (#738): emitted-but-unadvertised pages,
  no empty `<ul>` from all-draft child sets, empty fragments without wrappers.
- Zero-page risk note (#775) conforms: warning under `--quiet`, exit 0, all
  timing counters at 0.
- SVG active-content policy, inventory kinds (`html-page`, `theme-asset`,
  `content-asset`, `static-file`, `rendered-search`), and page-relative
  asset-url hrefs conform (P2).
- The default theme's inline first-party search script is documented in
  `themes/boris/README.md` ("first-party inline consumer") and
  `rendered-search.md`; it is offline and not "linked or vendored JavaScript"
  in the templating contract's sense. Non-issue.
- `compileHtmlToSink` ignores `layout_rules`, but the sink path is embed-only
  (`src/embed.zig`) and never receives CLI rules. Non-issue.
- `FrozenSite.site_nav_digest` doc comment (`compile.zig:62-66`) omits `status`
  from the material list while `siteNavMaterial` includes it — comment-only
  drift; the load-bearing status field is correct and tested. Non-issue.
- `rewriteImageLinks` angle-bracket branch is a no-op duplicate of the plain
  branch (`content_asset.zig:850-857`) — cosmetic. Non-issue.
- Content-local vs theme-asset collision branch in `checkCollisions` is
  structurally unreachable (theme assets are always under the literal `assets/`
  prefix, content outputs under `{id}.assets/`) — defensive dead code. Non-issue.

## Exit checklist

- [x] 3 contracts read before the locus files
- [x] 8 locus files read in full; drift checked both directions
- [x] ≥3 falsification probes (7 probe families, 6 of them black-box binary runs: P1–P7), ≥2 black-box: satisfied
- [x] Every material observation classified exactly once
- [x] Findings filed individually: #866–#869 (Confirmed), #870 (Likely)
- [x] `zig build test` green before and after probe work (exit 0 both runs)
- [x] Report PR targeting `main` (this PR)
- [x] Close-out comment posted on #813 with the mandated template
