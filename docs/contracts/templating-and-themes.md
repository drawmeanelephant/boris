# Templating and themes (F9)

**Status:** F9.1 + F9.2 + layout selection implemented (closed layout plan,
metadata/footer/asset-url, target-owned assets, layout UTF-8 at split,
orphan asset scrub, `--layout-rule` selection). Later slices (external
stylesheets, DaisyUI experiment, IR layout/asset edges) remain open per §12.

**Authority:** normative for the F9.1/F9.2 HTML theme path. Subordinate contracts:
[HTML output](html-output.md), [multi-target](multi-target-isolated-output.md),
[identity/path](identity-and-paths.md). Does not change frontmatter grammar,
IR `schemaVersion`, or the Apex trust model.

This design keeps Boris as a Zig compiler that emits static HTML. It adds no
MDX, JavaScript execution, runtime hydration, child-process renderer, live CDN,
or application-language dependency.

## 1. Problem and design boundary

`layouts/main.html` is already useful for a small site: it has `content`,
`title`, `nav`, `breadcrumb`, `toc`, and `children` markers. Real documentation sites
usually need a theme-owned stylesheet, a stable footer, page metadata, several
page shapes, and more than one output target. The practical extension is a
small, closed template vocabulary plus explicit static asset ownership.

The design has four boundaries:

1. Markdown, frontmatter, graph validation, includes, wiki-links, Aside tokens,
   and Apex remain the existing pipeline.
2. A layout is trusted static HTML with named Boris insertion points. It is not
   a programming language: no conditionals, loops, expressions, arbitrary
   partial calls, or user-defined functions.
3. A theme owns layout files and static bytes under its `assets/` directory.
   Boris copies those bytes into each target output; it never fetches them.
4. A target owns its output, staging tree, cache namespace, selected layout,
   theme identity, and copied assets. Targets may read the same content tree,
   but never another target's generated output.

The [theme-site fixture](fixtures/theme-site/) is the F9.1 acceptance fixture
for slots, page-relative `asset-url`, footer, and target-owned CSS copy.
Adversarial cases live under [theme-adversarial](fixtures/theme-adversarial/).

## 2. Vocabulary and theme shape

The recommended theme source shape is:

```text
<theme-root>/
  layouts/
    main.html
    home.html                 # optional named layout
    reference.html            # optional named layout
  footer.html                # optional trusted static HTML fragment
  assets/
    css/docs.css
    fonts/                     # optional; copied as opaque bytes
```

Only regular files below `layouts/`, the optional `footer.html`, and
`assets/` are theme inputs. Symlinks are rejected. Theme-relative paths use `/`
separators, cannot be absolute, and cannot contain empty, `.` or `..`
segments. A theme cannot write outside its target output root.

The first implementation may accept a layout path directly and derive its
theme root from an explicit `--theme` path. A theme manifest is not required
for this design; if one is later introduced, it must be a Boris-owned closed
configuration format and cannot turn layouts into executable content.

## 3. Template vocabulary and slot contract

Templates are UTF-8 HTML files. Boris scans the complete file before compiling
content. Static bytes are streamed unchanged; slot values are generated per
page. Every known marker may occur at most once.

### 3.1 Slots

| Marker | Required | Value and escaping |
|---|---:|---|
| `{{content}}` | yes | Rendered Apex Markdown and ordered Aside HTML. Raw HTML behavior remains the current trusted-author behavior. |
| `{{title}}` | no | Page `title`, or entity id when the title is absent; HTML-escaped text. |
| `{{nav}}` | no | Deterministic graph forest from the frozen Trunk/Satellite graph; generated HTML as in `html-output.md`. |
| `{{breadcrumb}}` | no | Root-to-current graph chain; generated HTML as in `html-output.md`. |
| `{{toc}}` | no | Page-local h1–h3 outline from Apex-emitted heading ids; generated HTML as in `html-output.md`. |
| `{{children}}` | no | Deterministic direct-child list from the frozen graph; title-or-id labels and links are escaped, and childless pages emit empty. No recursive graph semantics or query language is introduced. |
| `{{metadata}}` | no | Boris-generated page metadata fragment. Only current closed frontmatter fields are represented; text and attribute values are escaped. |
| `{{footer}}` | no | Contents of the theme's optional `footer.html`, or the empty string. This is theme-owned trusted static HTML, not page-authored executable content. |

`{{content}}` must occur exactly once. Missing or duplicate markers, unknown
markers, invalid UTF-8, or an unclosed marker are hard layout errors before
content compilation. Layout UTF-8 is validated at **plan split / load**
(`Layout.split` / `loadLayout`), not later during page writes. An absent
optional slot emits no wrapper of its own, so a theme controls its surrounding
HTML.

`metadata` is intentionally boring and deterministic. A future implementation
may emit a stable fragment such as:

```html
<dl class="page-metadata">
  <div><dt>Status</dt><dd>published</dd></div>
  <div><dt>Tags</dt><dd>guides, cli</dd></div>
</dl>
```

Unset fields are omitted. `id`, `parent`, and `title` are not treated as raw
HTML. The exact class names and whether `title` is repeated in metadata are
open decisions; the escaping, ordering, and closed-input rules are not.

### 3.2 Asset URL helper

Static HTML needs a page-relative URL because `guides/getting-started.html`
and `index.html` are at different depths. The proposed non-slot helper is:

```text
{{asset-url assets/css/docs.css}}
```

It resolves only to a file owned by the selected theme, copies that file to
the same theme-relative path below the target root, and emits a `/`-separated
URL relative to the current page output path. For example:

```text
index.html                       → assets/css/docs.css
guides/getting-started.html      → ../assets/css/docs.css
```

The helper accepts a theme-relative path under `assets/` only. It rejects
absolute paths, `..`, backslashes, empty segments, missing files, and a path
that would collide with a page output. URL encoding policy for non-ASCII asset
names is an open decision; the first slice should use a conservative ASCII
asset-path grammar and fail closed.

`asset-url` is the only proposed argument-bearing template construct. It does
not read a URL, invoke a process, inspect the network, or evaluate an
expression. Direct hand-written `href`/`src` values remain static bytes and
are not rewritten by Boris.

## 4. Layout selection

Frontmatter remains the closed five-key grammar. In particular, Boris must not
add a `layout` or `template` frontmatter key. Layout choice is build
configuration (`--layout-rule`), not page-authored executable metadata.
Unknown keys such as `layout:` continue to produce `EFRONTMATTER`.

### 4.1 CLI grammar

```text
--layout-rule <TARGET> <SELECTOR> <LAYOUT_PATH>
```

The flag is repeatable, HTML-only, and consumes exactly three following
arguments. Selectors are closed:

| Selector | Match |
|---|---|
| `id:<entity-id>` | Byte-exact final entity id (including `id:` frontmatter override) |
| `glob:<segment-pattern>` | `/`-separated segments; `*` is one complete non-empty segment |
| `role:trunk` / `role:satellite` | Resolved graph role after parent validation |

Partial wildcards (`ref*`), recursive `**`, regex, and declaration-order
precedence are rejected. At most **256** rules per target. Unknown targets,
duplicate selectors (even with equal paths), invalid selectors, and rule
limits are usage errors (exit **2**) before discovery. `--layout-rule` with
IR, RAG, Context Bundle, `check`, or `impact` is a conflicting-flags usage
error. Rule flags may appear before or after `--target` / `--target-layout`;
Boris attaches after target synthesis (including synthetic `default`).

**Layout path grammar** (shared by `--html-layout`, `--target-layout` paths,
`--layout-rule` layout paths, and `--theme` roots): workspace-relative only,
`/` separators, no absolute forms, no Windows drive letters, no backslashes,
no empty / `.` / `..` segments, no trailing separator. Invalid layout paths are
usage errors (exit **2**) at parse or target validation — before discovery or
publish. Missing layout files still fail closed without falling through to the
next rule.

### 4.2 Precedence

For each `(target, page)` pair:

1. Exact id rule (sole match).
2. Matching glob with the greatest count of literal segments; equal-specificity
   ties are usage errors even when layout paths are identical.
3. Role rule for the page’s resolved role.
4. Target fallback (`--target-layout NAME=PATH`).
5. Global fallback (`--html-layout`, including `--theme ROOT` sugar).
6. Product default `layouts/main.html`.

Rule declaration order never affects selection. Canonical rule order for
diagnostics and plan digests is `(selector rank, selector bytes, layout path)`.
A winning layout that is missing or invalid fails without silent fallback to
the next rule.

### 4.3 One theme root per target

Every fallback and rule layout for one target must either:

- share one managed theme root (`…/layouts/<file>.html` with a parent segment), or
- be entirely unmanaged legacy layouts (no derived theme root).

Mixing managed roots or managed+legacy within one target is a usage error.
Different targets may use different themes. One footer and one asset inventory
apply to the whole target; rules do not create per-page asset namespaces.

### 4.4 Cache and watch

HTML cache format is `boris-cache-v2-layout-rules`. Each page entry records
`selected_layout`. Fingerprints hash the effective selected layout path and
bytes (plus theme material for that layout), not the full rule table. Watch
observes every declared layout path; a changed layout rebuilds only targets
that declare it. With no `--layout-rule`, behavior matches one-layout-per-target
prior to this slice.

All declared layout paths are validated (loaded/split) even when no page
selects them. Selection runs after the frozen graph and before page workers.
Workers receive an immutable selected layout and never mutate rule tables.

## 5. Theme assets and self-contained output

For each target, Boris creates this output shape in the target's isolated root:

```text
<target-output>/
  assets/                    # copied theme bytes, preserving safe paths
  .boris-cache/              # target-owned cache namespace
  <entity-id>.html           # page outputs
```

Asset ownership rules:

- The selected theme is the sole owner of files copied from its `assets/`.
  Page-owned Markdown media use a separate sibling-tree contract
  (`{stem}.assets/`; see [content-local-assets.md](content-local-assets.md))
  and must not collide with theme `assets/` paths.
- Copying is deterministic: path order is bytewise sorted, file bytes are
  copied exactly, and no timestamps or host paths enter output metadata.
- Asset files are staged and published with the target, not written to a
  shared global cache or another target's directory.
- When a target uses a **managed theme root** (layout path under
  `…/layouts/<file>.html` with a parent segment), Boris scrubs orphan files
  under that target's published `assets/` after each successful publish: any
  file not in the current sorted theme inventory is deleted (covers remove and
  rename). Empty inventory removes the leftover `assets/` tree. Legacy
  `layouts/…` (no theme root) does **not** claim or scrub `assets/`.
- A page output / asset path collision is a preflight usage error. The design
  does not silently prefer a page or an asset.
- CSS `url(...)` references are kept relative to the CSS file. F9 does not
  parse or rewrite CSS; a font/image referenced by CSS must be present at the
  corresponding path under the copied asset tree.
- A normal build has no network dependency and is self-contained when opened
  from the target output directory. External fonts, analytics, images, and
  stylesheets are not silently fetched or vendored.

`asset-url` is preferred for HTML links because it computes the correct
page-relative path. The target root is the URL base; Boris must not emit a
leading `/` that escapes the published site when generating a managed asset
URL.

## 6. Per-target themes and leakage prevention

Target plans remain sorted by canonical target name and execute with the
existing multi-target isolation rules. Each plan carries:

```text
target name
output root
selected theme root / identity
selected layout(s)
layout-rule table, when implemented
asset inventory and digest
cache namespace
```

The same source content may feed `public` and `preview`, but each target gets
its own theme bytes, output assets, stage directory, and manifest. A target
must never resolve a relative asset through another target's output, and
generated output is never a theme dependency. A shared read-only theme input
is allowed; shared mutable output is not.

Target configuration identity must include at least target name, selected
layout path(s), theme identity/path as passed, layout bytes, and the sorted
asset inventory. This extends the current target/layout fingerprint without
changing the existing cache namespace rules.

## 7. Trust, raw HTML, and external stylesheets

Boris currently documents the HTML path as intended for trusted authors, and
Apex may pass raw HTML through. A theme layout and `footer.html` are also
trusted build inputs. F9 must not advertise them as a sanitizer or security
boundary.

Generated sinks are still defensive:

- `title`, metadata values, nav labels, breadcrumb labels, TOC ids/text, and
  generated URLs are escaped or validated at their sink.
- Asset paths are validated before joining them to a target root.
- No template value can execute Zig, JavaScript, Markdown, or a subprocess.
- No remote resource is fetched during a build.

External stylesheet links are allowed only under an explicit experimental
configuration (recommended shape: `--experimental-allow-external-stylesheets`
or its documented target-level equivalent). Without that opt-in, the
compiler-managed stylesheet reference path must reject `http://` and
`https://` URLs and the normal theme acceptance test must remain offline and
self-contained. The opt-in must be visible in target configuration and cache
identity, and should emit a warning or build-report note that output is no
longer self-contained.

This rule cannot make untrusted raw HTML safe: an author can write a raw
`<link>`, `<img>`, or `<script>` when raw HTML is trusted. A future strict mode
may scan or reject common external references, but a scanner is not a general
HTML sanitizer. Deployers handling untrusted content should sanitize or
isolate inputs before Boris and can add a restrictive output CSP.

## 8. Optional Tailwind/DaisyUI experiment

DaisyUI/Tailwind can be useful for evaluating theme ergonomics, but it must
remain an adapter experiment outside Boris's core build graph:

1. A developer uses Tailwind/DaisyUI in a separate, explicitly optional
   workspace to author source CSS.
2. That toolchain produces a concrete, versioned CSS file (and any fonts/images)
   under a theme `assets/` directory.
3. The checked-in or release-staged bytes are supplied to Boris as ordinary
   static theme assets. Boris copies and fingerprints them; it does not run
   Node, Tailwind, DaisyUI, a bundler, or a CDN request.
4. The layout references the emitted file through `asset-url`.

The experiment must therefore prove only that a compiled static CSS artifact
can style Boris output. It must not add Node or a bundler to `build.zig`, the
release gate, the default CLI, or the core repository architecture. A live
CDN link is useful only for a visual comparison and belongs behind the
explicit external-stylesheet experiment flag; it is never the acceptance
path.

## 9. Incremental fingerprints and dependencies

The existing HTML cache fingerprints source bytes, transitive include bytes,
target identity, layout path/bytes, and optional site-nav material. F9 extends
the same content-addressed model; it does not use mtimes as correctness keys.

The internal dependency model for a page is:

```text
page ──uses──> selected layout ──references──> footer / theme assets
page ──uses──> content includes and wiki targets
target ──owns──> complete copied asset inventory
```

For the first implementation:

- A page fingerprint includes selected layout bytes, footer bytes, each
  `asset-url` reference path and the referenced asset bytes, along with all
  existing inputs and target identity.
- A layout change dirties every page selecting that layout. A page rule change
  dirties pages whose selected layout changes.
- A referenced asset change dirties pages that reference it. The asset itself
  is recopied even when its HTML consumers can be reused; conservative
  re-rendering is acceptable for the first slice.
- Any theme asset inventory/path change updates the target asset manifest and
  target staging tree. Unreferenced asset byte changes need not dirty page HTML
  once asset publication is independently tracked.
- A `nav` layout retains the current global nav-material behavior: a relevant
  graph title/parent/role change dirties every page using that layout.
- Page-specific dependency records are target-keyed. No cache entry from one
  target can satisfy another target merely because the page id matches.

Layout and asset edges may first live in the HTML planner/cache dependency
index. They are not new IR v0.2 edge kinds: `ir-schema.md` explicitly says
`layout` and `asset` are internal today. Emitting them in `graph.json` requires
a separate contract amendment, fixture golden, and schema compatibility
decision.

Fingerprint inputs use normalized, content-root/theme-root-relative paths,
length-delimited bytes, stable ordering, and no absolute machine paths,
timestamps, or network responses. Asset publication and cache-manifest writes
remain per-target and deterministic.

## 10. Migration from `layouts/`

Migration is deliberately additive:

1. Keep `layouts/main.html` working as the v0.3.1 default. Existing layouts
   containing only the current five markers remain valid.
2. Continue accepting `--html-layout PATH` and `--target-layout NAME=PATH`.
   These are the compatibility bridge for a layout outside a theme root.
3. Introduce a theme root with `layouts/main.html` and `assets/`; `--theme`
   should be syntactic sugar for selecting that layout plus its asset root,
   not a second renderer.
4. Move the current inline `<style>` from `layouts/main.html` into a copied
   theme CSS file, then replace it with `{{asset-url assets/css/docs.css}}`.
5. Add `metadata`, `footer`, and page layout rules only when their contracts
   and fixture goldens are implemented. A missing optional marker does not
   force every existing layout to change.
6. Keep the existing Trunk/Satellite graph, `parent` key, output path rules,
   Aside stream, Apex in-process adapter, and target staging/cache behavior.

No migration step changes author frontmatter or requires a JavaScript build
stage. A legacy layout with direct relative `href` values may continue to
work, but Boris cannot make those URLs page-depth-correct or fingerprint their
referents until they use managed `asset-url` references.

## 11. Acceptance examples

These are design acceptance examples for the F9 implementation and are
exercised by the real-site-shaped fixture where applicable.

### Slots and relative URLs

Given `experimental-theme/layouts/main.html` uses all seven slots and
`asset-url assets/css/docs.css`, a target built from
`fixtures/theme-site/content/` must produce:

```text
index.html                       contains href="assets/css/docs.css"
guides/getting-started.html      contains href="../assets/css/docs.css"
reference/configuration.html     contains nav, breadcrumb, toc, metadata,
                                 content, and footer in the layout order
assets/css/docs.css              byte-identical to the theme input
```

Generated title, labels, tags, and ids are escaped. The page body preserves
the existing Apex/Aside behavior.

### Selection and isolation

```text
public  → docs theme → dist/public
preview → plain theme → dist/preview
```

A theme CSS edit changes only the owning target's copied asset and affected
HTML/cache entries. `dist/public` is never read as an input for `preview`, and
the two `.boris-cache/manifest.json` files have independent target identities.

### Failure and security

- A missing `{{content}}`, duplicate slot, unknown token, unsafe `asset-url`,
  or page/asset collision fails before publication.
- A normal build makes no network request and contains no managed external
  stylesheet link.
- An external stylesheet is accepted only with the explicit experimental
  opt-in and is represented in target configuration/fingerprint material.
- Changing a footer or selected layout dirties every dependent page; changing
  an unrelated source page does not dirty another target's cached output.

### Optional CSS experiment

The DaisyUI/Tailwind experiment passes only when a prebuilt CSS file is placed
under the theme's `assets/` tree and Boris treats it as opaque bytes. The
default `zig build`, release gate, and bare `boris` invocation do not require
Node, a bundler, or network access.

## 12. Open decisions (post-F9.2)

| # | Decision | Closure |
|---|----------|---------|
| 1 | Page layout rules (CLI vs config) | **Accepted** — `--layout-rule TARGET SELECTOR PATH` (CLI first; no project manifest) |
| 2 | `footer.html` convention | **Accepted** theme-root `footer.html` |
| 3 | Metadata DOM shape | **Frozen** for F9.1: `<dl class="page-metadata">` with Status / Parent / Tags when set; title/id omitted (title has `{{title}}`) |
| 4 | Non-ASCII asset URLs | **ASCII-only, fail closed**; percent-encoding deferred |
| 5 | Asset dirtying vs separate asset manifest | **Conservative** referenced-asset bytes in page fingerprint; unreferenced inventory changes do not dirty HTML |
| 6 | External-stylesheet opt-in warning shape | **Deferred** |
| 7 | IR `layout`/`asset` endpoints | **Deferred** — HTML planner/cache only |
| 8 | Layout UTF-8 boundary | **F9.2** — `Layout.split` / `loadLayout` (`LayoutInvalidUtf8`) |
| 9 | Orphan theme-asset scrub | **F9.2** — post-publish under managed theme roots only |
| 10 | Footer UTF-8 boundary | **Accepted** — `footer.html` validated at theme load (`FooterInvalidUtf8`); same encoding contract as layout, even though footer is not marker-scanned |

### Known limitations (not silent failures)

- `AssetPathEscape` remains a reserved error name; escape is enforced by path
  grammar + collision/symlink checks instead of a separate escape detector.
- Symlink rejection is implemented; portable tests create a symlink when the
  host allows and **skip** when create is denied (sandbox). Not a release-gate
  binary fixture.

## 13. Implementation slices

### F9.1 (landed)

- Closed layout plan in `assemble.zig` (`metadata`, `footer`, `asset-url`).
- Target-owned theme inventory/copy in `theme.zig` with collision checks.
- Fingerprint extension for footer + referenced assets.
- theme-site + theme-adversarial fixtures; sequential/`--jobs`/multi-target.

### F9.2 hardening (landed)

- Layout UTF-8 validation at plan split (`InvalidUtf8` → `LayoutInvalidUtf8`).
- Footer UTF-8 validation at theme load (`FooterInvalidUtf8`) so `{{footer}}`
  cannot inject invalid sequences into published HTML.
- Orphan theme-asset scrub after publish when a managed theme root is in use
  (remove + rename; empty inventory drops `assets/`).
- Expanded fixture/unit coverage: `--theme` path identity, asset-url depths,
  footer/metadata, multi-target isolation, full vs incremental byte-identical
  HTML/assets, traversal/collision/missing/symlink failure paths.

### Layout selection (landed)

- `--layout-rule TARGET SELECTOR LAYOUT_PATH` with `id:` / `glob:` / `role:`.
- Deterministic precedence, one theme root per target, cache format
  `boris-cache-v2-layout-rules` with per-page `selected_layout`.
- Fixtures: `docs/contracts/fixtures/layout-rules/`; pure selector module
  `src/layout_select.zig`. No IR schema change; no DaisyUI/Node/CSS pipeline.

The existing `layouts/main.html` remains the regression fixture throughout.
