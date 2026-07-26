# Twenty Twenty 3.1 theme materialization dogfood

Date: 2026-07-26  
Scope: standalone migration laboratory evidence only. Boris core, contracts,
and runtime dependencies did not change.

## Source and permission evidence

The supplied local source was
`/Users/tbuddy/Downloads/twentytwenty.3.1.zip`:

| Item | Evidence |
|---|---|
| Archive SHA-256 | `e4dce9fed293acd1c30a498c7e4f1200222821be704f8dc5e324002ac9ae34c0` |
| Theme | Twenty Twenty 3.1 |
| Permission | `readme.txt` says `License: GPLv2 or later`; its copyright section says the theme is distributed under GNU GPL. `style.css` says `License: GNU General Public License v2 or later`. |
| Source evidence SHA-256 | `readme.txt`: `2add5ba5e722098438b7c5de5d92bda3712575dfea6e7dbf3968161fa4ce2757`; `style.css`: `49d020a2a1104ffdb3c710b8d9ea490e868e1d5b2e50e6bc1b7c530d1c6dc217` |

The archive was unpacked only into `/private/tmp`; it and its extracted source
were not committed. The sample contains no separately named `LICENSE` or
`COPYING` file, so materialization did **not** invent or copy a `theme/LICENSE`.
The source-license evidence above is retained instead.

## Archaeology and reviewed ledger

`theme-archaeology` inventoried 61 files into 66 deterministic ledger rows:
19 `preserve`, 44 `review`, 3 `drop`, and 9 `unsupported_runtime` rows. Two
independent runs had byte-identical `adaptation_ledger.json`, `report.json`,
`REPORT.md`, and `BOUNDARY.md` outputs.

The generic archaeology output leaves PHP files as `review`. Human review made
one deliberately narrow ledger change, recorded here rather than treating it
as automatic conversion:

| Source | Original | Reviewed decision | Reason |
|---|---|---|---|
| `header.php` (`f7c5aaba41fe53cd5f79ded7d81aaa3fb76f44854dc691a9d61ed162a2499e0f`) | `other` / `review` | `layout` / `adapt` → `theme/layouts/main.html` | Generate only a generic closed Boris header/nav/content/toc/footer shell. PHP, hooks, menus, Customizer behavior, and runtime state are rejected. |

The reviewed ledger otherwise retained the archaeology decisions. It approved
only static CSS, font, and image rows. It explicitly refused
`assets/css/font-inter.css`: its otherwise-preserve row has two companion
`traversal_url_ref` drop rows for `../fonts/inter/*.woff2`, so the safe
materializer did not copy it. All seven `assets/js/*.js` rows remained review
only and were not emitted; no JavaScript, PHP, or WordPress runtime was
executed or emulated.

## Materialized draft

Two equivalent `theme-materialize` runs produced byte-identical drafts. The
draft contains:

- one generated `theme/layouts/main.html`, with only closed Boris slots and an
  `asset-url` helper;
- 17 copied static asset files (seven CSS files, two fonts, and eight images),
  all byte-checked against their ledger SHA-256 values;
- deterministic `materialize-manifest.json`, `MATERIALIZE-REPORT.md`, and
  `PROVENANCE.md` outputs.

It contains no PHP, JavaScript, remote fetch, source-framework template
execution, or copied asset with dropped companion safety evidence. This is a
reviewable static starting point, not visual or behavioral WordPress parity.

## Representative build and audit

A disposable two-page Boris content fixture exercised a Trunk/Satellite graph,
navigation, table, code block, Aside, wiki link, and a content-local image. It
compiled with the generated materialized theme. A sequential build and a
repeat `--jobs 2` build were byte-identical. Two independent link-audit runs
were byte-identical and each scanned two HTML files with **zero** missing local
routes or fragments.

## Exact commands

```text
unzip -q /Users/tbuddy/Downloads/twentytwenty.3.1.zip -d /private/tmp/twentytwenty-3.1-source
zig build --build-file tools/migration-lab/build.zig run -- --mode=theme-archaeology --root=/private/tmp/twentytwenty-3.1-source/twentytwenty --out=/private/tmp/twentytwenty-arch-a --quiet
zig build --build-file tools/migration-lab/build.zig run -- --mode=theme-materialize --root=/private/tmp/twentytwenty-3.1-source/twentytwenty --ledger=/private/tmp/twentytwenty-reviewed-adaptation-ledger.json --out=/private/tmp/twentytwenty-material-a --quiet
zig build
./zig-out/bin/boris --input .boris-twentytwenty-dogfood/content --theme .boris-twentytwenty-dogfood/theme --html-dir .boris-twentytwenty-dogfood/site --quiet
./zig-out/bin/boris --input .boris-twentytwenty-dogfood/content --theme .boris-twentytwenty-dogfood/theme --html-dir .boris-twentytwenty-dogfood/site --jobs 2 --quiet
zig build --build-file tools/migration-lab/build.zig run -- --mode=link-audit --root=/private/tmp/boris-theme-twentytwenty-dogfood/.boris-twentytwenty-dogfood/site --out=/private/tmp/twentytwenty-link-audit-a --quiet
```

The link-audit output directory was created before invocation because the
current lab command requires an existing `--out` directory. The absolute root
is intentional: `zig build --build-file tools/migration-lab/build.zig run`
executes from the tool directory, so a repository-relative generated-site path
would not resolve.

## Limitations and next cards

- No browser, responsive, or accessibility certification was performed.
- The generated shell links the first safe stylesheet in ledger order; selecting
  a production visual stylesheet needs a separate human design decision.
- Font CSS with a safe relative local reference needs an explicitly supported
  asset-reference rewrite policy; this pass correctly refused its traversal
  form.
- A classic WordPress-aware reviewed-ledger workflow could be specified if more
  real-theme passes demonstrate the same need. It must remain review-first and
  must not execute PHP or JavaScript.

