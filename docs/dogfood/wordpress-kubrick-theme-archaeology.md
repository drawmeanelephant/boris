# WordPress theme archaeology: classic benchmark

Date: 2026-07-18
Scope: migration-lab only; Boris core, contracts, and runtime dependencies were not changed.

## Result

No authentic Kubrick theme was available in the local workspace, and the
migration lab does not retrieve external themes. The controlled benchmark is
therefore the synthetic, redistributable fixture
[`tools/migration-lab/fixtures/mini-wordpress-kubrick/`](../../tools/migration-lab/fixtures/mini-wordpress-kubrick/).
It models the classic template names and behaviors without claiming Kubrick
source fidelity or universal WordPress compatibility.

The new standalone `wordpress-theme` mode in
[`wordpress_theme.zig`](../../tools/migration-lab/wordpress_theme.zig) reads
file bytes and source lines only. PHP and JavaScript are never executed.

## Deterministic inventory

The fixture contains 15 files: 9 PHP templates, 5 static assets/stylesheets,
and one fixture README. The generated `inventory.json` records every sorted
path, byte length, SHA-256, template classification, and line-level signal.
The canonical generated bundle is checked in under
[`wordpress-kubrick-theme-archaeology-artifacts/`](wordpress-kubrick-theme-archaeology-artifacts/).

| Evidence class | Count | Examples |
|---|---:|---|
| PHP templates | 9 | `index.php`, `single.php`, `page.php`, `header.php`, `footer.php`, `sidebar.php`, `comments.php`, `searchform.php`, `functions.php` |
| Static assets/stylesheets | 5 | `style.css`, `rtl.css`, `js/menu.js`, `images/logo.svg`, `images/screenshot.png` |
| Dynamic findings | 99 | template calls, loops, content tags, hooks, menus, widgets, PHP markers |
| Menu findings | 2 | `register_nav_menus:primary,footer`, `wp_nav_menu:primary` |
| Widget findings | 4 | `register_sidebar:primary`, `register_sidebar:footer`, `is_active_sidebar:primary`, `dynamic_sidebar:primary` |
| Template relationships | 8 | `get_header`, `get_footer`, `get_sidebar`, `get_search_form`, `comments_template` |

The inventory is intentionally source evidence rather than an evaluated model:
WordPress hook registration, plugin callbacks, conditional branches, database
state, and rendered output are outside the evidence boundary.

## Static Boris prototype

The generated [`prototype/main.html`](wordpress-kubrick-theme-archaeology-artifacts/prototype/main.html)
is a no-runtime layout using only Boris’s closed layout markers.
[`slot_mapping.json`](wordpress-kubrick-theme-archaeology-artifacts/slot_mapping.json)
records the source evidence and
decision for each requested surface:

| Boris surface | Decision | Mapping |
|---|---|---|
| `{{nav}}` | adapt + review | `wp_nav_menu()` is a candidate after graph/menu review |
| `{{breadcrumb}}` | review | WordPress conditional/link semantics are not inferred; use the Boris graph |
| `{{title}}` | adapt | `the_title()` maps to `{{title}}` |
| `{{content}}` | adapt | `the_content()` maps to `{{content}}` |
| `{{children}}` | review | `wp_list_pages()` may map after hierarchy review |
| Aside | review | Widget output is not a direct slot; selected static content may become inline `<Aside>` |
| `{{toc}}` | review | No stable heading-outline evidence was found; use Boris’s page-local TOC only after content review |
| `{{footer}}` | adapt + review | Static footer shell maps; `wp_footer()` callbacks remain manual |

`Aside` is explicitly documented as an inline content component, not a
WordPress sidebar/widget runtime. This preserves Boris’s existing content model
instead of inventing a second sidebar abstraction.

## Manual-review boundary

[`manual_review.json`](wordpress-kubrick-theme-archaeology-artifacts/manual_review.json)
preserves 86 unsupported or dynamic findings with exact
source path, line number, raw evidence, decision, and review reason. The output
decision totals are:

| Decision | Count | Meaning in this lab |
|---|---:|---|
| preserve | 9 | Static CSS/image bytes plus stylesheet provenance rows |
| adapt | 23 | Closed slot or one-page mapping, still subject to evidence review where noted |
| review | 78 | PHP source, hook/loop/runtime behavior, or ambiguous mapping |
| drop | 4 | No-runtime JavaScript asset and server-side/static-incompatible behavior |

These counts include both file-level decisions and line-level findings. They do
not mean that a WordPress theme has been converted or rendered successfully.

## Preserve / adapt / review / drop policy

- **Preserve:** static CSS, image bytes, and theme stylesheet provenance can be
  copied or re-authored without executing PHP.
- **Adapt:** `get_header`/`get_footer` shell relationships, title/content
  output, and graph-backed nav/children candidates have a closed Boris shape.
- **Review:** menus, widgets, breadcrumbs, conditionals, hooks, loops,
  metadata, comments, and every PHP line whose semantics depend on WordPress.
- **Drop:** runtime-only JavaScript and server-side behavior with no safe
  static prototype mapping. The raw source evidence remains in the manifest.

## Exact verification

From the repository root:

```text
zig build --build-file tools/migration-lab/build.zig test   # exit 0
zig build test                                               # exit 0
```

Fixture run (from `tools/migration-lab/`):

```text
zig build run -- --mode=wordpress-theme \
  --root=./fixtures/mini-wordpress-kubrick \
  --out=./.wp-theme-report --quiet                           # exit 0
```

The focused lab test runs the fixture twice and compares
`inventory.json`, `manual_review.json`, `slot_mapping.json`, `report.json`,
`REPORT.md`, and `prototype/main.html` byte-for-byte. It also asserts template
classification for the classic file names and checks that menu/widget/hook
evidence and all requested Boris markers are present.

No PHP command, WordPress runtime, network fetch, plugin install, or product
compiler change is part of this investigation.
