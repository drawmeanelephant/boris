# Changelog

All notable changes to Boris are documented here.

Format inspired by [Keep a Changelog](https://keepachangelog.com/).
Versioning: product **v0.3.1** with IR `schemaVersion` **`0.2.0`** and compiler id
**`boris/0.3.1`**. Breaking IR changes must bump `schemaVersion` and update
`docs/contracts/`. Product version bumps may update `compiler_id` / `boris_version`
without changing IR schema.

How to use going forward:

- Add bullets under **`[Unreleased]`** as you land work.
- When cutting a tag, move Unreleased into a dated section and reset Unreleased.
- Prefer one short bullet per user-visible or contract-visible change.
- Link related contracts or fixtures when the IR or acceptance surface moves.

---

## [Unreleased]

### Feature 9.1 — closed layout plan + target-owned theme assets

- Reusable closed layout plan in `assemble.zig`: existing five markers plus
  `{{metadata}}`, `{{footer}}`, and validated `{{asset-url assets/…}}`.
- Target-owned theme asset inventory/copy (`theme.zig`): sorted copy under the
  target output, page/asset collision preflight, symlink and path-escape
  rejection, ASCII-only asset path grammar (fail closed on non-ASCII).
- Theme root derived from `…/layouts/<file>.html`; legacy `layouts/main.html`
  remains unchanged (no managed assets). `--theme ROOT` is sugar for
  `ROOT/layouts/main.html`.
- Page fingerprints include footer + referenced asset bytes when those slots
  are used; asset changes dirty dependent pages. Multi-target isolation
  preserved. Contract: `docs/contracts/templating-and-themes.md`; fixture:
  `docs/contracts/fixtures/theme-site/`.

### Feature 9 — heading-target wiki links

- Wiki links accept section fragments: `[[entity-id#heading-id]]` and
  `[[entity-id#heading-id|label]]`. Fragments match **exact Apex-rendered**
  heading `id` attributes on the target page (no second slugger; same harvest
  approach as `{{toc}}`). Missing or empty fragments fail loud with
  `EREFERENCEMISSING` / `EREFERENCESYNTAX` — no silent page-only fall-back.
  Validation is fail-closed without a heading index; only fragment-target pages
  are rendered for the index. Page-only `[[entity-id]]` is unchanged. IR/RAG
  edge shape unchanged (IR does not check heading membership). Contract:
  `docs/contracts/heading-ids.md`. Sample content dogfoods one section link on
  `content/guides/overview.md`.

## [0.3.1] — 2026-07-15

### P4 — multi-target CLI ergonomics

- `--target` / `--target-layout` argument order is independent: parsed targets
  are sorted by name so equivalent permutations produce the same configuration.
- Bare HTML / `--html` / `--html-dir` still map to synthetic target `"default"`;
  `--target-layout default=PATH` attaches without requiring `--html`.
- Diagnostics and success output list targets in canonical name order with
  effective `out=` and `layout=` paths. Invalid target configuration (names,
  collisions, workspace escape, content/layout overlap) consistently exits **2**.
- `--target` combines with `--watch` and `--incremental` as documented. Contract:
  `docs/contracts/multi-target-isolated-output.md`.

### Feature 8 — graph-native dependency IR

- **F8.0 contracts:** pin target IR `schemaVersion` `0.2.0` and target compiler
  `boris/0.3.0`; define typed `page` / `source` endpoints, direct `parent` /
  `include` / `reference` edges, deterministic `reverseIndex`, validation and
  sorting rules, and a contracts-first fixture skeleton. Graph success artifact
  list includes `reverseIndex`; forward vs reverse dependency walks are explicit.
- **F8.1 resolve + freeze:** after page topology validation, resolve fence-aware
  direct include/reference dependencies from pages and reachable include
  sources; deduplicate and canonically sort typed edges; build the target-keyed
  `reverseIndex`. Existing include/wiki diagnostics block graph publication.
- **F8.2 emit + version:** emit IR `0.2.0` / compiler `boris/0.3.0`, bump product
  and RAG version to `0.3.0`, promote the graph-native fixture to a full golden,
  and enforce it in tests and the release gate.
- **F8.3 reverse-index dirty-set:** HTML planning now builds direct
  parent/include/reference dependencies with the IR 0.2 resolver. Fingerprint
  changes seed the incremental dirty set, then reverse walks expand affected
  parent/reference dependents before bounded workers run. Nested includes use
  forward walks of those same direct edges. Product/compiler/RAG version is
  `0.3.1` / `boris/0.3.1`; IR stays `0.2.0` with no edge-shape change.

### Fixed

- **P4 cache freshness:** incremental HTML reuse now records and verifies a
  SHA-256 `output_digest` of published page bytes (size remains a cheap
  prefilter). Same-length corruption, truncation, and replacement of dist HTML
  force re-render; truly unchanged outputs still cache; manifests stay
  deterministic. Contract: `docs/contracts/html-output.md`.
- Test isolation: compile/assemble filesystem tests no longer use fixed
  `zig-cache/boris-*` workdirs. Parallel `zig build test` executables that
  re-import those modules raced on the same paths and failed with
  `FileNotFound` (layout open / scrub). Paths now use `std.testing.tmpDir`.
- Adversarial backlog (issues #8–#28 remaining after #7/#23): include expansion
  already landed in #29; this cut hardens cache fingerprints (little-endian
  length prefixes, JSON-escaped manifest, output size freshness, page→page
  affected walk), TOC attribute-aware tag ends + OOM free, IR per-file read
  exit code `.io`, Apex NULL≠OOM, aside O(N) line/col cursor, graph freeze O(n)
  id index + per-cycle EPARENTCYCLE messages, wiki O(1) node map, frontmatter
  helper YAML rejection, watch mtime+size / transient poll recovery / debounce
  burst cap / scan dir skips, layout cwd root avoidance, stale HTML prune on
  full rebuild, and pre-open symlink re-check on dist/stage.
- CLI/Apex/TOC hygiene follow-on: multi-target I/O vs content failure split
  (`MultiTargetIoFailed` → exit 3), reserved Apex render status for upstream
  NULL, attribute-aware TOC `id` extraction (not substring), and alloc-failure
  coverage for heading text free-on-OOM.
- Graph validation rejects case-only entity id collisions (`guides/intro` vs
  `GUIDES/INTRO`) with `EINVALIDPATH` — prevents silent output overwrite on
  case-insensitive filesystems. Wires
  `docs/contracts/fixtures/case-id-collision/`. Removes unused `src/discover.zig`
  (divergent dead discovery path that held the unused case-collision helper).
- RAG publish no longer deletes the previous corpus before the new tree is
  installed: move-aside + restore-on-failure, then delete the old tree only
  after a successful swap (`src/rag.zig` `publishCorpus`).
- Aside open-tag scan: newline ends attribute scan / resets quote mode so an
  unmatched `"` cannot force O(N²) rescans of the rest of the body.
- Graph cycle detection walks parent chains iteratively (no deep C-stack
  recursion on long parent paths).
- Frontmatter line reader strips trailing `\r` only for CRLF pairs; bare CR at
  EOF is not treated as a line break.

### Docs

- Apex showcase: enable live dogfood for collapsible callouts, image IAL,
  advanced tables, inline footnotes, bracketed spans / paragraph IAL, and Critic
  Markup (verified under product Apex options). Fenced divs stay pending on the
  long page (next-heading quirk).
- Add durable Codex/ChatGPT review rules for scope control, authority ordering,
  evidence labels, sandbox-aware gate triage, and concurrency/determinism checks.
- Add multi-agent branch discipline: topic branches + PR default, no drive-by
  `main`, intended GitHub ruleset settings for when plan allows enforcement.
- CI: track cmark-gfm source CMake modules (were ignored by Apex pin
  `*.cmake`), add early presence check + aggregate `ci` job for required
  status checks; concurrency cancel on superseding runs.
- Fix U18 D4 smoke: concurrent worker arenas use `page_allocator` (not
  `std.testing.allocator`) so multi-thread Apex stress does not race the
  testing GPA on CI.
- Serialize `apex_render` behind a host mutex (D4): product Apex is not
  re-entrant; parallel `--jobs` keeps per-thread Whiteboards but one C entry
  at a time. Contract note in `docs/contracts/parallel-rendering.md`.

---

## [0.2.1] — 2026-07-15

Minor product cut after **v0.2.0**: Feature 7 (Boris-mediated includes + wiki-links)
on the HTML path, sample-content dogfood, F7 diagnostics/fingerprint polish, and
sandbox hygiene. **IR `schemaVersion` remains `"0.1.0"`** (emit shape unchanged).

| Field | Value |
|-------|-------|
| Package / product | `0.2.1` (`build.zig.zon`) |
| Compiler id | `boris/0.2.1` |
| RAG `boris_version` | `0.2.1` |
| IR `schemaVersion` | `"0.1.0"` (unchanged) |
| RAG format / schema | `boris-rag` / `1` (unchanged) |

### What 0.2.1 adds

- **`{{include path}}`** — Zig expand before Apex (fence-aware; nested; fail loud).
- **`[[entity-id]]` / labeled wiki** — rewrite from the frozen graph on the HTML path.
- **Dogfood sample site** under `content/` with live includes + wiki-links.
- Apex FS includes stay off; IR does not yet expose include/reference edges.

### Feature 7 — Boris-mediated includes + wiki-links — **Done**

- Author `{{include path}}` expands in Zig before Apex (fence-aware; nested;
  cycle/missing fail loud). Content-root `includes/` is not discovered as pages.
- Author `[[entity-id]]` / `[[entity-id|label]]` rewrite to relative Markdown
  links from the frozen graph. Apex FS includes stay off.
- Modules: `src/include.zig`, `src/wikilink.zig`; wired in HTML compile;
  fingerprints hash include bytes + wiki reference material.
- Diagnostics: `EINCLUDESYNTAX`, `EINCLUDEMISSING`, `EINCLUDECYCLE`,
  `EREFERENCESYNTAX`, `EREFERENCEMISSING`. Contract:
  `docs/contracts/includes-and-wiki-links.md`. IR `schemaVersion` unchanged.

### Feature 7 polish — structured diags, multi-body wiki fingerprints, tests

- HTML path prints retain-owned structured diagnostics (`diag.formatText`) with
  code, path, line/column, and remediation for include/wiki failures at plan-time
  and render-time (not bare `@errorName`).
- Wiki fingerprint material unions targets from page body **and** transitive
  include fragment bodies (`referenceMaterialMulti`).
- E2E HTML tests: expand + relative href; missing include/cycle/wiki fail-loud;
  fenced `{{include}}` / `[[wiki]]` stay literal. Unit tests cover tilde fences
  and diagnose helpers.
- Render-path include I/O uses the real GPA (no `page_allocator`). CLI
  `mapHtmlError` skips double-noise stderr for `IncludeFailed` /
  `ReferenceFailed` / `GraphValidationFailed` after structured diags.
- Nested include/wiki failures report the **fragment locus** (file + line/col)
  via owned fail buffers; fingerprint missing-wiki keeps include-body locations.
- Incremental e2e: renaming a page title dirties parents that only wiki-link to
  it through an include (control page stays cached).

### Docs — sample content + hygiene

- Refresh dogfood site under `content/` for product 0.2: HTML default, Apex
  Unified, Feature 6 nav/toc, P2/P3 helpers; closed frontmatter accuracy
  (title optional; not full YAML); real clone URL; Feature 7 live includes/wiki;
  Apex showcase with live / `APEX-PENDING` / `PRODUCT-OFF` samples.
- Removed abandoned `sandboxes/content-dogfood/` agent draft.
- Ignore local `zig-cache/` smoke dirs (alongside `.zig-cache/`).

---

## [0.2.0] — 2026-07-15

Product cut that packages the HTML-default site compiler: ApexMarkdown Unified
(Feature 1), HTML as default CLI (Feature 2), graph-aware nav + in-page TOC
(Feature 6), and P2/P3 incremental / watch / jobs / multi-target on the HTML
path. **IR `schemaVersion` remains `"0.1.0"`** (emit shape unchanged).

| Field | Value |
|-------|-------|
| Package / product | `0.2.0` (`build.zig.zon`) |
| Compiler id | `boris/0.2.0` |
| RAG `boris_version` | `0.2.0` |
| IR `schemaVersion` | `"0.1.0"` (unchanged) |
| RAG format / schema | `boris-rag` / `1` (unchanged) |

### What 0.2 is

- **Default:** `boris` → HTML site under `dist/` (not IR).
- **Markdown:** real ApexMarkdown Unified in-process (tables, footnotes, callouts, …).
- **Structure:** Trunk/Satellite graph validation; layout `{{nav}}` / breadcrumb / title / `{{toc}}`.
- **Scale path:** `--incremental`, `--watch`, `--jobs N`, `--target` multi-output.
- **Also:** JSON IR (`--out` / `--no-rag`), RAG pack (`--rag`). IR schema still `0.1.0`.

### Feature 6 follow-on — in-page heading `{{toc}}` — **Done**

- Layout marker `{{toc}}` (optional, at most once) emits a per-page outline from
  rendered body HTML: `h1`–`h3` with Apex `id` attributes, document order.
- Anchors match body ids (scan HTML after Apex + Aside; no independent slug
  rewrite). Empty fragment when no qualifying headings. h4–h6 omitted from TOC.
- Module: `src/html_toc.zig`. Wired in `assemble` multi-slot + `compile` render.
- Default `layouts/main.html` includes `{{toc}}` with light CSS indent classes.
- Contracts: `docs/contracts/html-output.md`. Page-local; no global nav fingerprint.

### Hygiene — residual risks D2/D3/D4 + publish/dialect/migration

- **D2:** Apex CMake configure disables system libyaml / PkgConfig discovery so
  host packages cannot change product link or behavior. Product frontmatter
  stays Boris-owned; Apex is not fed YAML metadata options.
- **D3:** `scripts/build-apex-markdown.sh` stamps
  `vendor/apex-markdown/build/.boris-apex-stamp` and skips cmake when archives
  and policy are current (fast path under every `zig build`). Force:
  `BORIS_FORCE_APEX_BUILD=1`.
- **D4:** Document concurrent Apex as smoke-validated for product options;
  CLI default remains `--jobs 1`. Permanent gates: U18 + parallel Unified site
  compile (`docs/contracts/parallel-rendering.md`).
- **Publish:** HTML stage tree and IR artifact publish fall back to
  copy+delete on `error.CrossDevice` (not atomic). Cross-volume atomic replace
  still not claimed.
- **Dialect / migration:** Close stale RAG seed wording that accepted
  `parentEntry` on product parse; architecture seed lists HTML as default CLI
  surface. STATUS risk table updated to mitigated/documented.

### Docs — sample dogfood site under `content/`

- Rebuild the sample site for HTML-default + Apex Unified + Trunk/Satellite:
  home, getting started, guides (overview, graph, asides, CLI, Apex, RAG), and
  frontmatter reference. Aside docs avoid bare tags outside fences so the
  component tokenizer stays green. Three modes (`boris`, `--out`, `--rag`) pass.

### Hygiene — remove `archive/` from the tree

- Delete top-level `archive/` (historical Feature 1 reviews, P3 notes, AUDIT-v0.1).
  Living docs and contracts remain the source of truth; do not treat deleted
  campaign notes as required reading.

### Feature 6 MVP — graph-aware HTML site nav — **Done**

- HTML path runs the same Trunk/Satellite `graph.validate` + freeze as IR/RAG
  before render (invalid parents fail the site build, exit 1).
- Layout markers: required `{{content}}`; optional `{{nav}}` (full site forest),
  `{{breadcrumb}}`, `{{title}}`. Multi-slot stream assembly (no page mega-string).
- Default `layouts/main.html` ships nav + breadcrumb + titled chrome with
  relative `href`s from nested pages.
- When `{{nav}}` is present, incremental fingerprints include site-nav material
  so title/parent changes dirty every page that embeds the forest.
- Contracts: `docs/contracts/html-output.md`. In-page heading `{{toc}}` still
  deferred.

### Docs — living tree hygiene (post Feature 2)

- Lead **README** / **STATUS** with user outcomes (site, graph, lean rebuilds)
  before internal mechanics; keep contracts normative and precise.
- Move historical reviews + m10 audit to top-level [`archive/`](archive/)
  (safe to delete or relocate off-tree). Active docs: STATUS, contracts,
  RELEASE-GATE, rag seeds only under `docs/`.

### Feature 2 — HTML as default CLI surface — **Done**

- Bare `boris` (no mode flags) builds an HTML site under `dist/` instead of
  JSON IR under `.boris/`.
- Explicit IR: `--out <DIR>` or `--no-rag` (JSON under `--out`, default
  `.boris`). Explicit HTML flags (`--html` / `--html-dir` / `--target`)
  retained; bare `--jobs` / `--watch` / `--incremental` are valid under the
  HTML default.
- Help text, `scripts/release-gate.sh` (HTML step 4b), README, STATUS,
  contracts (`html-output`, acceptance, overview), and RAG system seeds
  updated. IR `schemaVersion` unchanged (`0.1.0`).
- **Migration:** scripts that assumed bare `boris` ⇒ IR must pass
  `--out .boris` (or `--no-rag`).

### Feature 1 — ApexMarkdown Unified (campaign Chats 1–7) — **Done**

- Vendor real **[ApexMarkdown/apex](https://github.com/ApexMarkdown/apex)** as a
  flat source snapshot under `vendor/apex-markdown/` @ **v1.1.11**
  (`47d25d594b04143cdd747922d7fee8d66b3c5082`), including cmark-gfm and libyaml
  trees at recorded SHAs. Pin record:
  [`vendor/apex-markdown/VENDOR.md`](vendor/apex-markdown/VENDOR.md).
- **Chat 2:** `scripts/build-apex-markdown.sh` + `zig build build-apex` build
  static `libapex.a` (and cmark-gfm) via CMake; `build.zig` links them into
  product modules. Hostile path does not link real Apex. CI installs CMake.
- **Chat 3:** Host `vendor/apex/apex.c` is a real adapter:
  `apex_render` → Unified `apex_markdown_to_html` → copy into host allocator →
  `apex_free_string`. Version string
  `boris-apex/apex-markdown-1.1.11+unified`. File includes/plugins/external
  highlighters off. Host include guard renamed to `BORIS_APEX_HOST_H` so both
  host and upstream headers can be included. HTML goldens updated for header
  ids.
- **Chat 4:** Structural Unified fidelity tests U1–U17 (tables, nested lists,
  footnotes, math, callouts, IAL, fenced divs, dual-run, include-off, Aside
  document order).
- **Chat 5:** STATUS/README/contracts/RAG narrative claim **ApexMarkdown
  Unified**; Feature 1 marked Done; release-gate green. No IR schema or CLI
  default changes (Feature 2 still roadmap).
- **Chat 6:** Internal review
  ([`archive/docs/reviews/feature-1-internal-review.md`](archive/docs/reviews/feature-1-internal-review.md)):
  residual stub wording closed; adapter forces
  `allow_external_plugin_detection=false`; reject `md_len` wrap before NUL
  copy.
- **Chat 7:** External audit response
  ([`archive/docs/reviews/feature-1-external-audit-response.md`](archive/docs/reviews/feature-1-external-audit-response.md)):
  golden HTML pins for table/footnote/math/callout; trusted-author
  `unsafe=true` notice; STATUS tracks D2/D3/D4 with resolve triggers;
  source-rag skips `build`/`CMakeFiles`; full review SHA + sanitizer PASS vs
  SKIP clarification; AUDIT-v0.1 Feature-1 supersession note.
- **Chat 7 follow-through (pay-forward residual):** D4 concurrent Apex evidence
  (U18 multi-thread Unified smoke + parallel Unified site compile under
  `--jobs 8`); Linux CI requires real ASan/UBSan smoke via
  `BORIS_REQUIRE_SANITIZE=1` (macOS remains opt-in skip).
- **Second external opinion (micro-fixes):** pin `remainingAbiAssumptions`
  count to exact 8; `SECURITY` comment on adapter `unsafe=true`; U15b Apex
  callout inside Aside body.
- Retire root `APEX-Feature1-plan.md` after ship: campaign bullets archived in
  [`archive/docs/reviews/feature-1-apex-fidelity-spec.md`](archive/docs/reviews/feature-1-apex-fidelity-spec.md);
  pointers updated to contracts + reviews.

### Docs — residual post-P3 audit cleanup

- Fix underscore diagnostic codes in contract fixture READMEs/prose and RAG
  seed `03-trunk-and-satellite.md` to canonical forms (`EDUPLICATEID`,
  `EPARENTMISSING`, `EPARENTSELF`, `EPARENTNOTTRUNK`, `EPARENTCYCLE`,
  `EFRONTMATTER`, `EINVALIDPATH` for invalid-id). Align
  `fixtures/expected/rag/system/` goldens for 03/09.
- Remove ghost **v0.4.0** “P3.3 complete” release trigger from
  `docs/STATUS.md` versioning table (P3.3 already landed; packaging stays under
  0.2/0.3). No runtime or IR schema changes.
- Feature 1 implementer handoff / archive:
  [`archive/docs/reviews/feature-1-apex-fidelity-spec.md`](archive/docs/reviews/feature-1-apex-fidelity-spec.md)
  (real ApexMarkdown Unified under frozen host `apex.h` — not cmark-as-product;
  root plan retired after ship).

### Docs — post-P3 reconciliation

- Reconcile human-facing and normative docs with landed P2/P3: README CLI
  surface (`--html`, `--jobs`, `--watch`, `--target`, …), RELEASE-GATE checklist,
  contracts ownership/status/non-goals, acceptance/overview, HTML + watch + IR
  non-support wording, RAG narrative seeds, AUDIT historical banner, AGENTS
  concurrency guidance, and `compile.zig` module header. No runtime or IR schema
  changes. Bare CLI remains IR-first; Apex remains a minimal stub ≠ CommonMark.
  Audit note: [`archive/docs/reviews/post-p3-reconciliation.md`](archive/docs/reviews/post-p3-reconciliation.md).

### Multi-Target Isolated Output Directories & Cache Namespaces (P3.3)

- Support multiple explicitly named HTML build targets via repeatable `--target <NAME>=<OUTPUT_DIR>` (implies HTML). Legacy `--html` / `--html-dir` map to a single target named `default` (mutually exclusive with `--target` + `--html-dir`).
- Shared global layout for this slice: `layouts/main.html` (no per-target layout flag).
- Pre-render validation: duplicate names, output equality/nesting (path-boundary prefix), workspace membership with path-boundary checks, workspace-root rejection, target-root symlink rejection when the path exists, and **no overlap with content root or layout path/dir**. Validation failures abort before discovery and exit **2**.
- Isolated output trees and structural cache namespaces: `<target-out>/.boris-cache/manifest.json` per target; sequential sorted target execution with aggregate failure (`MultiTargetCompilationFailed`).
- Cache fingerprints use discriminator `boris-cache-v1-multitarget` and include target name, layout path, and layout template bytes. On-disk manifest `format_version` matches that discriminator; foreign/old versions are ignored (cold rebuild).
- Watch mode ignores events under every configured target output root and rebuilds all targets in sorted order after a debounced change batch.
- Review record and hardening notes: [`archive/docs/reviews/p3.3-multi-target-review.md`](archive/docs/reviews/p3.3-multi-target-review.md).
- P3.3 follow-ups: watch ignore roots precomputed once; shared multi-target fingerprint/dep prep (source/include scan once); best-effort orphan atomic-temp scrub; intermediate symlink component walk on target paths; `--target` in usage/`findBadArg`.
- P3.3 completion: `--html-layout` + `--target-layout NAME=PATH`; selective watch fan-out (layout-only → affected targets); sibling `{dist}.boris-stage` tree commit (discard on failure). Mark P3 scale-out complete in STATUS.

### Docs — status roadmap refresh (post-P2 / closing P3)

- Refresh `docs/STATUS.md` with audit snapshot (P2 complete; P3.1–P3.2 landed;
  P3.3 in flight), post-P3 prioritized feature roadmap (Apex fidelity + HTML
  default as **Now**, multi-target as last P3, TOC later), active implementation
  cards, Not Now list, and v0.2–v0.4 release boundary notes. Align
  `docs/contracts/README.md` status table with the same phase.

### Opt-in Local Development Watch Mode (P3.2)

- Implement opt-in development watch mode via `--watch` flag, bringing real-time, debounced, coalesced filesystem events to local HTML builds.
- Support event coalescing within a fixed 100ms debounce window and deterministic serialization of subsequent rebuilds to prevent concurrent compilation.
- Isolate the watcher behind a clean, testable `Watcher` interface, providing both an in-memory `FakeWatcher` for 100% deterministic test execution and a portable, recursive `PollingWatcher` fallback.
- Support graceful shutdown via POSIX signal handlers (`SIGINT`, `SIGTERM`) using an async-signal-visible atomic flag, cleanly releasing watcher resources after the in-flight rebuild finishes.
- Harden path handling: path-boundary ignore/translate (no `dist`/`distribution` false positives), normalize `./html-dir`, component-aware `.boris` / `.boris-cache` filters, and a 500ms idle poll interval for cheaper full-tree scans.
- Align rebuild error policy with the initial build (content/layout errors keep watching; unrecoverable I/O exits).

### Bounded Parallel HTML Page Rendering (P3.1)

- Add opt-in bounded parallel rendering support (`--jobs N`) for independent HTML page compilation, achieving safe, deterministic thread-pool execution using `std.Io.Mutex` and explicit work coordination.

### Explicit Incremental HTML Build Mode (P2.4)

- Add opt-in incremental HTML mode (`--incremental`), which computes in-memory fingerprints, skips unchanged page generation, cleans up stale assets from `dist/`, and publishes safely and atomically.

### Cache fingerprints and affected-page query (P2.3)

- Implement content-addressed cache fingerprints (using in-process SHA256) and transitive reverse-dependency affected-set queries under `src/cache.zig` with complete unit tests for same-input stability, single-page change boundaries, shared include/layout transitive impact, and alphabetical sorting.

### Layout edges on freeze

- `graph.Edge` gains optional `target`; `freeze` accepts `layout_path: ?[]const u8`.
  When set, each node gets a `kind = "layout"` edge with `to == from` and
  `target = layout_path` (layouts are not graph nodes). Edge sort is
  `(from, kind, to)`. Pipeline passes `null` until IR options carry a path.
- Align `release-gate.sh` expected diagnostics for the `invalid-id` fixture with `docs/contracts/diagnostics.md` (expecting `EINVALIDPATH`).

### Graph-aware navigation in IR (`graph.json` → `nav`)

- Emit a top-level `nav` array on successful `graph.json` (not manifest): per
  page `breadcrumb` (root → self), `children`, and trunk-level `siblings` for
  satellites. Computed only from the frozen Trunk/Satellite graph
  (`parent_index`); no filesystem re-walk, no frontmatter re-parse, no HTML /
  RAG / CLI changes. Sort = entity id order (same as nodes).
  Contract: [docs/contracts/ir-schema.md](docs/contracts/ir-schema.md).
  Implementation: `graph.buildNav` + `pipeline.renderGraph`.

### Quiet mode suppresses diagnostic stderr

- `--quiet` now suppresses diagnostic and I/O error text on stderr in addition
  to progress lines (IR / RAG / HTML entry points). Exit codes and on-disk
  artifacts (including `build-report.json` diagnostics) are unchanged. Unit
  tests already used `quiet: true`, so `zig build test` no longer prints
  expected failure diagnostics as if the suite failed.
  Contract: [docs/contracts/diagnostics.md](docs/contracts/diagnostics.md).

### Opt-in HTML CLI mode

- Default CLI gains opt-in SSG mode: `--html` and `--html-dir <DIR>` (default
  `dist`). Wires to `compile.compileHtmlSite` with layout `layouts/main.html`.
  Mutually exclusive with `--rag`, `--rag-dir`, and explicit `--out` so HTML
  owns its output destination. Default remains IR under `.boris/`.

### Review package step

- Add `zig build package` (`boris-package`): deterministic tar under
  `packages/boris-package.tar` with IR JSON, optional RAG corpus,
  `MACHINE-READABLE-VERSION.json`, and `SHA256SUMS`. Reuses `pipeline.run` /
  `rag.run`; does not change IR schema or HTML defaults.

### Frontmatter parent key containment

- Clarified that author-facing source frontmatter accepts **`parent` only**;
  `parentEntry` / `parent_entry` are rejected as unknown keys (`EFRONTMATTER`)
  on the product parse path (IR + RAG input share `parser.zig`). RAG catalog
  field `parent_entry` remains export packaging only.
  See [docs/contracts/frontmatter.md](docs/contracts/frontmatter.md)
  (migration / compatibility note); README + STATUS + AGENTS aligned.
- Focused parser tests: canonical `parent` accepted; legacy
  `parentEntry` / `parent_entry` rejected with `EFRONTMATTER` (not aliased).
  Non-product `frontmatter.zig` helper gets matching `parentEntry` rejection.
  **No runtime removal** of residual non-product helpers or RAG export field
  names in this change.

### Contracts navigation cleanup

- Explicit non-normative redirect banners on
  [`parent-relationships.md`](docs/contracts/parent-relationships.md),
  [`source-path-and-id.md`](docs/contracts/source-path-and-id.md), and
  [`json-ir-and-manifest.md`](docs/contracts/json-ir-and-manifest.md);
  [`docs/contracts/README.md`](docs/contracts/README.md) ownership map lists one
  canonical normative document per topic (no competing sources of truth).
- Planning notes refreshed: [`acceptance.md`](docs/contracts/acceptance.md) and
  [`v0.1-overview.md`](docs/contracts/v0.1-overview.md) match m10 reality;
  stale “CLI still stubs pipeline” status lines cleared on frontmatter /
  identity contracts; README RAG Aside export note corrected.
- Post-m10 priority list reevaluated in [`docs/STATUS.md`](docs/STATUS.md)
  (P0 hygiene → P1 opt-in HTML / graph nav / Apex fidelity → P2 dependency
  indexes → P3 concurrency last).

### Milestone 10 — v0.1 hardening (Aside + CI + audit)

- Constrained `<Aside>` tokenizer in [`src/aside.zig`](src/aside.zig): kind
  allowlist (`note|tip|info|warning|danger`), optional safe-anchor `id`, quoted
  attributes only, nested Aside rejected, unknown PascalCase tags hard-error,
  recognition **outside** fenced code only.
- Shared pipeline validation emits `ECOMPONENT` ([`docs/contracts/diagnostics.md`](docs/contracts/diagnostics.md)).
- Experimental HTML stream: Apex(markdown) + `aside.renderHtml` in document order.
- RAG export representation: `:::kind` / `:::kind{id="…"}` (non-round-trippable);
  raw `<Aside>` does not remain in exported pages.
- Hardening tests: IR/RAG dual-run determinism, matching graph categories, scanner
  order independence, duplicate-id non-masking, path escape rejection, component
  fixtures ([`src/hardening_test.zig`](src/hardening_test.zig)).
- CI matrix: Linux + macOS; Apex sanitizer remains opt-in local
  (`zig build test-apex-sanitize`).
- Contract: [`docs/contracts/components.md`](docs/contracts/components.md).
- Self-audit: [`archive/docs/AUDIT-v0.1.md`](archive/docs/AUDIT-v0.1.md).
- Docs/seeds synchronized; publishing-workshop analogies paired with invariants.

### Milestone 9 — experimental HTML path (Whiteboard + layout splice)

- Experimental single-threaded HTML path in [`src/compile.zig`](src/compile.zig)
  + [`src/assemble.zig`](src/assemble.zig): document-local Whiteboard arena,
  long-lived PageDb metadata, Apex body render, immutable layout prefix/suffix,
  Zig 0.16 `createFileAtomic` + `Atomic.replace` publication.
- **Not** default CLI (IR/RAG unchanged). `compile.experimental == true`.
- Layout: exactly one `{{content}}`; missing/duplicate hard errors before
  content compile. Three sequential writes only — no mega-string assembly.
- Flush-before-reset tests: `HoldUntilFlush` proves invalidate-before-flush
  fails; production order flush → publish → `free_all`.
- Error paths: render failure does not publish; write failure preserves prior
  final and cleans temp. PageDb survives each Whiteboard reset.
- Fixtures: [`test/fixtures/html/`](test/fixtures/html/) content + expected.
- Contract: [`docs/contracts/html-output.md`](docs/contracts/html-output.md).
- Release gate: Whiteboard flush/reset item checked for experimental path.

### Milestone 8 — in-process Apex C ABI + defensive Zig wrapper

- Native Apex C engine under [`vendor/apex/`](vendor/apex/) (`apex.h` / `apex.c`)
  compiled and linked into the Boris process (no child-process renderer).
- Defensive Zig wrapper [`src/apex.zig`](src/apex.zig): `@cImport` of
  `apex.h`, stack-lifetime `ApexAllocator`, status-before-outputs,
  null+nonzero rejection, arena free no-op, `Html` borrowed lifetime,
  `forbidApexFree` guard. **Not** wired into default IR or RAG CLI paths.
- Hostile C double [`vendor/apex/apex_hostile.c`](vendor/apex/apex_hostile.c)
  + [`src/apex_hostile_test.zig`](src/apex_hostile_test.zig); step
  `zig build test-apex-hostile`.
- Optional ASan+UBSan smoke: `zig build test-apex-sanitize` (documents skip if
  sanitizers unavailable on the host).
- Contract: [`docs/contracts/apex-abi.md`](docs/contracts/apex-abi.md)
  (mechanically checked / tested / vendor assumptions).
- Build: `build.zig` links Apex for product binary + Apex unit tests.

### Milestone 7 — optional deterministic RAG export

- Product RAG export in [`src/rag.zig`](src/rag.zig): reuses
  [`pipeline.compile`](src/pipeline.zig) (scanner → parser → PageDb →
  `graph.validate` → freeze). No second parser or graph implementation.
- CLI: `--rag` → corpus under `rag/`; `--rag-dir DIR` implies RAG-only;
  `--out` remains invalid with RAG flags (exit 2).
- Corpus: `INDEX.md`, `UPLOAD-GUIDE.md`, `catalog.jsonl`, `catalog_meta.json`,
  `system/**` (from `docs/rag/system` when present), `content/pages/**`,
  `graph/entity-catalog.md`, `graph/relations.md`.
- Determinism: stable sorts (system path, entity id, edges by src/tgt,
  catalog by `rag_path`); fixed JSONL field order; metadata-owned single H1
  (strip leading H1, demote remaining H1→H2). No timestamps / absolute paths
  in artifacts.
- Staging publication (`{out}.boris-rag-stage`); failed validation does not
  publish a graph-dependent corpus. Absolute `--rag-dir` supported; cross-volume
  atomic replace not claimed.
- Asides deferred: do **not** fabricate `:::kind` (documented in contract).
- Tests: dual-export byte-identity, catalog parse/field order, H1 rule, system
  seed order, IR/RAG identical diagnostic categories on invalid graph.
- Contract finalized: [`docs/contracts/rag-export.md`](docs/contracts/rag-export.md).
- Golden samples: `fixtures/expected/rag/`.

### Milestone 6 — IR vertical slice (scan → parse → graph → JSON)

- End-to-end content compiler pipeline in [`src/pipeline.zig`](src/pipeline.zig):
  scanner → bounded frontmatter parser → **PageDb** promote → graph validate →
  freeze → deterministic JSON IR.
- Graph validation in [`src/graph.zig`](src/graph.zig): duplicate id, missing
  parent, self-parent, satellite-of-satellite, cycles; freeze only when clean.
- Durable metadata ownership in [`src/page.zig`](src/page.zig) (`PageDb` /
  `DurablePage`); no retained parser slices after source buffers free.
- Emit under `--out` (default `.boris`): `manifest.json`, `graph.json`,
  `build-report.json` with stable field order ([`src/json_out.zig`](src/json_out.zig)).
- Publication: stage to `{out}.boris-stage` then per-file rename on success;
  content failure writes only `build-report.json` and removes graph-dependent
  artifacts. Cross-volume atomicity not claimed.
- CLI IR mode wired in [`src/main.zig`](src/main.zig); exit `1` content, `2`
  usage, `3` I/O. `--quiet` suppresses progress only.
- Diagnostic codes match contracts (`EDUPLICATEID`, `EPARENTMISSING`, …) in
  [`src/diag.zig`](src/diag.zig).
- Integration tests: valid e2e + JSON parse, invalid categories, dual-build
  determinism, no staging paths in IR, promote-after-free.
- Contracts finalized: [`docs/contracts/ir-schema.md`](docs/contracts/ir-schema.md),
  [`docs/contracts/diagnostics.md`](docs/contracts/diagnostics.md).
- Golden samples: `fixtures/expected/valid/`,
  `docs/contracts/fixtures/valid/expected/`.

### Name and metaphor (narrative / roll-forward)

- Document project namesake and compile rhythm **Load → Roll → Ignite → Reset**
  in [`docs/rag/system/10-name-and-metaphor.md`](docs/rag/system/10-name-and-metaphor.md)
  (folk Zouave / Boris temperament; no commercial brand affiliation). Wired into
  system seeds + light identity notes in `AGENTS.md`.
- Forward notes under **To be implemented / roll forward** in
  [`docs/STATUS.md`](docs/STATUS.md) so later milestones can fold metaphor into
  real surfaces gradually. Local `SUPPORT/` gitignored (private scratch).
- Track curated seeds under `docs/rag/system/` (gitignore now only ignores root
  `/rag/` generated corpus, not `docs/rag/`).

### Milestone 5 — bounded frontmatter parser and body splitter

- Strict, iterative frontmatter + body parser in [`src/parser.zig`](src/parser.zig)
  (not YAML; closed key set only). UTF-8 gate; **reject** leading BOM
  (`EINVALIDUTF8`); LF/CRLF fences and fields; body slice after closing fence
  preserved verbatim.
- Source-view metadata ownership: field values and body are slices into the
  caller buffer; `FrontmatterView` / bounds constants on
  [`src/page.zig`](src/page.zig). Absent `title` stays `null` (no heading/filename
  guess).
- Explicit bounds: source 1 MiB, frontmatter 64 KiB, 32 fields, title 512,
  id/parent 255, 32 tags × 64 bytes — limit overflows → `EFRONTMATTER`.
- Unit + fixture-driven tests assert diagnostic **categories** (`EFRONTMATTER`,
  `EINVALIDUTF8`, `EINVALIDPATH`); exercises `fixtures/content/valid/*` and
  parser-invalid suites under `fixtures/content/invalid/`.
- Contract precision: [`docs/contracts/frontmatter.md`](docs/contracts/frontmatter.md)
  (BOM policy, ownership, limits).

### Milestone 4 — content discovery and identity

- Deterministic recursive scanner [`src/scanner.zig`](src/scanner.zig): content
  root walk, case-sensitive `.md`/`.mdx` only, sort by `entity_id` then
  `source_path`, reject directory and page-file symlinks (never follow).
- Centralized identity/path derivation [`src/identity.zig`](src/identity.zig):
  single `canonicalEntityId`; `safeOutputRelativePath` cannot escape output
  roots. Logical metadata uses `/` only (no host absolute paths).
- Discovery-only [`src/page.zig`](src/page.zig) records (`source_path`,
  `entity_id`, `output_path`, `kind`) with explicit retain vs list ownership.
- Fixture + unit tests for recursive scan, sort stability, path rejection,
  `.txt`/`.MD` ignore, and symlink policy (skip on Windows / denied create).
- Contracts: [`docs/contracts/scanner.md`](docs/contracts/scanner.md); updates to
  [`identity-and-paths.md`](docs/contracts/identity-and-paths.md).

### Milestone 3 — typed CLI and exit codes

- Typed CLI parser in [`src/cli.zig`](src/cli.zig): single canonical `Options`
  (`mode: ir | rag`, `input_dir`, optional `out_dir` / `rag_dir`, `quiet`,
  `help`). Defaults: `--input content`, `--out .boris`, RAG dir `rag`.
- Mode rules: default and `--no-rag` → IR; `--rag` and `--rag-dir` → RAG-only;
  conflicts (`--rag`+`--no-rag`, `--no-rag`+`--rag-dir`, explicit `--out` with
  RAG flags) exit **2** (never silently ignore `--out`). Empty values, unknown
  flags, missing values, positionals, and duplicate flags are usage errors.
- Exit-code model in [`src/diagnostic.zig`](src/diagnostic.zig): `0` success,
  `1` content, `2` usage, `3` I/O. Valid modes print “pipeline not implemented”
  and exit 0 until the content pipeline lands.
- `--help` / `-h` exit 0 without filesystem access (injectable runner in tests).
- Table-driven parser tests for valid modes and every conflict/missing-value
  case; main-level exit-code mapping tests.
- README command examples match actual behavior.

### Milestone 2 — contracts and fixture corpus

- Normative contracts under [`docs/contracts/`](docs/contracts/):
  `frontmatter.md`, `identity-and-paths.md`, `diagnostics.md`, `ir-schema.md`,
  `rag-export.md` (plus contracts README). Author-facing parent key is only
  **`parent`** (no `parentEntry`). Closed frontmatter key set; stable diagnostic
  categories (`EDUPLICATEID`, `EPARENTMISSING`, `EPARENTSELF`, `EPARENTNOTTRUNK`,
  `EPARENTCYCLE`, `EFRONTMATTER`, `EINVALIDUTF8`, `EINVALIDPATH`, `EUSAGE`, `EIO`).
- Fixture inventory at [`fixtures/`](fixtures/): `content/valid/`,
  `content/invalid/`, `expected/`, and `manifest.json` documenting expected
  invalid categories. Critical graph/parser error cases covered.
- Fixture discovery tests: [`src/fixtures_test.zig`](src/fixtures_test.zig)
  (inventory + manifest consistency only; no compiler validation yet).
- README / STATUS distinguish **implemented** (CLI help stub) from **planned**
  (scanner, IR, RAG, HTML). Old contract filenames redirect to the new names.

### Tools

- Add standalone **`boris-source-rag`** (`tools/source-rag/`, `zig build source-rag`):
  packs project sources/docs into an LLM upload corpus under `source-rag/`
  (`files/**`, `INDEX.md`, `catalog.jsonl`). Separate from product content RAG;
  does not wire into the milestone-1 `boris` CLI.
- Document source RAG: [`tools/source-rag/README.md`](tools/source-rag/README.md);
  link from README and `docs/STATUS.md`.

### Milestone 1 — project foundation

- Establish minimal Zig **0.16.0** package: `build.zig`, `build.zig.zon` (`0.0.1`),
  executable name `boris`.
- CLI accepts only `--help` / `-h` (and bare invocation): print usage, exit 0;
  any other argument exits 2. No filesystem scan.
- Unit tests cover help/usage parser behavior (`zig build test`).
- CI runs `zig build` and `zig build test` with Zig 0.16.0 pin.
- Docs: truthful README; contracts README clarifies narrative ≠ implementation;
  RELEASE-GATE checklist left unchecked for future milestones.

---

## [0.1.1] — 2026-07-13

Doc↔code reconciliation release. **IR `schemaVersion` remains `"0.1.0"`**
(emit shape unchanged). Product identifiers:

| Field | Value |
|-------|-------|
| Package / product | `0.1.1` (`build.zig.zon`) |
| Compiler id | `boris/0.1.1` |
| RAG `boris_version` | `0.1.1` |
| IR `schemaVersion` | `"0.1.0"` (unchanged) |
| RAG format / schema | `boris-rag` / `1` (unchanged) |

### Documentation (primary)

- **Contracts ↔ code:** `manifest.json` + `graph.json` + `build-report.json`
  (no `pages.json`; nodes carry `bodyOffset`, not body text). Diagnostics live
  on the build report. Acceptance matrix and valid-fixture goldens updated.
- **Narrative seeds** (`docs/rag/system/`): IR-first overview; HTML/Apex path
  marked experimental; qualified claims for atomic HTML publish, Apex
  non-retention (assumptions list), whiteboard arena model, no full YAML,
  no cross-OS determinism without multi-OS CI.
- **Release gate:** [`docs/RELEASE-GATE.md`](docs/RELEASE-GATE.md) +
  [`scripts/release-gate.sh`](scripts/release-gate.sh); CI runs the script.
- Root [`README.md`](README.md), [`docs/STATUS.md`](docs/STATUS.md) refreshed.
- Demo `content/` uses compiler-dialect `parent` (not `parentEntry`).

### Added

- Integration + fuzz/regression harness (`src/harness.zig`, `src/fuzz.zig`,
  `test/fixtures/`, `test/README.md`): multi-page Trunk/Satellite, invalid graph
  cases, frontmatter/UTF-8, component tokenize+render, empty/large pages, layout
  markers, RAG-only vs IR, two-run determinism (HTML/graph/RAG), Whiteboard
  per-page reset isolation, discovery sort independence. Fuzz targets for
  frontmatter, components, Apex pointer/len contracts, and random graph
  topologies vs an independent reference checker (deterministic seed
  `0xB0B15_F027`, bounded iters/sizes). Disposable output under `test-output/`.
  Commands: `zig build test`, `zig build test-harness`, optional
  `zig build test-apex-hostile` (swaps in `vendor/apex/apex_hostile.c`).
- CLI exit code `3` for I/O/system failures; `--no-rag` flag; mutual exclusion of
  `--rag` / `--rag-dir` vs `--no-rag` (usage exit `2`).
- CLI unit tests: flag conflict, unknown flag, `--help`, RAG-only vs IR-only,
  malformed `--input`/`--rag-dir`/`--out`, `zig build rag` arg-forward wiring.
- Assemble publish tests: destination replace-over-prior, failed write keeps
  prior final output, temp cleanup via fault injection before publish.
- RAG machine contract `docs/contracts/rag-export.md` (format `boris-rag`,
  schema version `1`): deterministic corpus rules, `catalog_meta.json`,
  `catalog.jsonl` field order, H1 ownership, `:::kind` export representation.
- Every successful RAG export writes `catalog_meta.json`:
  `{"format":"boris-rag","schema_version":1,"boris_version":"…"}` (fixed key
  order). Documented in INDEX; **not** a `catalog.jsonl` row (same policy as
  `catalog.jsonl` itself).

### Changed

- Single `Options` struct parsed once (`parseOptions`); `--help` exits `0`
  without scanning content.
- Documented mode semantics: `--rag-dir` **implies RAG-only** (not IR+RAG /
  HTML+RAG). Explicit `--out=` with RAG-only is a usage error (never silently
  ignored).
- HTML page publish uses Zig 0.16 `Dir.createFileAtomic` + `File.Atomic.replace`
  (unique hex temp names scoped to the destination directory). On failure only
  the current temp is cleaned; prior final output is preserved. Destination
  replacement is tested on the host OS; cross-device atomicity and Windows
  concurrent-open quirks are documented, not over-claimed.
- Layout `prefix`/`suffix` remain `[]const u8` views into `Layout.raw`; owning
  `Layout` lifetime must exceed all writes (Whiteboard still resets only after
  `writePage` returns).
- RAG export is byte-reproducible: system seeds sorted by relative path;
  content/graph by `entity_id`; catalog + INDEX by `rag_path`. Never emit from
  hash-map iteration order; no timestamps, absolute paths, hostnames, or
  random ids in corpus files.
- Content page titles are **metadata-owned**: sole document H1 from frontmatter
  `title` (else entity_id); leading source H1 stripped; remaining ATX H1s
  demoted to H2.
- RAG `:::kind` blocks documented as export representation of `<Aside>`, not
  round-trippable authoring syntax.
- `catalog.jsonl` keeps pinned field order
  `rag_id, rag_path, category, title, entity_id, role, parent_entry, tags`
  with full JSON string escaping via shared `json_out` rules.

- Apex Zig↔C ABI hardened (`src/apex.zig`, `vendor/apex/`): stack-lifetime
  `ApexAllocator` (not global); pre-init `out_html`/`out_len`; status checked
  before any output slice; reject null+nonzero length; `size_t`/`usize` width
  comptime check; C overflow guards and OOM as `APEX_ERR_OOM` (never null-deref);
  documented non-retention and no-`apex_free` on arena HTML. Tests cover empty,
  large (64KiB bound), invalid UTF-8 bytes, forced OOM, and hostile/mock dirty
  error outputs. Optional `zig build test-apex-sanitize` (ASan+UBSan via `zig cc`).
- Constrained `<Aside>` tokenizer hardened (still not HTML/MDX/`:::`): UTF-8
  gate before body scan; lexical name boundaries; allowlisted attrs
  (`kind`/`id`/`type`) with deterministic duplicate errors; kind allowlist
  `note|tip|info|warning|danger`; safe `id` grammar
  `[A-Za-z0-9][A-Za-z0-9_-]*`; close only at logical line-start `</Aside>`
  (optional spaces/tabs); precise unterminated and nested-Aside errors;
  unknown PascalCase tags remain hard `E_COMPONENT` with path/line/col/name.
  See `docs/rag/system/04-components-and-admonitions.md`.
- HTML/RAG `parser.zig` frontmatter is a **closed bounded grammar** (not YAML):
  UTF-8 required, BOM rejected, LF/CRLF, `---` fences only at column zero,
  one-line `key: value` scalars, precise double-quote rules, rejected nested /
  block / anchor / flow forms; closed keys `title`, parent aliases, `id`,
  `status`, `tags`; duplicate keys and `parentEntry`+`parent_entry` hard-fail;
  explicit byte/key limits; promote-only PageDb strings.
- Contract `docs/contracts/frontmatter.md` rewritten to match both parsers
  exactly (no “YAML-like” claim).
- Single `pathutil.canonicalEntityId` derivation for all entity ids and output
  paths (compiler discover, HTML scanner, RAG). Entity ids **preserve** source
  letter case; case-only collisions emit `E_ENTITY_CASE_COLLISION` instead of
  silent lowercasing.
- Page discovery accepts case-sensitive `.md` and `.mdx` only.
- v0.1 symlink policy: reject symlinked directories and page files (`E_SYMLINK`);
  never recursively follow directory symlinks; diagnose directory-inode re-entry
  (`E_SYMLINK_CYCLE`) and hard-linked duplicate files (`E_SOURCE_PATH`).
- Discovery sorts by canonical `entity_id` (then `source_path`) before later
  stages so processing never depends on filesystem enumeration order.
- HTML (`{id}.html`) and RAG (`content/pages/{id}.md`) paths are built only from
  validated entity ids (`htmlOutputPath` / `ragPagePath`) to prevent output-root
  escape.

### Fixed

- Single shared graph-validation entry `graph.validate` (duplicate ids then topology)
  used by both the IR compiler path and `--rag` before any graph-dependent emit.
- RAG path now runs the same duplicate-id + parent checks as the compiler
  (`E_DUP_ID`, `E_PARENT_MISSING`, `E_PARENT_SELF`, `E_PARENT_NOT_TRUNK`, `E_PARENT_CYCLE`).
- Legacy parser accepts compiler-dialect `parent` (alongside `parentEntry`) so
  shared fixtures validate edges consistently on the RAG path.

### Tests

- RAG: dual-directory byte-identical export; `catalog_meta.json` shape; JSONL
  key order + escaping; sort stability under shuffled fixture creation; one H1
  per content page; machine files excluded from catalog rows.
- Aside tokenizer: AsideFoo boundary, unregistered PascalCase, unterminated,
  duplicate kind/id, invalid kind, unsafe id characters, line-start close
  (spaces/tabs), mid-line / fenced literal `</Aside>`, nested unsupported.
- Fixtures: `longer-cycle/`, `satellite-of-satellite/`.
- Dual-path tests: pipeline and RAG fail with the same graph diagnostic class
  on valid / missing-parent / self-parent / cycles / longer-cycle /
  satellite-of-satellite / duplicate-ids.
- pathutil: nested paths, Windows separators, traversal rejection, extension
  policy, output-path escape rejection, case-preserving ids.
- discover: deterministic entity_id sort, directory/page symlink rejection,
  symlink-cycle fixture (non-Windows).
- parser frontmatter: empty/no-FM, LF/CRLF, unclosed fence, invalid UTF-8, BOM,
  duplicate title/parent aliases, oversize title/block, unsupported YAML forms,
  colon/quoted value grammar.

---

## [0.1.0] — 2026-07-13

Initial content-compiler baseline. This section freezes **what the tree is
trying to be** at the first coherent v0.1 checkpoint, including intentional
gaps still listed in `docs/STATUS.md`.

### Added — content compiler (default CLI)

- Sequential pipeline: **discover → frontmatter parse → graph resolve/validate → freeze → emit**.
- Modules: `src/pipeline.zig`, `src/discover.zig`, `src/frontmatter.zig`,
  `src/graph.zig`, `src/diag.zig`, `src/json_out.zig`, `src/pathutil.zig`.
- CLI (`src/main.zig`):
  - `--input=DIR` (default `content`)
  - `--out=DIR` (default `.boris`)
  - `--quiet`
  - `--rag` / `--rag-dir=DIR` (RAG-only alternate path)
  - Exit codes: `0` ok, `1` content errors, `2` usage
- Emit under out dir:
  - `manifest.json` — schemaVersion, compiler, contentRoot, page summaries
  - `graph.json` — frozen nodes + parent edges
  - `build-report.json` — ok flag, errorCount, full diagnostics list
- Frontmatter closed grammar: `id`, `title`, `parent`, `status`, `tags`
  (not general YAML; unknown keys error).
- Graph validation: duplicate ids, missing parent, self-parent, cycles.
- Normative contracts under `docs/contracts/` with fixture trees and
  pipeline tests wired in `src/pipeline.zig`.
- `schemaVersion` / compiler id: `"0.1.0"` / `boris/0.1.0`.

### Added — agent / project policy

- `AGENTS.md`: Zig + in-process Apex only; no polyglot SSG; phased architecture;
  long-term graph-native build-system direction; hard “do not” list for agents.
- Contract docs: source path/id, frontmatter, parent relationships, JSON IR,
  diagnostics, acceptance criteria.

### Added — RAG export (alternate path)

- `zig build rag` / `boris --rag` → corpus under `rag/` (INDEX, UPLOAD-GUIDE,
  system seeds, content pages, graph, catalog).
- Curated seeds in `docs/rag/system/` (00–09).
- CI check: two RAG exports are byte-identical (`diff -r`).

### Present — HTML / Apex stack (not default CLI)

- In-process Apex C ABI (`vendor/apex/`, `src/apex.zig`) linked via `build.zig`.
- Whiteboard compile loop, Aside component parsing, layout zero-copy assemble
  modules remain and are unit-tested (`compile`, `parser`, `aside`, `assemble`,
  `scanner`, `page`).
- Default `boris` **does not** write `dist/`; site HTML is legacy/experimental
  relative to v0.1 acceptance (contracts deliberately exclude HTML).

### Added — engineering hygiene

- Zig 0.16 entry (`std.process.Init`, `std.Io`, unmanaged lists).
- `zig build` / `zig build test` / `zig build run` / `zig build rag`.
- GitHub Actions CI: install Zig 0.16.0, build, test, RAG determinism.
- `.gitignore` for `.zig-cache/`, `zig-out/`, `dist/`, `rag/`, `.boris/`.

### Known limitations at 0.1.0 (do not treat as bugs-of-the-week)

- Contract docs still partially describe `pages.json` and a narrower FM key set;
  implementation emits `graph.json` + `build-report.json` and richer FM keys —
  **reconcile before advertising IR stability**.
- Dual frontmatter dialects: compiler (`parent`) vs parser/RAG (`parentEntry`).
- Demo `content/` may still use `parentEntry` and fail compiler validation.
- No watch mode, incremental rebuild, worker pool, or reverse dependency index yet.
- No root README at tag time (see STATUS for operator cheat sheet).

### Changed / deferred relative to early SSG narrative

- Primary product story shifted from “always emit HTML + RAG” to
  **“validate content graph + emit versioned IR”**, with RAG opt-in and HTML
  retained as modules for a later phase.
- Contracts mark HTML, components, and RAG **out of v0.1 acceptance** even
  though code and seeds still exist in-repo.

---

## Version history legend

| Tag / section | Meaning |
|---------------|---------|
| `[Unreleased]` | Landed on main, not yet cut as a release note block |
| `[0.2.0]` | HTML-default product cut: Features 1+2+6, P2/P3; product `boris/0.2.0` |
| `[0.1.1]` | Doc↔code reconciliation + release gate; product `boris/0.1.1` |
| `[0.1.0]` | First content-compiler checkpoint |
| Later `0.2.x` | Fixes/docs within same product minor if IR schema stays `"0.1.0"` |
| New `schemaVersion` | Deliberate IR shape break (not required for product 0.2) |
