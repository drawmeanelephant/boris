# Changelog

All notable changes to Boris are documented here.

Format inspired by [Keep a Changelog](https://keepachangelog.com/).
Versioning: the current product release is **v0.9.0** (2026-10-11) with base
IR `schemaVersion` **`0.2.0`** and compiler id **`boris/0.9.0`**. Breaking IR
changes must bump `schemaVersion` and update `docs/contracts/`. Product version
bumps may update `compiler_id` / `boris_version` without changing IR schema.
The historical `v0.8.0` tag is preserved as erroneous evidence; see
[`docs/STATUS.md`](docs/STATUS.md).

How to use going forward:

- Feature/fix PRs add one fragment under
  [`docs/changelog.d/`](docs/changelog.d/README.md); do not edit the shared
  **`[Unreleased]`** section.
- At release cut, the release owner assembles the fragments into a dated section,
  in the documented deterministic order, then removes or archives them and resets
  Unreleased.
- Prefer one short bullet per user-visible or contract-visible change.
- Each fragment includes at least one repository-root-relative Markdown link;
  link the relevant contract when the IR or acceptance surface moves.

---

## [Unreleased]

New fragments land under
[`docs/changelog.d/`](docs/changelog.d/README.md); the release owner assembles
them into a dated section at the next release cut. The `[0.9.0]` section was
assembled from those fragments on 2026-10-11.

## [0.9.0] — 2026-10-11

The v0.9.0 release keeps base IR `0.2.0` (conditional semantic-relation and
recipe artifacts retain their conditional IR `0.3.0` / recipe `0.4.0` schemas)
and steps the line past the post-v0.8.2 maintenance phase into a fuller
publisher platform: publication profiles now *execute* — `build`, `watch`, and
`validate --profile` run declared HTML targets end to end — the CLI gains
`boris graph` (Mermaid / Graphviz DOT) and the `boris proof verify` enforcement
gate, opt-in compiler-owned head metadata ships with a bounded RSS
autodiscovery rider, HTML 4.01 Strict is an opt-in publication profile with its
own theme, `boris init` materializes fifteen compile-verified starter
archetypes, Windows builds and runs natively on the Zig 0.17 toolchain, the
opt-in NIP-42 signing supervisor lands for the Nostr surface, and the Boris
Editor grows a managed watch daemon, a graph map, a focus writing mode,
dark-mode design tokens, density modes, and a certified keyboard-first
accessibility posture. Every catalog theme reached a measured accessibility
floor, and several — cards, tokens, field-notes, columns, semantic,
html4-strict — gained a distinct voice of their own.

### Added

- Added opt-in HTML 4.01 Strict publication with a compatible theme, fail-closed whole-page and proof presentation checks, and located diagnostics; HTML/XHTML defaults remain unchanged ([profile contract](/docs/contracts/html4-strict.md), [#1003](https://github.com/drawmeanelephant/boris/issues/1003)).

- `boris validate --profile PATH` runs the profile's declared HTML targets as a zero-write prepublication validation pass: declared layouts, layout rules, static directory, sitemap path, input, and site URL drive the run, competing HTML selectors are conflicts, and declarations the validator cannot execute (editions, per-target RSS/llms, multi-target sitemap/static, publication locations, a sitemap declaration without `site.url`) refuse with exit 2 and a named field. Links: [the publication-profile contract](/docs/contracts/publication-profile.md) (Refs #1006; profile-driven build/watch remain deferred).

- `boris build --profile` and `boris watch --profile --serve` now execute supported declared HTML targets without repeated layout/theme/static flags, using the profile workspace and the existing compiler/watch pipeline; validation shares the mapping, static-file links participate in both output audits, and unsupported declarations fail before subset publication. See [the profile execution contract](/docs/contracts/publication-profile.md#html-execution).

- Opt-in [compiler-owned head metadata](/docs/contracts/head-metadata.md):
  target-local canonical/description, real OpenGraph and explicit Twitter tags,
  exact-page overrides, image preflight, Strict omission/refusal, draft exclusion,
  and shared build/validate semantics. The bounded single-target RSS rider emits
  autodiscovery; article publication dates use existing frontmatter, modification
  dates require explicit configuration. New declarations negotiate plan schema 3;
  existing configurations and profile execution limits otherwise stay unchanged.

- Implement the opt-in NIP-42 signing supervisor and proactive article gate, with schema-2 negotiation and hostile two-process loopback tests, including startup custody, forged controls, blocked-operation teardown and entropy/signing failure injection. Invalid/overlong session keys retain content-refusal exit 1. The capability remains unreleased pending review and required CI; macOS is the only supported session launcher, and ordinary schema-1 plan/sign/publish bytes remain unchanged. See [the Nostr evidence and limits](/docs/contracts/nostr-publication.md#phase-2-implementation-notes-and-release-evidence-boundary).


- `boris check` now reports advisory findings for valid-but-flat corpora —
  `flat_graph`, `unlinked_page`, `zero_includes`, and `zero_relations` — all
  informational (exit 0) unless a matching `--fail-on-*` flag opts in;
  corpus-level findings use the new `graph` endpoint type in the report. See
  the [Documentation Intelligence contract](/docs/contracts/documentation-intelligence.md)
  and the [CLI contract](/docs/contracts/cli.md).

- Added additive [theme metadata hooks](/docs/contracts/templating-and-themes.md)
  (#1007): a repeatable, attribute-safe `{{page-status}}` token (e.g.
  `<body data-status="{{page-status}}">`, empty string when `status` is unset),
  a once-only `{{tags}}` slot emitting `<ul class="page-tags"><li>…</li></ul>`
  from closed `tags` frontmatter, and a once-only `{{parent}}` slot emitting a
  resolved direct-parent `<nav class="page-parent">` title/link from the frozen
  graph. The frozen `{{metadata}}` `<dl>` shape, raw parent id, and absent-marker
  output are unchanged; `ul.page-tags` and the Strict `div.page-parent` are
  excluded from [rendered search](/docs/contracts/rendered-search.md) as
  compiler chrome.

- `boris init [DIR] [--type NAME]` materializes five deterministic,
  compile-verified starter archetypes: `docs` (the unchanged default),
  `garden` (dense wiki links, semantic relations, `{{include}}`
  composition, and a registered `<Aside>` under the `ledger` theme),
  `cookbook` (Cooklang `.cook` pages under `cards`, profile declaring
  `"input_format": "cook"`), `blog` (dated posts on a parent chain under
  `cozy`), and `textile` (`.textile` pages under `press`, profile
  declaring `"input_format": "textile"`). Each archetype ships its own
  theme byte-identical to the `themes/` catalog and a `boris.json`
  profile that drives the build — the compiler gains no per-archetype
  branches. Missing-content diagnostics now point at `boris init` as a
  starter path. See [the CLI contract](/docs/contracts/cli.md#init-deterministic-starter-scaffold-with-self-verification),
  [the includes contract](/docs/contracts/includes-and-wiki-links.md),
  [Cooklang compatibility](/docs/contracts/cooklang-compatibility.md), and
  [Textile compatibility](/docs/contracts/textile-compatibility.md).

- The published-output link audit shared by `boris build` and `boris validate`
  now checks the `#fragment` of every resolved local reference against the
  target page's rendered element `id` set (all elements, not only headings —
  matching `doctor`). A fragment that names no rendered anchor reports
  `EFRAGMENTMISSING` as a **warning**: it is printed and collected without
  failing the build, and the stale `href` is published verbatim rather than
  rewritten. Links:
  [diagnostics contract](/docs/contracts/diagnostics.md),
  [documentation-links contract](/docs/contracts/documentation-links.md),
  [link-fragments fixture](/docs/contracts/fixtures/link-fragments/README.md).

- The editor host's preview state (`GET /api/preview/state` and a `200` from
  `POST /api/preview/rebuild`) carries an additive `stale_reason` —
  `earlier_build` when `dist/` was already on disk at startup, `failed_rebuild`
  when a rebuild failed, timed out, or could not run and the last valid tree was
  kept, and `null` whenever `phase` is not `stale` — so the shell no longer
  infers a startup warning from a failed rebuild's `exit_code`. Older hosts
  without the field keep the `exit_code` fallback. Links:
  [the editor-host contract](/docs/contracts/editor-host.md#82-fixed-rebuild-command),
  [issue #1068](https://github.com/drawmeanelephant/boris/issues/1068).

- Added the first-class [`gallery` theme](/themes/gallery/README.md) (#1052):
  an image-first `home` layout that lays out `{{children}}` as an album grid,
  a `main` layout for albums and single images with `figure`/`figcaption`
  styling for hand-scaled [content-local assets](/docs/contracts/content-local-assets.md),
  the full accessibility floor, and no JavaScript. The
  [`gallery-site` specimen](/examples/gallery-site/README.md) ships
  deterministic, locally generated images at three page depths.

- [The init theme coverage matrix](/docs/init-theme-matrix.md) names at
  least two smoke-verified first-party themes for every `boris init --type`
  scenario, the theme slots each one carries, and the theme gaps that
  remain ([#1051](https://github.com/drawmeanelephant/boris/issues/1051)).
- `boris init --type landing` writes a single-Trunk site under `service`:
  one long page composed from `{{include}}` section fragments, one
  satellite, and profile `layout_rules` that send `id:index` to the
  theme's `home.html`
  ([#1054](https://github.com/drawmeanelephant/boris/issues/1054),
  [the CLI contract](/docs/contracts/cli.md#init-deterministic-starter-scaffold-with-self-verification)).
- `boris init --type wiki` writes a three-level reference tree under
  `reference` (index → section hubs → entries) with cross-entry wiki
  links; `layout_rules` send the index to `home.html` and the hubs, via a
  single `glob:wiki/*` rule, to `section.html`
  ([#1055](https://github.com/drawmeanelephant/boris/issues/1055)).
- `boris init --type link-in-bio` writes the smallest starter: one trunk
  page holding a personal link list, under `minimal`
  ([#1057](https://github.com/drawmeanelephant/boris/issues/1057)).
- `boris init --type changelog` writes release notes under `journal`: an
  `index` → `changes` → dated-entry chain with `published_at` +
  `summary`, and one `status: draft` unreleased entry that renders but
  stays out of search, RSS, and sitemap output
  ([#1056](https://github.com/drawmeanelephant/boris/issues/1056),
  [status gating](/docs/contracts/html-output.md)).
- `boris init --type resume` writes a single-page CV under `corporate`:
  tags rendered by `{{metadata}}`, one "now" satellite, and the theme's
  print stylesheet as the PDF path
  ([#1058](https://github.com/drawmeanelephant/boris/issues/1058)).
- `boris init --type newsletter` writes a weekly paper under `press`
  whose `layout_rules` route the masthead, back-issue archive, and dated
  issues to press's `home`, `archive`, and `blog` layouts. Its profile
  declares `site.url` and a target `sitemap`, so the first build emits
  `dist/sitemap.xml`. Profile `rss` is not declared yet because press
  layouts lack the `{{head}}` slot the RSS rider requires
  ([#1060](https://github.com/drawmeanelephant/boris/issues/1060),
  [head metadata](/docs/contracts/head-metadata.md#bounded-rss-rider-and-execution-boundary)).
- `boris init --type portfolio` writes a studio site under `showcase`: an
  index, an about page, and three dated project satellites, with profile
  `layout_rules` sending `id:index` to the theme's `home.html` and every
  other page to `main.html`
  ([#1053](https://github.com/drawmeanelephant/boris/issues/1053)).

- `boris init --type archive` writes a long-lived archive under `archive`:
  four tagged entries joined by `relates_to` and `supersedes` relations, so
  entry pages render `{{relations}}` and the derived `{{backlinks}}`; one
  `status: archived` record; and a hand-kept `topics` index by tag.
  `layout_rules` send `id:index` to the theme's `archive.html`
  ([#1059](https://github.com/drawmeanelephant/boris/issues/1059),
  [the CLI contract](/docs/contracts/cli.md#init-deterministic-starter-scaffold-with-self-verification)).
- `boris init --type dashboard` writes a project-status board under
  `engineering`: three projects, one per `status:` value, each showing a
  visible status label, with the status-to-project-state mapping
  (`published` = active, `draft` = proposed, `archived` = retired)
  documented on the board, `depends_on` / `supersedes` relations, and
  status-history tables. `layout_rules` send `id:index` to `home.html`
  ([#1062](https://github.com/drawmeanelephant/boris/issues/1062)).
- `boris init --type photo-gallery` writes an image gallery under the new
  `gallery` theme: a cover page and two albums, each page carrying small
  self-made PNG plates in its own `{stem}.assets/` folder inside
  `<figure>` captions, with `layout_rules` sending `id:index` to the
  album-grid `home.html`
  ([#1061](https://github.com/drawmeanelephant/boris/issues/1061),
  [content-local assets](/docs/contracts/content-local-assets.md)).
- The `boris init --type newsletter` profile now enables `head` and
  declares `rss`, so the first build writes a three-item `dist/feed.xml`
  and an autodiscovery link in every non-draft page head; a `status:
  draft` issue stays out of the feed and sitemap
  ([#1060](https://github.com/drawmeanelephant/boris/issues/1060),
  [head metadata](/docs/contracts/head-metadata.md#bounded-rss-rider-and-execution-boundary)).
- Every `boris init` starter now writes its theme's full catalog file set,
  including the `ACCESSIBILITY.md` that the `cards`, `service`,
  `reference`, `minimal`, `corporate`, and `showcase` READMEs link to
  ([#1046](https://github.com/drawmeanelephant/boris/issues/1046)).

- Every single-layout theme now has a recorded named-layout decision in its
  README ([theme catalog](/themes/README.md), #1050). `journal` gains
  `layouts/archive.html`, a log index whose `$ ls entries/` listing is the
  page's `{{children}}`, for dated-entry trees such as the `changelog`
  starter (`id:changes`). `cards` gains `layouts/home.html`, an intro card
  above a deck of child cards, the shape a cookbook recipe box wants.
  `boris`, `cozy`, `ledger`, `reading`, `corporate`, `minimal`, and
  `html4-strict` stay single shape by design, and each README records the
  reason. `showcase/layouts/home.html` now renders `{{children}}` as a
  search-excluded project grid, so the `portfolio` index lists its projects
  from the graph (#1053). Every catalog theme maps to a buildable specimen in
  [`examples/README.md`](/examples/README.md): `studies-site` is the shared
  corpus for `semantic`, `columns`, `service`, `engineering`, `civic`,
  `tokens`, `corporate`, `minimal`, `boris`, and `html4-strict`, and it gains
  a typed relation and a footnote. Its documented command no longer fails
  with `FileNotFound` for the single-layout themes. `corporate`'s print pass
  also forces a white shell surface and keeps body links underlined.

- `boris proof verify` (#840 piece 2): the publication-check enforcement gate as a contracted product command. It reads the committed `checks.json` of one target (target-bound from the report itself) and applies an explicit severity policy — `--max-errors` (default `0`), `--max-warnings` (default unlimited; warnings counted and reported), and repeatable `--block-code` promotions. Exit `0` pass, `1` policy failure, `2` usage, `3` missing/unparsable proof (fail-closed: missing evidence never passes). `incomplete` verdicts and not-applicable checks are always reported. The GitHub Pages deploy now runs it before the upload, so committed error findings block publication while warnings stay visible and non-blocking. Links: [the CLI contract](/docs/contracts/cli.md), [#840](https://github.com/drawmeanelephant/boris/issues/840).

- Publication-check verdict in the build and watch output (#840 piece 1): every non-quiet HTML build and every watch rebuild/initial build prints one line read back from the committed `checks.json` — `checks: 3/3 passed`, or the failing/incomplete checks with severity counts and the deploy consequence (`checks: 2/3 — rendered-html failed: 1 warning — deploy passes`; error findings read `deploy blocks`). Not-applicable checks are counted, never silent; a missing or unparsable report omits the line (chrome never fails the build). Enforcement itself stays out of the build per #740/#741 — the `boris proof verify` gate and the deploy wiring are the next pieces. Links: [the publication-checks contract](/docs/contracts/publication-checks.md), [#840](https://github.com/drawmeanelephant/boris/issues/840).

- The Boris Editor UI ships a design-token system with a dark mode: semantic color/spacing/radius/elevation tokens derived from the existing green-and-rust identity, a persisted `Theme: dark` / `Theme: light` header toggle that defaults to `prefers-color-scheme`, WCAG AA contrast in both themes, and the rust focus ring kept as the a11y signature; the Svelte app is migrated to runes mode with typed state modules under `editor/ui/src/lib/state/` and reduced-motion-gated motion (dialog fade/scale, problem-group and palette transitions, preview width tween) that only reflects real state changes ([editor/README.md](/editor/README.md)).

- The editor host now supervises one managed `boris watch --watch-json` daemon
  per project: authenticated start/stop/state/event endpoints surface the
  compiler's contracted NDJSON build-event stream with monotonically
  increasing sequence numbers, rebuilds are refused while the daemon owns the
  `dist/` writer seat, and stopping the daemon (or the host) always reaps it.
  An explicit stop also clears any crash residue, so the post-stop state reads
  `idle` with no stale `last_error`.
  See [the editor README](/editor/README.md) and
  [the watch-mode contract](/docs/contracts/watch-mode.md).

- The editor UI gains a Watch pane for the managed watch daemon: honest
  idle/running/success/failed/stale state naming, a bounded newest-first feed
  of the compiler's `--watch-json` build events with ring-eviction boundaries
  labeled, explicit Start/Stop controls plus command-palette entries, a
  preview-rebuild refusal note when the daemon owns the `dist/` writer seat,
  and an honest "not supported" notice against hosts without the backend —
  see [the editor README](/editor/README.md) and
  [the watch-mode contract](/docs/contracts/watch-mode.md).

- `scripts/agent-pack.sh` gains opt-in `--with-editor`: it builds the
  `boris-editor` host and bundles it with the prebuilt UI shell under
  `ui/dist/`, records `"editor_ui": true` in `MANIFEST.json`, and covers the
  UI files in `SHA256SUMS`. The default kit stays slim. Links:
  [the agent binary kit guide](/docs/AGENT-BINARY-KITS.md),
  [the editor README](/editor/README.md).

- CI now fails a PR that references an open issue without declaring, per issue, whether the merge closes it (`Closes #N` — one issue per keyword, any GitHub close synonym, no comma lists, no bold-wrapped keywords) or leaves it open (`Refs #N` / `Related to #N` — reported to the reviewer, never force-closed) — a bare `#N` mention declares neither — so multi-issue fixes can no longer orphan issues at merge time ([the PR template](/.github/PULL_REQUEST_TEMPLATE.md)).

- The `pr-issue-close` lint can now be driven offline: `--pr` and `--body-file`
  share one verdict path, and `ISSUE_CLOSE_LINT_FIXTURE=<path>` supplies issue
  states in place of the API, so a body is judged with no network and no `gh`.
  The grammar self-test uses that seam to run the real entry point as a
  subprocess, pinning the inert-vs-live matrix — report text, class guard, and
  exit codes — in 61 cases under macOS `bash` 3.2. A number the fixture omits
  is an error rather than a skip, so a fixture typo cannot turn a real violation
  into a passing test. Links:
  [the lint](/scripts/check-pr-issue-close.sh),
  [the CI lane](/.github/workflows/ci.yml).

- `boris graph` renders the frozen content graph as deterministic text: Mermaid (default, copy-pasteable into GitHub/Notion) or Graphviz DOT, with read-only compile semantics, `--input DIR`, `--format mermaid|dot`, and `--out PATH` (stdout otherwise). The projection consumes the frozen nodes and typed `parent` / `include` / `reference` edges plus author semantic relations, aliases source endpoints, and escapes labels through the shared encoder. Links: [the graph render contract](/docs/contracts/graph-formats.md), [the CLI contract](/docs/contracts/cli.md), [documentation-intelligence fixtures](/docs/contracts/fixtures/documentation-intelligence/README.md).

- The Editor **Graph** pane now draws a deterministic visual map of the frozen graph above its lists: pages layer by hierarchy, `parent` edges are solid, references dashed, and node borders scale with topology (direct children plus incoming references). The SVG is `aria-hidden` — a pointer convenience for review, with the existing named lists kept as the keyboard path. Links: [the editor guide](/content/guides/editor.md), [the graph render contract](/docs/contracts/graph-formats.md).

- The Editor graph map opens fit-to-width (never upscaled past actual size) and gains visible zoom controls — zoom in/out, Fit, and Actual size with a live percentage — plus a focusable scroll viewport so the wheel, touch, and arrow keys pan. This fixes wide-graph clipping without adding a dependency or a drag handler; the SVG stays `aria-hidden` and the named lists remain the keyboard path. Links: [the editor guide](/content/guides/editor.md).

- The editor now documents a CLI to editor capability matrix and allowlists two more read-only Boris commands: **Export graph** (`boris graph`, Mermaid by default or Graphviz DOT) and **Verify proof** (`boris proof verify --html-dir dist`), while conflict compare panes open at the top of both columns. Links: [the editor-host contract](/docs/contracts/editor-host.md), [the editor README matrix](/editor/README.md#cli-to-editor-capability-matrix), [#983](https://github.com/drawmeanelephant/boris/issues/983), [#984](https://github.com/drawmeanelephant/boris/issues/984), [#985](https://github.com/drawmeanelephant/boris/issues/985), [#986](https://github.com/drawmeanelephant/boris/issues/986).

- Every ordered scale the editor declares — the type chain, the spacing rhythm,
  the corner steps, and the stacking ladder — now writes its order down exactly
  once, in a `--scale-*` list in `editor/ui/src/lib/tokens.css`, and nothing
  else keeps a copy. `--scale-space-base` declares the spacing rhythm's base
  instead of describing it in prose, and the six bare `z-index` values in
  `styles.css` became `--layer-*` names, so the ladder is the only authority on
  stacking order.
- `editor/ui/scripts/check-scales.mjs`, run by `npm run check`, holds the static
  half: every declared token of each family is classified, every listed name
  exists, each list ascends (numerically where a value is resolvable without a
  viewport, and reported as deferred where it is a `clamp`), spacing steps are
  whole multiples of the declared base, the layer ladder holds bare numbers,
  every scale token is declared once and only in `tokens.css`, every `var()`
  reference lands on a declared step, no `z-index` is a bare number, and each
  documented section names its scale's list without naming tokens that do not
  exist. It runs its own self-tests first, so the checker is checked.
- `editor/ui/tests/scales.spec.ts` holds the half that needs a viewport. It
  resolves the same lists out of the *applied* stylesheet at four widths, which
  is the only way to check a `clamp` step, a value overridden further down the
  cascade, or the rhythm's base — and it asserts that the sticky nav and the
  skip link carry the declared layer rather than a loose number. The rendered
  heading levels stay in `editor/ui/tests/reading-hierarchy.spec.ts`, now
  measured in both density modes.
- That last point is why any of this exists: the prior hierarchy suite pinned
  Review density only, so an Author-only override could flatten the app title
  onto the pane-title size with every suite green. Which is exactly what
  happened, and what these scales are now walked against.

- The editor UI gains a focus writing mode: a full-screen, word-processor
  style surface for the open buffer with Write / Split / Preview layouts
  (choice persisted per browser), typography controls (text size
  S/M/L/XL, reading measure Narrow/Medium/Wide, and a Serif/Sans
  typeface toggle, persisted and validated on load), a live reading aid
  that renders the bounded Markdown subset an author types (headings,
  paragraphs, emphasis, code fences, quotes, lists, wiki links, and Aside
  tokens) with honest non-navigable wiki links, full escaping, and a
  frontmatter block that renders as a muted collapsed band rather than
  body text, word count and caret status, and entry/exit from the Source
  pane's Focus button or the command palette. Opt-in writing aids
  (persisted and validated on load): typewriter scrolling keeps the typed
  line vertically centered, and paragraph dimming veils everything but the
  caret's paragraph through a masked overlay. The overlay edits the
  shared buffer, so undo/redo, recovery snapshots, conflict handling, and
  saves are the shell's existing machinery — see [the editor
  README](/editor/README.md).

- Editor section navigation now gives arrival feedback (#941): activating a
  nav link focuses the target section and pulses it (static highlight under
  `prefers-reduced-motion`), a scrollspy hands `aria-current` to the section
  at the reading top, the nav sticks below the viewport with targets carrying
  a measured `scroll-margin-top`, nav activation hands focus to the landed
  section, and narrow viewports gain edge affordances on the pill row. The
  change also resolves the duplicate `id="graph"` between the Source pane's
  empty state and the real Graph pane.
  Links: [the component](/editor/ui/src/components/SectionNav.svelte).

### Changed

- Boris now builds on Zig **0.17.0**: `minimum_zig_version` is `0.17.0` across
  the root, editor, and tool packages, CI pins 0.17.0, and the Oliver pin moves
  to `2a0a1e9` (its 0.17-compatible revision). Author-facing grammar, IR, and
  `dist/` output are unchanged. Links:
  [the Oliver renderer contract](/docs/contracts/oliver-renderer.md),
  [project status](/docs/STATUS.md).

- The editor shell has one visual vocabulary over its tokens — a single button
  system (primary, secondary, danger, ghost), badge, notice, empty state, card,
  toolbar, and row list — and every pane now renders a designed loading,
  unavailable, empty, stale, or `build_required` state instead of incidental
  text. Panes no longer claim "no files", "no profile", or "no Proof Pack"
  before the host answers (or when it never does), warning-severity problems
  stop rendering as errors, and a startup `stale` preview reads as a warning
  rather than a failure. Two contrast defects are fixed: the Publication
  **Run publication plan** label inherited muted ink on the accent fill, and
  light-theme key-hint chips on primary buttons were white on near-white.
  `check-scales.mjs` now fails any absolute length in a type, spacing, or
  corner property of `styles.css`. No host endpoint or contract changed.
  Links: [the editor README](/editor/README.md#component-vocabulary-and-state-honesty),
  [issue #1044](https://github.com/drawmeanelephant/boris/issues/1044).

- Focus writing mode's Typography and Writing aids panels open as overlays
  under their summaries instead of expanding inside the header, so opening one
  no longer reflows the chrome or shrinks the writing surface. They stay native
  disclosures with their saved preferences, and act as one light-dismiss menu:
  opening one closes the other, a click outside closes it, and Esc closes the
  open panel (focus returns to its summary) before a second Esc exits focus
  mode. The panel sits on one new stacking step, `--layer-focus-popover`, in
  the editor's declared layer ladder. Links: [the editor
  guide](/editor/README.md#focus-writing-mode),
  [#1066](https://github.com/drawmeanelephant/boris/issues/1066).

- In the editor's Review density, Graph and Publication are top-level panes
  in the workspace rail (after Problems, Preview, and Watch) instead of
  sub-panes under the writing surface, so Source no longer grows into a tall
  column beside a short rail; the section nav now lists every destination in
  the order it appears on screen. The Project file actions take the compact
  size and pair up instead of stacking one per line. The section-nav
  scrollspy keeps the pane you jumped to marked current on Review's shorter
  page, follows rail scrolling after a switch from Author, and lands
  mode-switch jumps correctly under reduced motion. No host endpoint or
  contract changed. Links: [the editor README](/editor/README.md#density-modes-and-the-writing-surface),
  [issue #1067](https://github.com/drawmeanelephant/boris/issues/1067).

- Themes batch A (#1047, #1048): `reference`, `press`, `showcase`,
  `archive`, `journal`, `compact`, `minimal`, `corporate`, `service`, and
  `engineering` now wire `{{head}}` and labelled, search-excluded
  `{{relations}}`/`{{backlinks}}` on every layout, adopt `{{page-status}}`
  (a visible status label on `engineering`), `{{tags}}`, and `{{parent}}`
  where the theme's voice uses them, and record each intentional omission
  in the theme README. Each theme ships an `ACCESSIBILITY.md` with measured
  focus and text contrast; fixes include sub-3:1 focus rings (`press`,
  `service`, `engineering` header), dark-mode link and print palettes,
  missing focus/print/motion passes (`showcase`, `archive`), and a clean
  single-column CV print for `corporate`. See
  [the theme catalog](/themes/README.md) and
  [the slot contract](/docs/contracts/templating-and-themes.md).

- Twelve shipped themes (boris, field-notes, cards, cozy, ledger, reading,
  semantic, columns, civic, tokens, lab, html4-strict) now reach the
  accessibility floor and style every slot they emit. field-notes, cards, and
  cozy gain relations and backlinks. field-notes and ledger replace the flat
  metadata list with the status, parent, and tags hooks. cozy adds a draft
  stamp. Light-mode focus rings below 3:1 are fixed in five themes. ledger and
  html4-strict gain print styles, and html4-strict gains a skip link and
  `:focus-visible`. Each theme now ships `ACCESSIBILITY.md`, and its README
  lists the slots it leaves out and why. Links:
  [theme slot contract](/docs/contracts/templating-and-themes.md),
  [HTML 4.01 Strict profile](/docs/contracts/html4-strict.md),
  [#1047](https://github.com/drawmeanelephant/boris/issues/1047),
  [#1048](https://github.com/drawmeanelephant/boris/issues/1048).
- Eleven of those themes (all but html4-strict) keep layout text out of the
  rendered-search index. Relations and backlinks sit in a `graph-links`
  wrapper marked `data-boris-search-exclude`, as in the other ten themes.
  Children panels, kickers, sidebar headings, and layout title `h1`s are
  excluded too. A page's search entry now holds only its authored text.
  html4-strict cannot carry the attribute, so its README documents that its
  index includes navigation and relation link text. Link:
  [rendered-search contract](/docs/contracts/rendered-search.md).

- Visual quality pass for the docs-voice themes (#1049, part of #1045):
  [`reference`](/themes/reference/README.md), [`compact`](/themes/compact/README.md),
  [`semantic`](/themes/semantic/README.md), [`columns`](/themes/columns/README.md),
  [`service`](/themes/service/README.md), [`engineering`](/themes/engineering/README.md),
  [`civic`](/themes/civic/README.md), and [`tokens`](/themes/tokens/README.md)
  now style breadcrumbs, outlines, Details, definition lists, footnotes,
  figures, h4, and per-kind Aside colours in each theme's voice, and keep
  Markdown table alignment. These constructs previously fell back to browser
  defaults. Dark-mode links in `semantic`, `civic`, and `tokens` now pass
  contrast (they measured 2.4–3.6:1). The six themes whose layouts show
  `<h1>{{title}}</h1>` mark it with `data-boris-search-title`, so a page with
  no authored heading is indexed under its own title rather than the theme
  name ([rendered search](/docs/contracts/rendered-search.md)). They also
  drop `aria-label`s that sat on role-less wrapper `div`s. Measured contrast
  is in each theme's `ACCESSIBILITY.md`.

- Seven personal-voice themes (press, cozy, journal, ledger, field-notes,
  cards, reading) now style every authored construct in their own voice:
  all five Aside kinds are told apart, and Details, definition lists,
  footnotes, figures and captions, blockquotes, `hr`, `h4`, and Markdown
  table alignment no longer fall back to browser defaults. Images no longer
  overflow the column in journal, ledger, cards, and reading. Visited and
  current-page link states are styled to match each voice. Breadcrumbs in
  cozy, journal, and ledger are inline trails instead of numbered lists.
  journal and cozy no longer put the site name in an `h1`, so the page
  title is each page's only `h1`. cards keeps nested navigation below
  42rem. Children panels in press, cozy, ledger, field-notes, and cards
  hide when the page has no children. reading still adds no English of its
  own and keeps its `:lang(ja|zh|ko)` rules. Each theme's
  `ACCESSIBILITY.md` records the new contrast figures. Links:
  [theme catalog](/themes/README.md),
  [theme slot contract](/docs/contracts/templating-and-themes.md),
  [#1049](https://github.com/drawmeanelephant/boris/issues/1049).

- `boris init` starters use the named layouts that
  [#1050](https://github.com/drawmeanelephant/boris/issues/1050) added.
  The `cookbook` profile sends `id:index` to the `cards` theme's `home.html`,
  which shows each recipe as a card. The rule selects the `.cook` index
  like any other page. The `changelog` profile sends `id:changes` to the
  `journal` theme's `archive.html`, whose listing names the published
  releases and leaves out the draft. The `portfolio` index drops its
  hand-written project list, because the `showcase` home now lists the
  about page and the projects through `{{children}}`
  ([#1053](https://github.com/drawmeanelephant/boris/issues/1053)). Both new
  layout files are embedded too, so every starter theme again matches its
  catalog copy file for file
  ([#1046](https://github.com/drawmeanelephant/boris/issues/1046),
  [the CLI contract](/docs/contracts/cli.md#init-deterministic-starter-scaffold-with-self-verification),
  [theme matrix](/docs/init-theme-matrix.md)).

- `boris init` (the default `--type docs`) now writes the catalog
  [`boris`](/themes/boris/README.md) theme's full file set, as every other
  archetype writes its theme
  ([#1063](https://github.com/drawmeanelephant/boris/issues/1063),
  [#1046](https://github.com/drawmeanelephant/boris/issues/1046)). The
  private two-file starter theme it used to write had no `{{relations}}`,
  `{{backlinks}}`, `{{children}}`, or `{{metadata}}`, so the starter's index
  promised a semantic relation the theme could not show. It had also
  drifted from the catalog theme's fixes: slot adoption, the accessibility
  floor, the [#1049](https://github.com/drawmeanelephant/boris/issues/1049)
  visual pass, and the search-title marker. The relation now
  renders on both of its pages, the index lists its guides, and tags
  appear in the page header. Search works as before: the catalog layout
  ships the same browser search client. The cost is that `init --type
  docs` no longer writes the historical starter bytes, and the sidebar,
  `<title>` suffix, and footer say "Boris" until you edit the theme copy.
  See [the CLI contract](/docs/contracts/cli.md#init-deterministic-starter-scaffold-with-self-verification)
  and [the init theme matrix](/docs/init-theme-matrix.md).

- `boris init --type photo-gallery` embeds its five PNG plates straight from
  the [`examples/gallery-site`](/examples/gallery-site/) specimen through a
  new `init_example_assets` module instead of byte copies under
  `src/init_templates/`, so the starter and the example share one source of
  truth ([#1084](https://github.com/drawmeanelephant/boris/issues/1084)).

- The `cards` theme is now an index-card workbench with its own point of view:
  collections spread across the desk as numbered, tabbed, ruled card decks of
  real generated child links, a document becomes one pulled reading sheet, the
  page outline folds under a native "Find a line" disclosure, and the site
  graph lives in a native "Open the index" drawer instead of a sidebar and
  outline rail. Page metadata files itself below the prose as a record rather
  than a badge strip above the headline, and the theme ships a six-card
  "useful-things box" specimen in place of the shared calm-documentation copy.
  Presentation only — the layouts keep every existing slot, the content model
  and config schema are unchanged, and the published pages stay
  JavaScript-free. See [the Cards theme](/themes/cards/README.md) and the
  updated [theme matrix](/docs/init-theme-matrix.md).

- The `tokens` theme is now a token sheet for a design system with its own
  point of view: pages are spec sheets with hairline rules, field-table
  metadata, and a DRAFT stamp on `status: draft`; collections list children
  as a numbered register; the site graph folds into a mono catalog column;
  and the masthead and cover display the stylesheet's own tokens as live
  swatches, type steps, and space bars. Dark mode prints the same set as a
  blueprint. The theme ships a six-sheet "house set" specimen in its README
  in place of the shared calm-documentation copy, and `{{title}}` now names
  the document `<title>` instead of printing the static word "Tokens" on
  every tab. Presentation only — every existing slot is retained, the
  content model and config schema are unchanged, and the published pages
  stay JavaScript-free. See [the Tokens theme](/themes/tokens/README.md).

- `themes/field-notes` is now a bound expedition logbook — grid-paper
  leaves, punched binding, stamped entry headers, children filed as
  numbered route legs, and a logbook-index margin — instead of the shared
  documentation skeleton. Links: [theme README](/themes/field-notes/README.md),
  [init theme matrix](/docs/init-theme-matrix.md).

- `themes/columns` is now a broadsheet — nameplate masthead, edition
  line, credit-line metadata, a press stamp for page status, and article
  prose set in real justified columns — instead of the shared boxed-docs
  skeleton. Links: [theme README](/themes/columns/README.md).

- The `semantic` theme is now a landmark-first documentation theme with its own
  point of view: the page's structure is the surface. Every region names itself
  in a small monospace label — `header`, `main`, `article`, `section`, `nav`,
  `footer` — every heading carries its level in the left margin, and callouts,
  disclosure, tables, and definition lists are the platform elements styled in
  place. The banner drops the hero-card and badge skeleton; the home page becomes
  a contents page whose two-column deck is the graph's first level of real child
  links; the footer is a quiet colophon instead of self-narration. Light and dark
  palettes follow the operating system, `prefers-reduced-motion` pins the only
  motion the theme has, and print drops the labels and the rails. The decorative
  region and heading labels are CSS generated content given an empty accessible
  name, so a screen reader announces the real landmark or heading level and the
  label stays visual. Presentation only — the layouts keep every existing slot,
  the content model and config schema are unchanged, the published pages stay
  JavaScript-free and offline, and the layout authors no heading of its own so a
  page has exactly one `<h1>`, the one the content provides. The theme ships a
  small, complete specimen under `themes/semantic/specimen/` that demonstrates
  landmarks, heading hierarchy, and native components on its own content graph.
  See [the Semantic theme](/themes/semantic/README.md), its
  [accessibility notes](/themes/semantic/ACCESSIBILITY.md), and the updated
  [theme matrix](/docs/init-theme-matrix.md).

- The `html4-strict` compatibility theme is redesigned as **"the standard
  sheet"**: 1999 markup set like a Swiss design manual — a ruled margin rail
  with the site index and numbered page outline, one grotesque system stack,
  hairline structure rules, and a single poster red for links, markers, and
  the title full-stop. Same Strict DTD, same slot vocabulary, new
  presentation only; every assembled page still passes the whole-document
  `EHTML4STRICT` gate and the W3C HTML 4.01 Strict validator. See
  [the theme README](/themes/html4-strict/README.md) and
  [the recomputed accessibility notes](/themes/html4-strict/ACCESSIBILITY.md).

- The editor now carries reading order in type: one documented scale in
  `lib/tokens.css` (meta → body → sub-pane title → pane title → app title),
  a 1.55 prose line-height with a readable measure, and a shared pane header
  row so a title, its lede, and its actions stop competing at the same size.
  Pane titles rise above body copy, `h4` group labels become small-caps
  labels, field labels step below prose, the Problems result chip no longer
  squeezes its lede into a word-per-line column, and Focus writing mode scales
  its document headings with the chosen text size. Presentation only — no
  endpoint, contract, or pipeline change. Links:
  [editor README](/editor/README.md#reading-hierarchy-and-pane-headers),
  [issue #418](https://github.com/drawmeanelephant/boris/issues/418).
- The Project pane renders the project as an indented, collapsible directory
  tree derived from the host's flat path list, so a long project path stops
  breaking mid-token. A row shows its own path segment and indentation carries
  the rest; folder rows are named disclosure buttons with `aria-expanded` and a
  CSS-only caret, and the 200-file budget still counts files only. Each file row
  keeps its full project-relative path as its accessible name and tooltip, the
  filter still matches whole paths, collapsed folders persist and are validated
  on load, and opening a file expands the folders above it. The host's file list
  stays flat — the tree is derived presentation and holds no directory model of
  its own. Links: [editor README](/editor/README.md#project-file-tree),
  [issue #418](https://github.com/drawmeanelephant/boris/issues/418).
- The editor host API is now a normative contract, so the surface cannot drift:
  [editor-host.md](/docs/contracts/editor-host.md) pins the loopback
  transport/security discipline and launch line, the closed endpoint surface
  with its payloads and error taxonomy, author-owned file operations and
  fingerprint/atomic-save rules, the fixed Boris command allowlist and artifact
  version negotiation, both managed daemons (validation, watch) with their
  start/stop/backoff/reaping contract and dist-writer exclusion, and the
  preview origin. It also records the compiler-serve reconciliation as open
  work and names each black-box script that pins a section. Docs plus one type
  correction: the shell declared `hello_schema` as a string while the host has
  always sent a number.
- The editor host contract is now executable: new
  `editor/scripts/test-host-contract.sh` parses the endpoint table and error
  taxonomy out of [editor-host.md](/docs/contracts/editor-host.md), reconciles
  both against the host's own route table and error set in both directions,
  probes every documented endpoint for its exact method set, rejects generated
  near-miss and plausible-but-absent `/api/*` paths, and drives **every** code in
  the taxonomy to its documented status with a live request — a 50 000-file
  fixture, a directory where a page is expected, and four stub-compiler/host
  scenarios — so a documented code that no request can raise now fails the
  build instead of rotting as a "reserved" row. It also floods the watch event
  ring with two stub compilers to pin the §7.3 bounds: the 100-event cap
  (`gap`, `oldest_seq`, `dropped_lines`, and the rule that an unparseable line
  consumes no `seq`) and the ~4 MiB byte budget, where eviction is byte-driven
  rather than count-driven. The same sweep removed `corrupt_recovery`, which no
  handler could raise. It runs as a stage of
  `editor/scripts/test-editor-gate.sh`, so a route or code that drifts from the
  contract fails CI. The first run found a real defect the contract had
  documented but the host did not honor: `POST /api/commands/run` let runner
  errors escape, so an invalid command request or an unrecognized artifact
  version closed the connection with no response at all instead of the
  documented `400 invalid_command_request` / `502 unsupported_boris_artifact`.
  The handler now maps them like every other endpoint.
- Corrected two stale claims in the editor README: the watch-admin section
  still called the editor's watch UI a non-goal, and M5 still justified the
  host's preview origin with a compiler serve mode not existing — that shipped
  as `boris watch --serve` ([CLI contract](/docs/contracts/cli.md)). M5 now
  records the overlap and the reconciliation as open work instead of a settled
  rationale. Docs only.

- `boris-content-audit` graduated to its own repository
  ([`drawmeanelephant/boris-content-audit`](https://github.com/drawmeanelephant/boris-content-audit),
  tagged `v0.8.2`, issue [#834](https://github.com/drawmeanelephant/boris/issues/834)).
  The tool tree left with its history (21 commits, moved via
  `git filter-repo`), and this repo dropped its one-shot gate, its
  `content-audit` / `test-content-audit` build steps, and its
  `content-audit-test` CI lane plus the strict aggregate requirement on it.
  The tool keeps its own build, tests, and unconditional both-OS CI lane, and
  pins the closed frontmatter and identity grammar by Boris release tag.
  Links: [the tools registry](/docs/tools-registry.md),
  [the split plan](/docs/plans/content-audit-standalone-repo.md).

- The Boris Editor's accessibility contract is certified **keyboard-first**
  against the CI accessibility tree, and spoken OS voice control (macOS Voice
  Control / Windows Voice Access) is descoped from v1 — sub-issue
  [#677](https://github.com/drawmeanelephant/boris/issues/677) closes as not
  planned. Every [#418](https://github.com/drawmeanelephant/boris/issues/418)
  workflow already completes by keyboard with stable accessible names and no
  workflow was voice-only, so no shipped capability is removed. Links:
  [the posture](/editor/README.md#accessibility-posture),
  [the certification](/editor/accessibility-certification.md).

- Bumped the [GitHub Pages target](/docs/contracts/publication-platforms.md) workflow's `configure-pages`, `upload-pages-artifact`, `upload-artifact`, `download-artifact`, and `deploy-pages` pins to their current Node 24 releases, clearing the runner's Node 20 deprecation annotations (#962). `mlugg/setup-zig` remains on its latest upstream release, which still declares Node 20.

- Bumped the CI workflow's `actions/checkout`, `actions/setup-node`, `actions/upload-artifact`, and `dorny/paths-filter` to their current Node 24 releases and pinned every action in [the CI workflow](/.github/workflows/ci.yml) by commit SHA, clearing the runner's Node 20 deprecation annotations (#963). `mlugg/setup-zig` stays pinned at its latest upstream v2.2.1, which still declares Node 20.

- Repointed the CI and [GitHub Pages](/.github/workflows/github-pages.yml) workflows from `mlugg/setup-zig` to [`drawmeanelephant/setup-zig`](https://github.com/drawmeanelephant/setup-zig), a v2.2.1 fork whose only change is `runs.using: node20` → `node24`, clearing the last Node 20 deprecation notice after upstream moved to Codeberg (#964).

- The editor's everyday surface now reads as a writing tool first: a default **Author** density mode (Source + Project; review panes unmounted, authoring hints folded, and section-nav links to Review panes switching modes before they land) beside the full **Review** chrome, Source as a measured hero surface with a measured line gutter, current-line band, and presentation-only frontmatter seam, and a primary/secondary action hierarchy in Problems with per-command `aria-busy` progress and large reports collapsed behind an explicit disclosure; a mode-gated landing that clamps at max scroll keeps its active nav marker while it covers the reading line. Links: [the editor guide](/content/guides/editor.md#density-modes-and-the-writing-surface), [#988](https://github.com/drawmeanelephant/boris/issues/988), [#989](https://github.com/drawmeanelephant/boris/issues/989), [#990](https://github.com/drawmeanelephant/boris/issues/990), [#991](https://github.com/drawmeanelephant/boris/issues/991).

- Author mode stops reading as an equal-card dashboard: Project is demoted to a
  file drawer under the writing page (no shared height, elevation, or heavy
  edge) instead of a peer card, the section nav leads with Project and Source
  while the Review destinations recede into a captioned, faint cluster that
  still switches modes and lands on activation, and Source takes page material
  rather than a wider dashboard tile — no card elevation, a focus-within edge,
  and a readable-measure cap centered in its column on wide windows, so the
  pane edge is the page edge and heading, editor, gutter, and status line share
  one column. The top band quiets too: the header drops its decorative eyebrow
  so the product mark and the live connection status share one row, the
  connection readout collapses to a compact state chip whose honest sentence is
  one activation away (the live region announces the short label rather than
  re-reading a sentence), the theme control states only its state, and Author
  takes a smaller product mark and tighter header/nav bands than Review. Links:
  [the editor
  guide](/content/guides/editor.md#density-modes-and-the-writing-surface),
  [#993](https://github.com/drawmeanelephant/boris/issues/993).


- Removed the contract-claim registry gate added in [#997](https://github.com/drawmeanelephant/boris/pull/997), and forbade standing up a replacement. Quoted-tether records and the `--audit` worklist were extra process on top of existing unit, CLI, and release-gate checks; they made `zig build test` slower without changing compiler behavior. [`AGENTS.md`](/AGENTS.md) now treats parallel verification products (claim registries, quote-tethers, contract-audit worklists, `known-divergence` ratchets) as needing an explicit user request; a contract the code does not honor is a defect to fix or rewrite, not a new gate. The Cooklang `{`-adjacency defect stays open. Links: [the test harness](/test/README.md), [the agent playbook](/docs/AGENT-PLAYBOOK.md), [#907](https://github.com/drawmeanelephant/boris/issues/907).

### Fixed

- Fixed Cooklang name termination at the Boris seam: a `{` later in the line no
  longer swallows prose into the ingredient name, so
  `Add @salt into the {bowl} and stir.` yields ingredient `salt` with no
  quantity and keeps `{bowl}` in the prose — enforcing the adjacency rule in
  the [Cooklang compatibility contract](/docs/contracts/cooklang-compatibility.md)
  via the repinned Oliver parser ([Oliver renderer pin](/docs/contracts/oliver-renderer.md),
  #907).

- Rendered search now omits compiler metadata chrome, keeps authored definition
  list terms and values separate, and covers both cases in the contract fixture.
  Links: [rendered-search contract](/docs/contracts/rendered-search.md),
  [#1005](https://github.com/drawmeanelephant/boris/issues/1005).

- HTML `build --profile` now refuses profile target or edition settings that its CLI configuration does not select, instead of silently compiling a mismatched default site; matching Standard.site and Nostr metadata opt-ins still work. See [the publication-profile contract](/docs/contracts/publication-profile.md) (Refs #1006; full profile execution remains deferred).

- Complete the editor document head with a deep-green SVG favicon, a browser
  chrome color that follows the active light/dark surface, and a JavaScript-
  disabled fallback. Links: [the Boris Editor](/editor/README.md),
  [#1010](https://github.com/drawmeanelephant/boris/issues/1010).

- Reserve concurrent execution for WebSocket deadline races so worker-pool saturation cannot run a blocking operation or timer inline. Keep the full loopback write-fuzz coverage and checked allocation while avoiding per-frame allocator stack unwinding. CI prints test commands and timing summaries without raising its timeout. See [the transport evidence](/docs/contracts/nostr-publication.md#conformance-matrix).

- Require AUTH transmission before its matching positive OK can open the NIP-42 article gate; keep retired signer replies relay-local, preserve large article delivery after replacement authentication, and retain replacement rejection/Close outcomes and diagnostics. Six offline recording-relay regressions cover the fixes without changing the approved opt-in boundary or ordinary schema-1 behavior. See [the Nostr acceptance evidence](/docs/contracts/nostr-publication.md#phase-2-implementation-notes-and-release-evidence-boundary).

- Windows builds and runs natively: `zig build` installs a `boris` POSIX
  launcher shim beside `boris.exe`, threaded-I/O file opens and readers
  follow Windows async semantics, the preview server shuts down without
  an overlapped-accept panic, and test scripts account for Windows
  signal, jq-CRLF, and symlink behaviors. `zig build test` is green on
  Windows Server 2022 (208 steps, 16518 tests). See
  [the PR](https://github.com/drawmeanelephant/boris/pull/1019).

- Frontmatter-sourced graph diagnostics now point at the offending field line
  instead of `1:1`: `EPARENTMISSING`, `EPARENTSELF`, and each `EPARENTCYCLE`
  participant report the page's `parent:` line, and `ERELATIONMISSING`,
  `ERELATIONSELF`, and `ERELATIONDUPLICATE` report the `relations:` line.
  Diagnostic `remediation` now carries a concrete action at every emit site
  where one exists (including parser failures, which previously fell back to a
  generic hint), and machine-readable reports no longer contain the circular
  "See the stderr diagnostic" pointer — see the
  [diagnostics contract](/docs/contracts/diagnostics.md) (#1021).

- The [GitHub Pages target](/docs/contracts/publication-platforms.md)
  workflow installs Zig **0.17.0** in both the build job and the optional
  deployment-observer job, matching `minimum_zig_version` and the `ci.yml`
  pins. The `0.16.0` pins left over from before the 0.17 toolchain migration
  (#1026) failed every push-to-`main` run at `zig build`, leaving the live
  Pages site undeployed since 2026-10-07 (#1033).

- Gated the shipped search UI's `h1` section-score bias on an actual term
  match in all three themes (`boris`, `lab`, `corporate` under
  [themes/](/themes/)) and the `boris init` starter layout
  (`src/init_templates/layouts/main.html`, since retired by #1063): a non-empty query that
  matches no term now reports "No results." instead of returning every document
  with an `h1` ([#1037](https://github.com/drawmeanelephant/boris/issues/1037)).
  Consumer rules: [rendered-search](/docs/contracts/rendered-search.md).

- `boris build`, `boris watch`, and `boris init` no longer hang at the end of
  compile on Windows: the [publication-claims](/docs/contracts/publication-claims.md)
  evidence chain now reads each committed report once and replays the collected
  bytes to the parser from memory, removing the rewind-and-reread pass that
  never completed on asynchronous no-follow file handles under Zig 0.17
  ([#1032](https://github.com/drawmeanelephant/boris/issues/1032)). The
  transient buffer is bounded at 64 MiB per report; a larger committed report
  is rejected as malformed rather than allocated.

- Target-declaration failures (`TargetOutputSymlink`, `TargetOutputCollision`, `WorkspaceEscape`, and siblings) raised before per-target compilation begins now emit the same locus diagnostic the per-target wrapper reports — `sourcePath` names the offending output and remediation is targeted — instead of a generic `sourcePath: null` entry with "check the command line". `watch --watch-json` stays exclusively NDJSON through a failing initial build: one `build-failed` record, exit 2, no trailing prose. A wrong-typed container inside `targets[].head` (`"defaults": []`, `"pages": {}`, `"values": []`, `"image": []`) names the field in the object that holds it instead of fabricating a nested path segment. See [the watch-mode contract](/docs/contracts/watch-mode.md) and [the publication-profile contract](/docs/contracts/publication-profile.md) (Fixes #1035, #1036, #1038).

- Malformed publication profiles now name the offending key or field and its object path — including paths inside `targets[].head` — for example `unknown key "bogus" in targets[0].head.pages[0].values`, `duplicate key "format"`, or `missing required field "id" in targets[0].head.pages[0]`, instead of printing a bare error enumeration. Duplicate keys are compared after JSON escape decoding, so `"name"` and `"na\u006de"` collide. Semantic rejections with no JSON-shape fault still report the bare error name. See [the publication-profile contract](/docs/contracts/publication-profile.md) (Fixes #1038).

- `build`/`validate --sitemap` with a `--site-url` that disagrees with the declared Pages publication location now emits an `EPUBLICATIONLOCATION` diagnostic naming both URLs instead of failing silently with a generic `EIO` report entry, and `watch` no longer labels the failure an unrecoverable I/O error. See [the diagnostics contract](/docs/contracts/diagnostics.md) (Fixes #1035).

- Static-directory, sitemap-path, RSS feed-path, and target-output usage failures (`StaticSymlink`, `StaticDirMissing`, `SitemapOutputCollision`, `RssOutputCollision`, `TargetOutputSymlink`, and siblings) now keep their specific error and report `EUSAGE` diagnostics naming the offending path, instead of collapsing into `LayoutSelectionFailed` with `ELAYOUT` diagnostics and the layout path. RSS feed collisions report their own `InvalidRssPath`/`RssOutputCollision` names and blame `rss.path`, not a sitemap the target may not declare. See [the diagnostics contract](/docs/contracts/diagnostics.md) (Fixes #1036).

- Publication-profile parsing no longer reports an allocation failure during
  the initial JSON parse as malformed input — the run now exits 3 (the
  system-error class) instead of the exit-2 usage class — and the `head`
  declaration grammar rejects the wrong-type values `std.json` used to
  coerce: numeric and numeric-string enum values (`type: 0`, `type: "0"`) and
  byte-array strings (`title: [116,105,116]`) now fail with a diagnostic that
  names the field, per the
  [head metadata contract](/docs/contracts/head-metadata.md).
- Allocation failures deeper in the profile parse keep their OutOfMemory
  identity and memory safety: Standard.site location normalization no longer
  degrades OOM to `InvalidLocation`/`InvalidPublication`, the `input` /
  `html_output` string overrides no longer free the replaced value before its
  successor exists (a double free on allocation failure), and partially built
  `standard-site` publication configs and `layout_rules` entries release their
  intermediate strings instead of leaking them.

- Focus writing mode's Typography and Writing aids panels now close when
  keyboard focus leaves them — Tab past the last control or Shift+Tab before
  the summary dismisses the open panel and lets focus keep moving to the next
  control, instead of leaving the panel hanging over the writing surface.
  Links: [the editor guide](/editor/README.md#focus-writing-mode),
  [#1076](https://github.com/drawmeanelephant/boris/issues/1076).

- Editor: `--section-nav-h` now tracks the section nav's live height — a
  `ResizeObserver` on the band plus a re-measure before a mode-gated jump —
  so a pane landed after an Author → Review density switch parks below the
  nav instead of too tight under the stale margin (#1078). Links:
  [SectionNav.svelte](/editor/ui/src/components/SectionNav.svelte),
  [section-nav.spec.ts](/editor/ui/tests/section-nav.spec.ts).

- Editor: Graph and Publication group labels no longer skip a heading level —
  the `.group-label` role renders as `h3` under a pane title and `h4` under a
  sub-pane title, so screen-reader heading navigation reads `h2 → h3 → h4`
  with no gap. Links: [editor reading hierarchy](/editor/README.md),
  [issue #1077](https://github.com/drawmeanelephant/boris/issues/1077).

- The editor preview can no longer stick on `running`: a Boris process that
  exits `0` without producing `dist/index.html` now lands the preview on
  `failed` with a message naming the missing output, and the shell re-reads
  `/api/preview/state` after any refused or failed rebuild response so the
  Rebuild preview action stays usable. Links:
  [the editor host contract](/docs/contracts/editor-host.md),
  [#1073](https://github.com/drawmeanelephant/boris/issues/1073).

- [Rendered search](/docs/contracts/rendered-search.md) no longer fabricates a
  slug `fragment` for a heading without an `id` (the empty fragment links the
  page), so layout `<h1>{{title}}</h1>` headings stop failing the
  `rendered-search` publication check with `SEARCH_CONTENT_MISMATCH`. It also
  reaches the `<title>` fallback on doctype-led pages, lets a search-excluded
  layout heading marked `data-boris-search-title` supply the document title,
  and keeps compiler-emitted `{{relations}}`/`{{backlinks}}` and the HTML 4.01
  Strict nav, breadcrumb, TOC, and children wrappers out of the index
  (#1045, #1047, #1048).

- Themes visual pass, product batch (#1049): `boris`, `showcase`,
  `archive`, `lab`, `html4-strict`, `corporate`, `minimal`, and `gallery`
  now style every authored construct (all five Aside kinds with measured
  kind colours, Details, aligned tables, nested and definition lists,
  footnotes, code, blockquotes, figures, h1–h4, children). Fixes include
  table column alignment overridden by `text-align` in `boris`, `showcase`,
  `lab`, and `gallery`, Aside
  titles that `corporate` and `minimal` never matched (`admonition__title`),
  images and code overflowing at 390px in `showcase` and `archive`, `lab`
  printing near-white headings from its dark and pride modes, `archive`
  showing an empty "More entries" panel, and the `archive` index taking the
  theme name as its search title (its layout `<h1>` now carries
  `data-boris-search-title`). The `corporate` CV print is unchanged. See
  [the theme catalog](/themes/README.md) and
  [the rendered-search contract](/docs/contracts/rendered-search.md).

- Catalog themes no longer carry demo-site copy into `boris init --type`
  starters, which copy each theme byte for byte (#1045, #1046). A fresh
  `archive` site no longer shows "Personal index · 2018—2024" and a fixed
  lede over its own title, and the `dashboard` board no longer says "Theme
  study". Fake site names, an owner bio, a `©` line, and theme pitches are
  gone from [`cozy`](/themes/cozy/README.md),
  [`press`](/themes/press/README.md), [`showcase`](/themes/showcase/README.md),
  [`reference`](/themes/reference/README.md),
  [`journal`](/themes/journal/README.md), and six other themes. Each theme
  shows its own name or a neutral label instead, within the closed slot
  vocabulary ([templating and themes](/docs/contracts/templating-and-themes.md)).
  Theme READMEs now link repository-only targets by absolute GitHub URL,
  so the copies inside a starter no longer have dead `../../examples/` links.

- `zig build test` no longer flakes under machine load: the Nostr publication
  matrix and auth-IPC tests stopped asserting on wall-clock timing. Plans that
  expect a non-timeout outcome now carry a deadline scheduler starvation cannot
  beat, stall scenarios drive a test-only clock instead of racing `sleep`, and
  promptness checks compare cross-thread event ordering rather than elapsed
  milliseconds. Product deadlines are unchanged. Links:
  [nostr publication contract](/docs/contracts/nostr-publication.md),
  [issue](https://github.com/drawmeanelephant/boris/issues/1075).

- `boris init` now claims its target with an exclusive-create `.boris-init.lock` marker before the emptiness check, so two concurrent `init` runs on the same directory can no longer both materialize — or have one's failure cleanup delete the other's half-written tree. See [the CLI contract](/docs/contracts/cli.md) (Fixes #1099).

- Editor host now compiles and runs its full test suite on Windows (Zig 0.17.0
  std shims for file permissions and wait4 status), and the Preview pane's
  rebuild honors a project's `boris.json` publication profile instead of
  assuming the default theme, so profiled projects preview correctly.
  Links: [editor host contract](/docs/contracts/editor-host.md).

- A page file whose name violates the identity rules no longer bricks the build with a bare `InvalidPath`: discovery carries the offending walk path to the diagnostic boundary, so the build fails with a located `EINVALIDPATH` (e.g. `content/my page.md: not a valid page path`) and a rename remediation naming the actual file. Links: [the identity-and-paths contract](/docs/contracts/identity-and-paths.md), [#851](https://github.com/drawmeanelephant/boris/issues/851).

- Frontmatter's closing `---` must be a complete (newline-terminated) line, matching the opening-fence rule and the contract wording: a file whose last line is `---` with no trailing newline now fails closed with `EFRONTMATTER` ("unclosed frontmatter") instead of being silently accepted with an empty body — ending the asymmetry where `---<EOF>` closed but `---\r<EOF>` did not. Links: [the frontmatter contract](/docs/contracts/frontmatter.md), [#852](https://github.com/drawmeanelephant/boris/issues/852).

- Entity ids may no longer end with a page extension (`.md`, `.mdx`, `.textile`, `.cook`): such an id could byte-equal another page's `sourcePath`, conflating the incremental cache keys and silently missing rebuilds. `id:`/`parent:` frontmatter values, wiki-link targets, and every other id surface now reject the shape fail-loud with a located `EINVALIDPATH` (frontmatter) or `EREFERENCESYNTAX` (wiki link). Links: [the identity-and-paths contract](/docs/contracts/identity-and-paths.md), [#854](https://github.com/drawmeanelephant/boris/issues/854).

- A footnote definition no longer disappears when an `<Aside>`/`<Details>` component sits between it and its reference: before rendering, definitions that a component split from their referencing segment are relocated (moved, never duplicated) to the first segment that references them, so the published page renders the `footnote-ref` link and the footnotes section instead of literal `[^1]` prose and silently dropped definitions. Unreferenced definitions stay where the author put them; scanning is fence- and inline-code-aware. Links: [the Oliver renderer contract](/docs/contracts/oliver-renderer.md), [#860](https://github.com/drawmeanelephant/boris/issues/860).

- Theme and content-local asset walks reject a file whose name contains a literal backslash with a located `EASSET` diagnostic naming the actual file (e.g. `theme/assets/css/weird\name.css`), instead of normalizing the name into a nested path and failing later with a bare `FileNotFound` for a file that visibly exists. POSIX-only edge; the normal-name control keeps building. Links: [the templating-and-themes contract](/docs/contracts/templating-and-themes.md), [#870](https://github.com/drawmeanelephant/boris/issues/870).

- Single-cause conflicting-options rejections now name both tokens as typed per the #764 rule: `boris plan --profile p.json --timings` reports `plan conflicts with --timings`, `validate`/`check`/`impact --profile` name the mode (`validate conflicts with --profile`), and flag×flag pairs name both flags (`--watch conflicts with --profile`) instead of the generic `conflicting options (try --help)`. Multi-cause argv keeps the generic form; exit code 2 is unchanged. Links: [the CLI contract](/docs/contracts/cli.md), [#874](https://github.com/drawmeanelephant/boris/issues/874).

- `llms.txt` descriptions no longer describe decoration: a CommonMark thematic break (`---`, `***`, `___`, space-separated forms) after the heading is skipped instead of becoming the page's exported description, and a break closes an already-started paragraph. Links: [the llms.txt contract](/docs/contracts/llms-txt.md), [#879](https://github.com/drawmeanelephant/boris/issues/879).
- The focused rendered-search gate (`zig build --build-file tools/search-index/build.zig test`) no longer prints a `failed command` block on green runs: `parse` is now side-effect-free (the usage text is printed by the CLI runner, not the parser), so the `--help` unit test no longer writes to stderr, which the Zig 0.16 build runner reports as a step failure even when every test passes. CLI behavior is unchanged. Links: [the rendered-search contract](/docs/contracts/rendered-search.md), [#882](https://github.com/drawmeanelephant/boris/issues/882).
- Wiki-link targets accept UTF-8 entity ids: `[[guides/café]]` now scans and rewrites like any other reference instead of failing with `EREFERENCESYNTAX`, while `identity.validateEntityId` still rejects malformed UTF-8, whitespace, and URL-significant bytes fail-loud. The wiki heading-fragments fixture gains a UTF-8 entity-id case and the release gate asserts its rendered href. Links: [the includes-and-wiki-links contract](/docs/contracts/includes-and-wiki-links.md), [the identity-and-paths contract](/docs/contracts/identity-and-paths.md), [#883](https://github.com/drawmeanelephant/boris/issues/883).

- The publication Proof Pack schema now accepts its own builds: `publication-proof-pack-1.schema.json` adds `static-file` to the artifact-kind enum, so a `--static-dir` target's `_boris/proof/proof-pack.json` no longer fails the published schema it is bound to (the schema already required the `static-file` key in `summary.artifacts.by_kind`). A runtime-vs-schema parity test now pins the Proof Pack vocabularies to the emitter, mirroring the artifacts, checks, claims, and touches evidence modules. Links: [the Proof Pack contract](/docs/contracts/publication-proof-pack.md), [#884](https://github.com/drawmeanelephant/boris/issues/884).

- `boris plan` output now validates against its own published schema when the profile configures a Nostr surface: `publication-plan-1.schema.json` gains the closed conditional `nostr` object (emitted after `editions`, exactly the shape the renderer emits), and the [publication plan](/docs/contracts/publication-plan.md) and [publication profile](/docs/contracts/publication-profile.md) contracts document the ninth root field, its emitted position, and the offline-boundary transport-declaration exception, ending the three-way disagreement with [nostr-publication.md](/docs/contracts/nostr-publication.md) (#885). A new golden fixture (`fixtures/publication-plan/nostr/`) pins the emitted bytes and a schema-conformance test covers the nostr-bearing plan.

- The [publication checks contract](/docs/contracts/publication-checks.md) now states the rendered-search evidence truthfully: the declared supporting scope (and its `supporting_sha256` digest, and the Touch Atlas `artifact-supports-check` edges) covers every committed `html-page` record — the selector vocabulary has no advertised dimension — while the search-document inspection set excludes unadvertised `status: draft` pages per #752. Contract prose only; emitted evidence was already self-consistent (#886).

- Refreshed the [publication-touches](/docs/audits/publication-touches/README.md) and [publication-proof-pack](/docs/audits/publication-proof-pack/README.md) audit examples and READMEs to shipped behavior: the "not yet shipped" status lines are replaced with the shipped story, all three proof-pack examples gain the schema-required `static-file: 0` counter, and the supporting-scope edges, `supporting_artifact_ids` rows, relationship counts, and README tables now model the shipped selector semantics (every committed artifact supports `rendered-html`; committed `html-page` records support `rendered-search`). All six examples validate against their published schemas and the HTML↔JSON parity check passes (#887).

- Standard.site profile `name`/`description` now honor the contract's 5000/30000-byte bounds instead of the shared 1024-byte site bound, so contract-legal publication records are configurable; the plan schema's `maxLength` pins moved with them and the JSON transport ceiling was raised above the largest semantic string (#895). Links: [the Standard.site contract](/docs/contracts/standard-site.md).
- The Standard.site exclusion reason vocabulary is pinned to the rendered hyphenated wire form `missing-date` in the contract and in a byte-level plan-render test, ending the `missing_date`/`missing-date` spelling disagreement (#896). Links: [the Standard.site contract](/docs/contracts/standard-site.md).
- Standard.site `include`/`exclude` filters now reject mid-glob patterns (`guides/*/x`, `a**`) at profile parse with `InvalidPublication` instead of silently giving them exact-match semantics; the closed filter grammar (exact entity id or trailing-`*` prefix) is documented in the contract (#899). Links: [the Standard.site contract](/docs/contracts/standard-site.md).
- The profile parser's Standard.site branch now has parser-level tests: valid-shape normalization, invalid `did`, invalid `pds` origin (path/query/userinfo/port/plain-HTTP), name/description bounds, mid-glob filter rejection, and the unknown-target fallback — plus a fix for the invalid-`pds` error path that leaked the dup'd origin string (#900).

- Wasm and host embeds now report a missing or broken layout the way the native compiler does: the HTML phase maps the failure into a structured `ELAYOUT`-class diagnostic, and a content-class HTML fault completes the compile with status 1 plus diagnostics instead of the opaque "unexpected compile error" ABI code `-4`. A closed fault set keeps embed misuse and system failures on the ABI-error path, and the fix also removes a double-deinit on the embed error path that could corrupt memory after cleanup (#909). Links: [the embedding contract](/docs/contracts/embedding.md).
- The container-runner contract no longer claims `theme/`, `layouts/`, or a publication profile in the job archive are visible to the compiler: in `boris-job-1` only `content/` reaches the build (the fixed argv names no theme/layout/profile flag), content-local `content/themes/...` trees are the way to ship managed theme assets, and the default layout resolves against the runner process cwd as the official image already documents (#910). Links: [the container-runner contract](/docs/contracts/cloudflare-container-runner.md).

- `boris-job-runner` accepts standard ustar archives containing directory members: trailing-slash names (`content/`) are validated as the directory path instead of rejected as `archive` ([container-runner contract](/docs/contracts/cloudflare-container-runner.md), #908).

- Fence-aware scanners honor CommonMark-indented (`≤3`-space) fenced code blocks: wiki-links (#858), include directives (#859), and content-local images (#869) inside indented fences — including unterminated fences — stay literal instead of failing the build or corrupting published code samples. The image scanner additionally leaves top-level 4-space indented code blocks literal while still validating list-nested images ([includes-and-wiki-links](/docs/contracts/includes-and-wiki-links.md), [content-local-assets](/docs/contracts/content-local-assets.md)).

- Full rebuilds no longer delete declared `--static-dir` `.html` passthrough files: the stale-output walker now skips currently-declared static paths (stale entries are still scrubbed), so declared embeds survive and `artifact-integrity` passes ([html-output](/docs/contracts/html-output.md), #866).

- `boris watch` survives transient filesystem hiccups: a root scan failure keeps the previous snapshot and emits no events instead of firing a mass-delete rebuild storm that kills the watcher (#876).
- `boris watch --timings` now records phase/counter data for initial and rebuild compiles, so the shutdown report carries real measurements instead of an all-zero artifact ([watch-mode](/docs/contracts/watch-mode.md), #877).

- CLI usage diagnostics name the offending option instead of misattributing it: duplicate `--layout-rule` selectors blame `--layout-rule` (#867), bad `--site-url` values blame `--site-url` (#880), `--site-url` without `--rss`/`--sitemap` and `--out` with `nostr plan` name their conflict pairs (#905). Session-family flags (`--did`, `--prune`, `--dist`, …) are now rejected outside `standard-site` instead of silently ignored (#872). The `--help` conflict list documents the new pairs ([cli](/docs/contracts/cli.md)).

- Documentation links rewrite inside compact (blank-line-free) `<Aside>`/`<Details>` bodies instead of failing the link audit: component tags no longer open the raw-HTML-block skip (#861). A stray unmatched backtick no longer suppresses link rewriting for the rest of the page (#862).
- Published-path collisions emit a located `EASSET` diagnostic naming the shared output path and the colliding page/entity instead of a bare `AssetCollision` ([content-local-assets](/docs/contracts/content-local-assets.md), #868).

- Standard.site omitted-status pages are now pinned as eligible in the contract (mirroring RSS), and the unreachable `unsupported` exclusion reason is removed from the contract, code, and wire vocabulary, ending the plan-vs-contract drift (#892). Links: [the Standard.site contract](/docs/contracts/standard-site.md).

- `boris nostr plan` now fails closed (`ENOSTRMARKDOWN`, `relative-url`) on an ordinary authored relative link or image destination in the publication-safe Markdown view, not only on the four Boris-mediated classes; every link and image destination must be scheme- or origin-qualified. Links: [Nostr publication contract](/docs/contracts/nostr-publication.md), [#893](https://github.com/drawmeanelephant/boris/issues/893).

- A disabled `nostr` profile section no longer requires `pubkey`, `articles`, or `relays`: those are requirements of an *enabled* section per the contract, so a staged-but-disabled surface may be `{"enabled": false}` alone. Supplied values are still validated and fail closed. Links: [Nostr publication contract](/docs/contracts/nostr-publication.md), [#894](https://github.com/drawmeanelephant/boris/issues/894).

- The `pr-issue-close` lint now models GitHub's reference rules exactly, closing
  two ways a PR body could look correctly linked while landing nothing. `Refs #N`
  / `Related to #N` is accepted as a declared keep-open intent — the check
  reports the issue to the reviewer and GitHub never auto-closes it, so a parent
  or umbrella issue can be named without being force-closed by a merge — while a
  bare `#N` mention still fails for declaring neither intent. And a declaration
  written inside backticks or a fenced block now fails as INERT instead of being
  stripped away as if it were not there: GitHub does not linkify those regions,
  so an inert `Closes #N` closes nothing while reading exactly like a working
  one. This is the failure that orphaned issue #834 on 2026-09-11. The grammar
  self-test grew from 29 to 50 cases. Links:
  [the lint](/scripts/check-pr-issue-close.sh),
  [the PR template](/.github/PULL_REQUEST_TEMPLATE.md).

- The section nav's scrollspy no longer hands `aria-current` to the wrong pane
  when the panes are laid out in columns that disagree with nav order. Currency
  went to the last qualifying section in nav order, so a jump to Graph settled
  on Preview — a pane parked off the top of the rail and clipped — and the
  reading line sat a nav height *below* where a jump actually parks a pane,
  which let a neighbouring pane score as nearer the line at some widths. It now
  takes the qualifying section nearest the line, measured at that pane's own
  scroll-margin-top, and the pane a jump just landed on wins a tie against one
  sharing its offset in another column. The e2e suite pins the resulting
  contract across the desktop three-column, narrow two-column, and mobile
  single-column layouts, so a pane that reintroduces the order-versus-layout
  divergence fails loudly instead of silently mislabelling the active pane.
  Links:
  [the component](/editor/ui/src/components/SectionNav.svelte),
  [the spec](/editor/ui/tests/section-nav.spec.ts).

- Corrected nine stale `blob/afterparty/...` links to `blob/main/...` across author-facing surfaces — the [publishing](/content/guides/publishing.md), [Nostr publication](/content/guides/nostr-publication.md), [Cooklang](/content/guides/cooklang.md), and [overview](/content/guides/overview.md) guides, the [homepage](/content/index.md), the [commands reference](/content/reference/commands.md), and the `boris init` starter text — so a reader who follows a contract link lands on current normative text instead of a frozen staging branch that predates those contracts' own current state. The [STATUS pointer table](/docs/STATUS.md) now cites open roadmap issues (#454, #840, #907) instead of four closed ones.

- Editor dialogs keep shortcut chips visible without gluing them into accessible names (`CancelEsc`), completion suggestions name value and detail separately, Create/Rename failures stay inside the dialog as human sentences, Graph is reachable with no file open, conflict compare panes reset to the top, `/api/version` emits schema versions as `[1]` instead of a raw `0x01` byte, and a successful create/rename/delete still updates the Project file list when the follow-up `GET /api/files` fails. Links: [the editor-host contract](/docs/contracts/editor-host.md), [the editor guide](/content/guides/editor.md).

- Editor graph map opens at a readable zoom (50% floor) centered on the active
  page while Fit still shows the whole graph; typing coalesces into one undo
  step per phrase; a cold launch restores the last author-owned file from the
  disposable state root (or `content/index.md`); and an existing `dist/` tree
  is framed as stale instead of an empty idle preview. Links: [the editor-host
  contract](/docs/contracts/editor-host.md), [the editor
  guide](/content/guides/editor.md).

- Review corrections to the Author surface above. The Author app title step is
  its own link in the type chain (`--text-2xl-compact`) rather than the
  pane-title size, which had made `h1` exactly as large as the pane titles it
  outranks. The theme control drops `aria-pressed`: a pressed state presumes a
  name that does not change with it, and here the changing label *is* the
  state. The Author Source textarea keeps no focus ring of its own now that the
  shell owns one, so the page shows a single edge instead of a frame within a
  frame. The connection readout's live region is text-only, matching every other
  status region in the editor, with the disclosure chip as a sibling rather than
  a button nested inside an atomic region.


- `boris --help` no longer prints a stray backslash on the `recipe-scale` mode
  line — a doubled multiline marker that shipped because nothing read the help
  text, which is now a named constant with a test over its shape — and the
  interactive CLI reference documents the three shipped commands it was missing
  (`graph`, `proof verify`, and `init`) instead of describing a
  six-command surface. Links: [the command
  reference](/content/reference/commands.md), [the CLI
  contract](/docs/contracts/cli.md).

- The required CI aggregate now depends on the `changes` path-filter job and
  fails when it fails, so a broken change-detection step can no longer wave the
  skipped conditional lanes through as green; PR body edits (`edited`) rerun
  the workflow so the issue-close lint revalidates the current body; and the
  optional GitHub Pages audit summary reports the actual `deploy-pages` step
  outcome instead of an unconditional success line after a failed deployment
  ([the CI workflow](/.github/workflows/ci.yml), [the Pages
  workflow](/.github/workflows/github-pages.yml)).

- Editor: Create and Rename dialogs no longer fail silently on an empty
  path — the submit action is natively disabled while the trimmed path is
  empty, so the muted state is visible and the browser refuses implicit Enter
  submission while the only submitter is disabled.
  Links: [the editor README](/editor/README.md).

- Editor: the Graph nav link is honestly disabled while no file is open
  (#944) — `aria-disabled="true"` with a tooltip, and activation reports the
  reason ("Graph is available once a file is open.") through the
  editing-status live region instead of doing nothing. The link stays
  focusable, re-enables when a file opens, and the scrollspy never marks the
  absent section current. Refs #942, #941.

- Editor: section nav clicks preserve the launch fragment (#943) — the URL
  is rewritten as `#token=…&section=<id>` so a reload after a nav jump stays
  authenticated; the consumed `open=` launch path is deliberately dropped so
  it cannot re-open the file on every reload.

- The managed watch daemon no longer lets trailing spool events resurrect a
  parked daemon: an explicit stop now parks the state `idle` for good, even
  when the dying compiler's final bytes carry a `build-started` (or other
  build boundary) event that races the teardown. Late events are still
  recorded in the event log as factual history (seq, cycle, ring buffer)
  but no longer flip the lifecycle state; the next explicit start clears
  the parked flag and events apply normally again.

### Docs

- Documented the [rendered-search](/docs/contracts/rendered-search.md)
  `data-boris-search-title` marker: a marked heading overrides the document
  title (last one wins), falling back to first `h1`, `<title>`, then the
  canonical path — previously shipped behavior known only from the source
  (#881), now pinned by a contract fixture and unit tests.

- The [code-health pass](https://github.com/drawmeanelephant/boris/milestone/2) closed: all eleven audit cards and the black-box binary round completed, findings filed as GitHub issues for remediation, and the one-pass reports archived from `/docs/audits/code-health/` to [the archived audits](/docs/archived/audits/README.md) per the #693 pattern.

- Added a [tools registry](/docs/tools-registry.md): one table mapping every `tools/` member (docs-maintenance, github-pages-audit, scale-smoke, search-index, source-rag, testdata-generator) to its build wiring (root vs own `build.zig`), coupling class (product CLI / in-process product-module import / product-binary black-box / fully standalone), CI lane, audience, and reason for existing — plus a split-vs-keep reading of the seams. Linked from the [documentation map](/docs/SOURCE-MAP.md) beside the `src/` source map. Implements [#836](https://github.com/drawmeanelephant/boris/issues/836).

- Code-health audit report for the export surfaces (IR, RAG, context bundle, llms.txt, RSS, sitemap, rendered search): determinism verified byte-identical across all surfaces, #778/#750 falsified as recurrences, five low-severity findings filed ([report](/docs/archived/audits/code-health/exports/REPORT.md)).

- Code-health black-box binary round 2 (#808): kit cold-start (neutral prompt, verified `cbc9fa9fe3fc` kit) + 8-group CLI matrix on the archive-layout-audit fixture; two low-severity findings filed (#904, #905), prior-round regressions verified fixed ([report](/docs/archived/audits/code-health/black-box-round-2/REPORT.md)).

- Corrected stale contract wording and help text from the audit sweep: [ir-schema](/docs/contracts/ir-schema.md) output-publication file count and internal edge-kind inventory (#855, #856), [oliver-renderer](/docs/contracts/oliver-renderer.md) Oliver-API scope (#864), [cli](/docs/contracts/cli.md) `--profile`/`--out` rejection on `validate`/`check`/`impact` plus `--help` conflict list (#873), [publication-artifacts](/docs/contracts/publication-artifacts.md) `static` semantics for `static.dir` passthrough (#889), [nostr-publication](/docs/contracts/nostr-publication.md) secret-key hex case (#897), [publication-platforms](/docs/contracts/publication-platforms.md) registry validation mechanism (#898), [standard-site](/docs/contracts/standard-site.md) proof-tree ownership marker (#902), [cloudflare-container-runner](/docs/contracts/cloudflare-container-runner.md) `BORIS_BIN`/`BORIS_WORK_ROOT` environment table (#911); plus two zero-behavior one-liners: removed a duplicated `static-file` kind-table entry (#888) and asserted the `ExitCode.session` (9) contract value (#901).

- Recorded the answer to [#584](https://github.com/drawmeanelephant/boris/issues/584): Nostr NIP-23 stays off the verified-target seam as a decision, not deferred work. A relay list is not a location provider, relays hold no committed artifact inventory, and a `complete` publish verdict is not a Proof Pack claim — so no registry membership, no Nostr Proof Pack claim, and no required live-smoke gate. Reopening requires a product reason that accepts a new location invariant for a destination with no `base_url`. The [first-tester fixture](/docs/contracts/fixtures/nostr-live-smoke/README.md) stays the opt-in Nostr-shaped evidence. Links: [the platform model](/docs/contracts/publication-platforms.md), [the Nostr contract](/docs/contracts/nostr-publication.md).

- Added a [Surge.sh static-host recipe](/docs/surge.md): the shell path from `dist/` to a Surge domain, with the declared-versus-deployment-owned `CNAME` distinction (a Surge-written `dist/CNAME` survives a rebuild untouched; `--static-dir static` makes it an inventoried artifact), the `_boris/proof/` upload boundary a bare `surge ./dist` does not enforce, preview/revision/rollback commands, and a scoped-token CI example. Surge stays a commodity host with no `publication.target` name; [the platform model](/docs/contracts/publication-platforms.md) is unchanged (#848).

## [0.8.2] — 2026-09-02

The v0.8.2 minor release keeps base IR `0.2.0` (conditional semantic-relation and recipe artifacts retain their conditional IR `0.3.0` / recipe `0.4.0` schemas) and packages the post-v0.8.1 maintenance line: the migration laboratory moved to its own repository with the frontmatter parser published as a stable `parser` package module, the `lab` theme and self-verifying `boris init` with starter search, `--static-dir` passthrough, slim default agent kits built around the `boris watch` feedback loop, documentation-intelligence edge counts, baked VCS-revision provenance on RAG and recipe-view outputs, the static-file and embed/entity/`--report` fixes, and the publishing and CookLang guide rewrites.

### Added

- Build provenance (#781) now records the binary's baked VCS revision token in three output surfaces — complete-mode RAG `catalog_meta.json` (`vcs_revision`), `boris recipe-scale` view envelopes (`vcsRevision`), and the publication Proof Pack pair (`vcs_revision` after `target`, mirrored in `_boris/proof/index.html`) — each additive with the `""` sentinel when undetected, so every upstream evidence digest stays deterministic for the same content; the IR artifact set deliberately keeps no provenance field (decision recorded in [cli.md](/docs/contracts/cli.md) and [ir-schema.md](/docs/contracts/ir-schema.md)). Links: [rag-export](/docs/contracts/rag-export.md), [cooklang-compatibility](/docs/contracts/cooklang-compatibility.md), [publication-proof-pack](/docs/contracts/publication-proof-pack.md), [#781](https://github.com/drawmeanelephant/boris/issues/781).
- Standalone `boris-source-rag` corpus metadata now carries the bake-time VCS revision token (`catalog_meta.json` trailing `vcs_revision`, `""` sentinel when undetected; `256`-byte fixed buffer sized for the added field) threaded explicitly from the `build_info` compile-time plumbing rather than any runtime Git probe, mirroring [#794](https://github.com/drawmeanelephant/boris/pull/794)'s additive pattern without touching determinism semantics ([source-RAG guide](/tools/source-rag/README.md), [#795](https://github.com/drawmeanelephant/boris/issues/795)).
- Added the shipped [`lab`](/themes/lab/) theme: a dark-first lab-terminal documentation theme with three persisted color modes (`dark`/`light`/`pride`, applied pre-paint and cycled by a header toggle), the first-party inline rendered-search consumer adapted to a dropdown panel on the documented `data-boris-search-*` hooks, and an optional named print layout. See [the theme catalog](/themes/README.md) and the [`examples/lab-site/`](/examples/lab-site/) specimen.
- `boris init` now proves its own output: after materializing the deterministic starter tree it compiles it through the normal HTML pipeline into a probe directory that is removed again, so exit `0` means "materialized and compiled" with the verified page count in the success report (a probe failure removes the tree and exits `1`; targets outside the workspace skip the probe with an explicit note). The starter theme also ships the rendered-search browser client — search box, `/` hotkey, no-JS fallback — so a fresh site has working search over `dist/_boris/search/search-index.json` out of the box, and the init orientation now points at `check`, `impact`, and `--context`. Links: [the CLI contract](/docs/contracts/cli.md), [the rendered-search contract](/docs/contracts/rendered-search.md).
- `boris init --help` / `-h` now prints init-specific help (exit 0) instead of repeating the full compiler help, mirroring the `standard-site` family's narrow-help behavior. Links: [the CLI contract](/docs/contracts/cli.md).
- Added `--static-dir DIR` (#804): a declared directory of site-owned static files (`robots.txt`, `humans.txt`, `.well-known/`, …) copied byte-identically into the HTML target root, declared as `static-file` records in the artifact inventory, fail-loud on missing dirs, symlinks, unsafe paths, and collisions, with stale-file scrub on rebuild and a per-target `static.dir` profile field. Links: [the HTML output contract](/docs/contracts/html-output.md), the [publication artifact inventory contract](/docs/contracts/publication-artifacts.md), and the [CLI contract](/docs/contracts/cli.md).
- `boris check` and `boris impact` reports now carry `edgeCounts` in the summary — incoming and outgoing edge counts by edge kind, split by endpoint class — closing the documented-but-missing gap in [the documentation-intelligence contract](/docs/contracts/documentation-intelligence.md). Links: [the schema](/docs/contracts/schemas/documentation-intelligence-0.2.0.schema.json), [#821](https://github.com/drawmeanelephant/boris/issues/821).
- Boris now publishes the frontmatter parser as a stable package module (`parser`, exposed through `build.zig` via `b.addModule("parser", …)` and pinned by a package-API test) so dependent builds — including the migration laboratory, which is being split into its own repository — can consume it through `build.zig.zon` instead of a relative source path. See [the standalone-repo plan](/docs/plans/migration-lab-standalone-repo.md).

### Changed

- Agent binary kits now default to the root product CLIs (`boris`, `boris-package`, `boris-source-rag`); standalone developer tools are opt-in via `scripts/agent-pack.sh --all-tools`, and the kit README names the built-in `boris watch --serve` / `--watch-json` feedback loop. Links: [the agent binary kit guide](/docs/AGENT-BINARY-KITS.md).
- Removed the dead legacy `DependencyIndex.renderJson` serializer (schema `0.1.0` `forward`/`reverse` shape) and its test: the shipped `graph.json` is emitted exclusively by the IR emitter under schema `0.2.0`, so no second live shape for the artifact remains. Links: [the IR schema contract](/docs/contracts/ir-schema.md), [#831](https://github.com/drawmeanelephant/boris/issues/831).
- The migration laboratory moved out of this repository: `tools/migration-lab/`, the migration-owned contracts (`astro-import-plan`, `astro-import-apply`, `astro-import-plan-policy-v1`, `takeout-lab-intake` and their schemas), `docs/MIGRATION.md`, and the Contoso fixture now live in the [boris-migration-lab repository](https://github.com/drawmeanelephant/boris-migration-lab); this repo's pointers (README, SOURCE-MAP, the contracts index, AGENT-BINARY-KITS, RELEASE-GATE) link there, and its `migration-lab-test` CI lane was removed. The frontmatter parser remains published as a `parser` package module so the lab can pin it through `build.zig.zon`.

### Fixed

- Fix the OAuth PDS XRPC DPoP path so a live OAuth smoke can complete against bsky.social. The client no longer requires a `DPoP-Nonce` header on non-challenge responses (adopt it best-effort), recognizes a `use_dpop_nonce` challenge by its response body rather than HTTP status (bsky.social uses 401 while the reference PDS uses 400), and sizes the native transport header buffer to four headers so a DPoP `putRecord` does not panic ([`atproto_xrpc.zig`](/src/atproto_xrpc.zig), [`atproto_transport_std.zig`](/src/atproto_transport_std.zig), [#531](https://github.com/drawmeanelephant/boris/issues/531)).
- `boris-scale-smoke` now answers `-V`/`--version` with `boris-scale-smoke/0.8.2` on stdout and exit 0, matching the other nine pack binaries and the shared CLI contract ([`docs/contracts/cli.md`](/docs/contracts/cli.md)) ([#789](https://github.com/drawmeanelephant/boris/issues/789)).
- The Wasm embed result manifest now emits the contract-required `id` field on every diagnostic (string or null) and escapes raw C0 control bytes in JSON strings, so host-supplied file names containing control characters can no longer produce a manifest that fails `JSON.parse`. Links: [the diagnostics contract](/docs/contracts/diagnostics.md), [the embedding contract](/docs/contracts/embedding.md), [#822](https://github.com/drawmeanelephant/boris/issues/822), [#823](https://github.com/drawmeanelephant/boris/issues/823).
- Entity ids now reject Unicode whitespace, not just ASCII space: page filenames and `id:`/`parent:` frontmatter values containing `Zs` separators (NBSP, ideographic space, hair space, …) or the remaining White_Space code points fail validation instead of publishing raw non-ASCII whitespace in filenames and hrefs, honoring the identity contract's no-whitespace rule for the full Unicode subset while valid UTF-8 ids such as `café` and `日本語` keep working. Links: [the identity-and-paths contract](/docs/contracts/identity-and-paths.md), [#830](https://github.com/drawmeanelephant/boris/issues/830).
- HTML `build`/`validate --report` no longer mangles content failures with a phantom `EIO` fallback diagnostic: parse failures now reach the report with their real code, source path, and position, and the generic fallback is skipped whenever the report already holds a structured error, so `errorCount` reflects the actual failure count instead of being inflated on graph or layout failures. A genuine I/O failure with no structured diagnostic still yields the `EIO` explanation. Links: [the diagnostics contract](/docs/contracts/diagnostics.md), [#829](https://github.com/drawmeanelephant/boris/issues/829).

### Docs

- Retitled and rewrote the published [publishing guide](/content/guides/publishing.md) from a target list into a step-by-step publishing-workflows walkthrough: local `dist/` → pick a hosted target → deploy (GitHub Pages with the optional post-deploy audit, or Standard.site offline-first) → read the evidence chain. It preserves the inbound `#github-pages` / `#standard-site` anchors so existing site links (`index.md`, `getting-started.md`, `reference/commands.md`) keep resolving, and it points to [/docs/github-pages.md](/docs/github-pages.md) and [/docs/standard-site.md](/docs/standard-site.md) as the operator authorities.
- Added a [CookLang recipes guide](/content/guides/cooklang.md) covering the `.cook`-only whole-tree mode (mixed trees fail `ECOOKLANG`), the accepted CookLang syntax, recipe references, `recipe-scale --factor`/`--servings` (read-only, timers locked, `servings` frontmatter exception), and the documented bounds — grounded in the [CookLang compatibility contract](/docs/contracts/cooklang-compatibility.md) and linked from the guide index.

## [0.8.1] — 2026-08-25

The v0.8.1 release keeps base IR `0.2.0` (conditional semantic-relation and recipe artifacts retain their conditional IR `0.3.0` / recipe schema bumps) and packages the post-v0.8 integration line: the Boris Editor as a local, compiler-backed authoring host, the Standard.site and Nostr publication CLI families, GitHub Pages verification evidence, the publication Touch Atlas and Proof Pack chain, Oliver-native rendering with the Cooklang seam and first-class themes, standalone tool hardening, and the documentation restructure around the publisher-platform identity. The historical `v0.8.0` tag remains preserved as erroneous evidence.

### Added

- Added graph-aware `--scope`, deterministic byte-capped `--split-size`, product RAG `--bundles-only`, and manifests for selected graph closure and upload parts. See [`docs/contracts/rag-export.md`](/docs/contracts/rag-export.md) and [`docs/contracts/context-bundle.md`](/docs/contracts/context-bundle.md).
- Add a graph-backed pre-Apex rewrite for existing relative Markdown document links, preserving URL suffixes and safety boundaries ([documentation-link contract](/docs/contracts/documentation-links.md)).
- Published JSON Schema (draft 2020-12) for the three IR artifacts under `docs/contracts/schemas/`, so consumers no longer hand-roll parsers from the prose contract. `docs/contracts/ir-schema.md` remains normative.
- `zig build test-ir-schema` validates freshly emitted IR against each published schema and fails on drift in either direction — a required property the emitter dropped, or a property the emitter added that the schema does not describe. Included in the aggregate `zig build test`.
- `boris-source-rag` gained `--pack-by=tool`, an output segmentation axis orthogonal to `--profile`. Instead of one flat corpus it emits a self-contained pack per scope under `packs/`, each with its own `INDEX.md`, catalog, manifests, and bundles, so a single pack can be used without the rest of the tree. Pack boundaries are derived from `scanDirsForProfile` rather than restated, so the packs are the existing profile scopes with `tools` split per tool: `core` (`src`, `layouts`, root files), `docs` (`docs`, `content`), one pack per `tools/<name>/`, and `tooling` for the remainder of the `tools` scope (`scripts`, `test`, `SUPPORT`). Tool packs come from the scanned paths, so a new `tools/<name>/` gets a pack with no code change. Tests assert the resulting totality property: each profile's scan equals the union of its packs, and every scanned directory belongs to exactly one profile scope. The root keeps a router `INDEX.md` and a machine-readable `pack_manifest.json` listing each pack's authoritative byte count, an approximate token figure with its method (`bytes/4`) recorded alongside, and the questions the pack answers. `--split-size` and `--bundles-only` compose per pack. The default (`--pack-by=none`) output is byte-identical to before.
- Added the standalone [`boris-docs-maintenance`](/tools/docs-maintenance/) developer tool to inventory evidence sets, parse dossier markers, and publish deterministic reports ([#209](https://github.com/drawmeanelephant/boris/issues/209)).
- Added a focused process-level contract smoke covering explicit command routing, deterministic JSON goldens, repeated output, and distinct content, usage, and I/O exit classes. See [the CLI smoke](/test/cli-contract.sh) and [CLI contract](/docs/contracts/cli.md).
- Added a deterministic rendered-HTML search index tool and extraction contract; see [the rendered search contract](/docs/contracts/rendered-search.md).
- Added conditional Ubuntu/macOS CI coverage for the standalone `tools/search-index` and `tools/docs-maintenance` test gates. See the [release-gate workflow policy](/docs/RELEASE-GATE.md).
- Added staged compiler publication and the default-layout browser UI for the deterministic [rendered-search artifact](/docs/contracts/rendered-search.md), including an accessible zero-results state and no-JavaScript navigation fallback.
- Added a deterministic, review-only [relationship target inventory](/tools/migration-lab/README.md) to the Starlight migration laboratory, retaining exact path-derived keys, provenance, duplicate-key evidence, and selection exclusions without emitting Boris relations.
- Added deterministic exact-key relationship candidate classification against the standalone migration-lab inventory, preserving `inventoried`, `ambiguous`, `absent`, and `invalid` review evidence without emitting Boris relations. See the [migration-lab guide](/tools/migration-lab/README.md).
- Published local `href`/`src` references are now audited against the outputs a build intends to keep, immediately before the staged tree is committed, so a reference that climbs above the output root or names nothing publishable fails the build with `EROUTEESCAPE` / `EROUTEMISSING` and leaves the published tree untouched. Links: [the diagnostics contract](/docs/contracts/diagnostics.md).
- Added a reproducible [`agent-pack`](/scripts/agent-pack.sh) workflow that gathers Boris's native CLIs with commit metadata and SHA-256 verification for agent handoff; see the [agent binary kit guide](/docs/AGENT-BINARY-KITS.md).
- `src/encode.zig` and `src/structured_out.zig`: a shared output-encoding layer for machine-facing emitters, with per-container targets (YAML scalar, YAML flow-sequence item, markdown table cell, markdown heading, markdown block text, and XML text/attribute for a future feed emitter). `structured_out.Sink` only accepts `comptime` template text on its literal path, so a runtime value cannot reach an emitter unencoded without the explicit, greppable `rawTrusted` opt-out. JSON escaping continues to live in `json_out.zig`; the sink delegates to it rather than duplicating it.
- Added deterministic RSS 2.0 export with strict UTC publication metadata, safe deployed-page URLs, and atomic single-file publication. See the [RSS contract](/docs/contracts/rss-2.0.md).
- Added deterministic staged XML sitemap generation for one HTML target, with strict public URL/path validation, protocol limits, and obsolete-output cleanup. See the [XML sitemap contract](/docs/contracts/xml-sitemap.md).
- Added the strict, internal schema-v1 publication-profile parser and static planner, without exposing an incomplete profile workflow. See the [publication-profile contract](/docs/contracts/publication-profile.md).
- Added the read-only internal rendered HTML and search-snapshot auditing kernel in [`src/doctor.zig`](/src/doctor.zig), without exposing a public command or changing publication output.
- Added a deterministic, read-only Astro plain-Markdown import planning surface with snapshots, canonical SHA-256 plan digests, and explicit quarantine evidence; see [the plan contract](/docs/contracts/astro-import-plan.md).
- Hardened Slice A with no-follow selected-root validation, code-aware executable/reference classification, truthful bounded frontmatter, final-identity collision evidence, required proposal validation, and real Draft 2020-12 schema tests.
- Added deterministic initial-create Astro import application from reviewed Slice A evidence, including source-state re-verification, atomic staging, importer custody metadata, and immutable base blobs; see [the apply contract](/docs/contracts/astro-import-apply.md).
- Hardened Slice B1 stage ownership cleanup and added public CLI, fixture, source-confinement, semantic-plan, and independent manifest/base-blob verification coverage.
- Added a native, read-only Filed.fyi full-corpus scan mode with deterministic source, frontmatter, identity, hierarchy, relation, link, asset, component, and malformed-record ledgers. See the [migration-lab guide](/tools/migration-lab/README.md).
- Added the standalone Zig [`boris-testdata` fixture generator](/tools/testdata-generator/README.md) with deterministic graph-aware Markdown generation, extensible phase-aware barbs, a mild post-publish poison profile, external theme/template inputs, canonical Boris artifact-inventory consumption, non-normative output snapshots, fixture manifests, and Boris subprocess evidence.
- Added the deterministic, stdout-only `boris plan --profile PATH` declaration surface for normalized publication intent, with a versioned [publication-plan contract](/docs/contracts/publication-plan.md) and schema.
- Added a deterministic target-owned HTML payload inventory with exact byte sizes and SHA-256 digests; see the [publication artifact inventory contract](/docs/contracts/publication-artifacts.md).
- Ensured the inventory is the last target payload replaced, so a failed replacement cannot expose a next-generation inventory for an older target.
- Documented the existing per-file staged-publish limitation: a mid-tree filesystem failure can leave earlier payload replacements visible, while the prior inventory remains authoritative for the last successful publication.
- Added deterministic target-local publication checks evidence at [`_boris/proof/checks.json`](/docs/contracts/publication-checks.md), bound to the committed artifact inventory and exact payload bytes.
- Added deterministic target-local publication claims-and-limitations evidence at [`_boris/proof/claims.json`](/docs/contracts/publication-claims.md), derived strictly from the committed artifact inventory and checks evidence bytes, with three fixed mechanical claims and six declared limitations.
- Extend the executable publication-conformance evidence suite with C01 (valid Textile HTML), C05 (layout precedence), C06 (cache/watch failure paths), and C07 (asset collisions and SVG policy), including a bounded watch-lifecycle test and two remediation cards for confirmed defects (watcher exit on failed include rebuild; active-SVG rejection exit class). The C05 and C06 incremental cases reuse one output directory per scenario (an `--incremental` first publication followed by `--incremental` rebuilds into the same target), the exit trap reaps every retained watcher PID, and the watch-failure case pins the exact exit code. Links: [conformance report](/docs/archived/audits/publication-conformance/REPORT.md), [watch-mode contract](/docs/contracts/watch-mode.md), [content-local-assets contract](/docs/contracts/content-local-assets.md), [textile-compatibility contract](/docs/contracts/textile-compatibility.md).
- Added the Phase 6A deterministic [publication Touch Atlas contract](/docs/contracts/publication-touches.md), schema, and hand-checkable examples; implementation and `touches.json` emission remain explicitly deferred.
- Boris now derives and atomically replaces a deterministic target-local `touches.json` Touch Atlas after the claims report commits. The atlas is a relationship index over the exact committed bytes of `artifacts.json`, `checks.json`, and `claims.json` only: it connects targets to inventory artifacts, artifacts to check subjects and supporting inputs, checks to findings and claims, and claims to limitations. A malformed or stale upstream report prevents a new atlas, and a failure preserves any prior report and emits the committed-target diagnostic even under `--quiet`. Links: [publication Touch Atlas contract](/docs/contracts/publication-touches.md).
- Publication Touch Atlas status moved from "contract drafted, implementation not yet shipped" to "implemented first slice". The contract's documented non-claims (source provenance, runtime transformation traces, deployment graphs, accessibility/prose inference, proof-pack presentation, and repair actions) remain explicitly out of scope. Links: [STATUS](/docs/STATUS.md).
- Added the Phase 7A deterministic [publication Proof Pack contract](/docs/contracts/publication-proof-pack.md), Draft 2020-12 schema, and hand-checkable JSON/HTML examples; the presentation model includes root finding rows after the check rows, an embedded model digest in the static HTML, a first-slice two-file generation transaction (exit 3 on failure, prior-pair preservation when restoration succeeds, explicit recovery-failure honesty, split-pair detection), schema enforcement that constrains every relationship node ID and edge endpoint to the closed Touch Atlas stable-ID vocabulary, and a stdlib-only HTML/JSON parity checker under `docs/audits/publication-proof-pack/` that binds target/format/schema-version identity from the model and rejects extra relationship groups. Implementation and `proof-pack.json` / `index.html` emission remain explicitly deferred.
- Emitted the first shipped deterministic [publication Proof Pack](/docs/contracts/publication-proof-pack.md) pair `_boris/proof/proof-pack.json` + `_boris/proof/index.html` as the final presentation layer after the Touch Atlas commits. The pack binds the exact committed artifacts, checks, claims, and touches bytes (never rereading payloads, source, cache, or deployment state), derives a mechanical overall status, renders every model fact with full HTML escaping, embeds the lowercase SHA-256 of the exact `proof-pack.json` bytes in the static HTML, and installs both files through a first-slice staged transaction (tmp write + verify, `.prev` preservation, `index.html` first, `proof-pack.json` as the commit point, unconditional `.prev` cleanup on success, prior-pair restoration on handled failure with explicit recovery-failure honesty). A Proof Pack failure keeps the committed target and all four evidence reports, exits with code 3, and emits the diagnostic even under `--quiet`.
- Add a standalone, bounded Zig GitHub Pages post-deploy observer with a versioned deployment-evidence contract and separate retained workflow artifact; the optional audit binds observations to the normalized plan and exact target-local inventory without changing the public Pages payload. See [`github-pages-deployment-evidence`](../contracts/github-pages-deployment-evidence.md) and [`GitHub Pages workflow guidance`](../github-pages.md).
- Add a fail-closed GitHub Pages publication target declaration, exact public artifact packaging, retained evidence binding, and the official Pages Actions workflow; see [`docs/github-pages.md`](../github-pages.md) and the [`publication-profile` contract](../contracts/publication-profile.md).
- Pinned ten Proof Pack-layer semantic-rejection negative controls in `writeAfterTouches`' test block, covering changed artifact digests, check-status rewrites with repaired bindings, overlapping finding ranges, wrong claim-to-check bindings, changed limitation sources, and Touch Atlas node-metadata, missing/extra/reversed edges, and kind/id mismatches — each asserted to reject while preserving the prior pair byte-for-byte, per the [publication proof pack contract](/docs/contracts/publication-proof-pack.md).
- New standalone, deterministic, read-only [`boris-content-audit`](/tools/content-audit/) tool: audits poetry coverage, canonical parent alignment, verse density, placeholders, and mapping exceptions in an existing Boris content tree. Not part of publication, never writes to the source tree, and not wired into the root `zig build test` gate — build and test via [`tools/content-audit/build.zig`](/tools/content-audit/build.zig) or the root aggregate commands `zig build content-audit` and `zig build test-content-audit`. CI runs a dedicated content-audit lane on Linux and macOS with a strict success requirement in the aggregate `ci` job.
- Hardened [`boris-content-audit`](/tools/content-audit/): tool-owned output backup handling validates the ownership marker content, a bounded frontmatter grammar conforms to the Boris frontmatter contract, unregistered poetry shapes are never analyzed as paragraph units, Markdown fence semantics are honored, policy mapping tables are validated (stale keys, impossible targets, duplicate source/type coverage), delta compatibility is strict, collection filters scope every section consistently, and the consumer GitHub Actions workflow acquires a pinned tool build with exit-status capture.
- Added `boris validate`, an artifact-free HTML source/configuration preflight that reuses canonical compiler semantics. See the [validation contract](/docs/contracts/validation.md).
- Added `--timings`, an opt-in machine-readable phase timing and counter report on stdout. It records scan/parse/graph/dependency durations on every mode and the full HTML publication pipeline (fingerprint, render, heading harvest, search, link audit, inventory, checks, claims, touches, proof pack) with page/include read, hash, link-resolution, and fast-path-hit counters. Default output, diagnostics, exit codes, artifacts, and `--quiet` are unchanged when the flag is absent. `plan` rejects the flag as conflicting (exit 2): its stdout is reserved for the single declaration JSON document. See the [CLI contract](/docs/contracts/cli.md).
- Cooklang recipe input via `--cooklang`, a `.cook`-only tree mode alongside `--textile`. Cooklang metadata is already YAML front matter, so Boris's frontmatter parser is unchanged and [`src/cooklang_seam.zig`](/src/cooklang_seam.zig) adapts only the body: ingredients, cookware, timers, sections, notes, both comment forms, short-hand preparations, and forced line breaks. The rendered document is an `## Ingredients` list, a `## Cookware` list, and `## Method` numbered steps. Author text is escaped against the engine Boris actually links — Oliver, CommonMark 0.31.2 (652/652 conformance) plus GFM tables and the opted-in heading-attribute, footnote, definition-list and strikethrough extensions. The per-byte set covers CommonMark's live punctuation (`|` table cells, `#` headings, `-`/`+` list items, `` ` `` code spans, `[`/`]` links, `=` setext underlines, `~` strikethrough) and the entity characters `&`, `<`, `>` against raw-HTML interpretation. A `"` guard survives from the old Apex path, where fenced divs emitted `class="…"` unescaped and `:::x"onmouseover="alert(1)` published `<div class="x"onmouseover="alert(1)">`; Oliver has no fenced divs, so that injection is closed by the renderer migration, but the guard is harmless under CommonMark and keeps the adapter engine-agnostic. Every author-controlled span is guarded, including token names, quantities, preparations and section names, and the bounded subset refuses macros, wiki links, raw HTML, control characters, unterminated `{`, `(` or `[-`, and over-long or over-numerous tokens with `ECOOKLANG`. A recipe reference (`@./sauces/pepper-oil{1%tbsp}`) becomes a real wiki link and therefore a validated graph edge of kind `reference`, so a reference to a recipe that does not exist fails the build instead of rendering as dead prose. The structured recipe reaches the IR as the `recipe` node facet — quantities stay strings because Cooklang admits `1/2` and `1-2`, and references are never merged because adding `200%g` to `1%cup` needs a unit model Boris does not have. Like semantic relations before it, the version bump is conditional: a corpus with no recipes still emits `0.2.0`, so existing artifacts do not move. Contract: [cooklang-compatibility.md](/docs/contracts/cooklang-compatibility.md); schema: [`ir-graph-0.4.0.schema.json`](/docs/contracts/schemas/ir-graph-0.4.0.schema.json); fixtures: [`fixtures/cooklang-compatibility/`](/docs/contracts/fixtures/cooklang-compatibility/).
- `boris init [DIR]` materializes a deterministic starter site that builds, validates, and plans out of the box: three graph-exercising Markdown pages, a starter theme on the closed layout slots, and a publication profile. It refuses to clobber a non-empty directory, is byte-deterministic across runs, and rejects compiler-phase flags as usage errors. (#391, [/docs/contracts/publication-profile.md](/docs/contracts/publication-profile.md) for the generated profile schema)
- Editor ergonomics (contracts first, no LSP in this slice):
- The closed frontmatter grammar now has a machine-readable twin, [`boris-frontmatter-1.schema.json`](../contracts/schemas/boris-frontmatter-1.schema.json), describing the parsed field set as a JSON object (closed key set, typed values, normative bounds). The schema-conformance suite validates every fixture tree's parsed frontmatter against it.
- A successful IR build now publishes `completion.json` alongside `manifest.json` / `graph.json` / `build-report.json`: a deterministic editor completion surface with entity ids (title, parent, role, status, tags, relations), the relation-kind vocabulary (canonical plus observed), distinct parent targets, and the closed layout-slot set. Schema: [`boris-completion-1.schema.json`](../contracts/schemas/boris-completion-1.schema.json).
- Wiki-link fragment heading ids are Oliver-rendered on the HTML path and are documented as out of scope for the IR completion index; the entity id list serves the `[[entity#…]]` completion prefix.
- Added a top-level [authoring spine](/docs/authoring-spine.md): a non-normative teaching path — start → content & frontmatter → links & graph → layout → publish → verify — grounded in the `boris init` starter tree and linking into the contract warehouse instead of duplicating it. Each step reuses the closed vocabulary already published for editors (`boris-frontmatter-1.schema.json`, the `completion.json` entity/parent/ relation/layout-slot vocabulary). Linked from the README.
- `_boris/proof/artifacts.json` records now carry pixel `dimensions` (`{width, height}`, parsed from image headers where determinable) and an explicit `semantics` value (`static` for theme-owned assets, `content-reference` for content-local `.assets/` trees, `null` for non-asset records), documented in the [publication artifact inventory contract](/docs/contracts/publication-artifacts.md). The keys are optional-on-parse, so inventories written before them still round-trip unchanged.
- Added a normative [publication platform model](/docs/contracts/publication-platforms.md): the verified-target chain, the three-adapter seam (location provider, deployer, packaging rules), the closed `publication.target` registry boundary, and the deployment matrix — GitHub Pages shipped and verified, Cloudflare Pages deliberate-but-waiting, Vercel/Netlify wait for demand, commodity hosts never proactive, with the Cloudflare runtime/edge directions tracked separately (#300, #301).
- `boris --version` / `boris -V` now print the compiler id (e.g. `boris/0.8.1`) to stdout and exit 0, short-circuiting like `--help` (no content tree is read), and are listed in the [README quickstart](/README.md). Closes the version-query gap for tooling that needs to pin the compiler.
- The [editor](/content/guides/editor.md) recognizes a `.cook`-only tree, invokes Boris with `--cooklang`, and shows a read-only recipe facet (ingredients, cookware, timers, `recipeRef`) from `graph.json`. Scaling is not implemented; that is compiler issue [#554](https://github.com/drawmeanelephant/boris/issues/554) ([#418](https://github.com/drawmeanelephant/boris/issues/418) M7).
- The [editor](/content/guides/editor.md) now inspects the compiler `graph.json` for the open page: parent, children, backlinks, references, includes, completion relations, and wiki-link tokens in the buffer, with command-palette jump by entity id or title ([#418](https://github.com/drawmeanelephant/boris/issues/418) M6).
- Added the first Boris Editor substrate: a loopback Zig host, semantic Svelte shell, strict compiler-artifact version adapter, and real-compiler black-box gates, while keeping project content read-only. See the [editor README](../../editor/README.md).
- The [editor](/content/guides/editor.md) lists existing publication profiles, runs [`boris plan --profile`](/docs/contracts/publication-plan.md), and shows the normalized declaration plus any local [Proof Pack](/docs/contracts/publication-proof-pack.md). It does not deploy ([#418](https://github.com/drawmeanelephant/boris/issues/418) M9).
- The [editor](/content/guides/editor.md) consumes the HTML `--report` for layout diagnostics, shows a theme-layout inspector over closed slots, and offers 375/768/1440 preview widths plus an honest accessibility review aid. Fallback layout winners remain unrecorded ([#557](https://github.com/drawmeanelephant/boris/issues/557); [#418](https://github.com/drawmeanelephant/boris/issues/418) M8).
- The [editor](/content/guides/editor.md) records the #418 M10 keyboard checklist, defaults Textile create paths to `.textile`, and keeps recipe scaling an honest gap until [#554](https://github.com/drawmeanelephant/boris/issues/554). Spoken Voice Control is not claimed ([#418](https://github.com/drawmeanelephant/boris/issues/418) M10).
- Added a standalone reproducer for the Touch Atlas streaming-checks parse failure ([#420](https://github.com/drawmeanelephant/boris/issues/420)): a synthesized 216-finding `checks.json` that dies at finding #207 when its `owner` value straddles the 64 KiB streaming buffer, with a 13-byte-longer control that parses cleanly. (Retired with the canary in the same unreleased window; see the #420 resolution in [the Touch Atlas contract](/docs/contracts/publication-touches.md).)
- Added explicit, atomic Boris Editor file operations with external-change conflicts, content undo/redo, and disposable crash recovery, backed by filesystem and accessible-interaction gates. See the [editor safety contract](../../editor/README.md#m2-safe-file-editing).
- Added the Boris Editor's fixed-command validation workflow and accessible Problems panel, consuming only Boris-owned reports with a documented stderr fallback. See [the editor contract adapter](/editor/README.md).
- Added a maintained theme-example portfolio with the Textpattern candidate, refreshed examples, and six framework-inspired Boris-native studies under [the examples directory](/examples/README.md).
- Added accessible schema- and graph-aware Boris Editor completion sourced exclusively from canonical Boris artifacts. See [the editor authoring workflow](/editor/README.md).
- Added the Boris Editor's loopback live-preview fallback with build-on-save, last-good preservation, and explicit stale/failure states; the embedded preview frame is allowed through the host Content-Security-Policy and its real-browser rendering is covered by the integration gate. See [the preview workflow](/editor/README.md).
- Added a `zig build test-doc-links` guard inside `zig build test`: every relative Markdown link in `README.md` and the [authoring spine](/docs/authoring-spine.md) must resolve to a real file or directory, heading anchors must match GitHub-style slugs, and the spine must keep its six-step shape. The first run caught the README's phantom `benchmark/` link; the Benchmarking section now states honestly that no committed benchmark harness exists yet.
- Added a host-independent Zig AT Protocol OAuth foundation with PKCE, P-256 JWK/thumbprints, ES256 DPoP proofs, RFC vectors, and a freestanding compile gate. See the [OAuth core contract](/docs/contracts/atproto-oauth.md).
- Added an offline, deterministic Nostr NIP-23 publication plan: `boris nostr plan --profile PATH` reports the eligible articles, their publication-safe Markdown, and the tags each long-form event would carry, holding no key and contacting no relay. See the [Nostr publication contract](/docs/contracts/nostr-publication.md).
- The [editor](/content/guides/editor.md) now has a Ctrl+K command palette for file actions: type to filter, arrow keys to navigate, Enter to run. Create, Rename, and Delete reuse the existing dialogs, and Open file entries route through the unsaved-changes resolution dialog when the buffer is dirty ([#462](https://github.com/drawmeanelephant/boris/issues/462)).
- The [editor](/content/guides/editor.md) Create, Rename, Delete, and conflict dialogs now show visible Enter (confirm) and Esc (cancel) key hints. The Delete and conflict dialogs focus their primary action when opened, so Enter confirms it directly ([#462](https://github.com/drawmeanelephant/boris/issues/462)).
- The [editor](/content/guides/editor.md) unsaved-changes resolution dialog now supports keyboard shortcuts: Alt+S saves and continues, Alt+D discards and continues, with visible hints on the action buttons ([#462](https://github.com/drawmeanelephant/boris/issues/462)).
- The [editor](/content/guides/editor.md) completion combobox now shows visible arrow, Enter, and Esc key hints, and Esc closes the suggestion list without clearing the filter. The recovered-work banner shows a Tab+Enter hint for its action buttons ([#462](https://github.com/drawmeanelephant/boris/issues/462)).
- The [editor](/content/guides/editor.md) Ctrl+K command palette now also runs editor commands: Save file, Validate project, Build diagnostics, Build HTML, Check graph, Run impact, Rebuild preview, and Focus source pane. Commands and preview rebuilds still route through the unsaved-changes resolution dialog when the buffer is dirty ([#462](https://github.com/drawmeanelephant/boris/issues/462)).
- Added Standard.site as the second verified publication target: opened `publication.target` into a closed registry, and added a deterministic offline projection (publication + document records, rkey encoding, eligibility exclusions) with a machine-readable plan artifact. See the [Standard.site target contract](/docs/contracts/standard-site.md) and the [platform registry](/docs/contracts/publication-platforms.md).
- Added Standard.site verification surfaces: a compiler-owned `{{head}}` slot for deterministic document link tags, well-known publication-record emission (with a base-path limitation report instead of a decoy), and a deterministic post-commit verification report. See the [Standard.site target contract](/docs/contracts/standard-site.md) and the [diagnostics contract](/docs/contracts/diagnostics.md).
- Added a typed atproto XRPC record client (get/put/deleteRecord) with DPoP-authenticated requests, nonce retry, origin pinning, and an offline mock transport with a freestanding compile gate. See the [OAuth core contract](/docs/contracts/atproto-oauth.md) for the authorization foundation it builds on.
- Added Standard.site publish reconciliation: precondition verification of the session DID, PDS, collections, rkeys, and plan digest; per-record create/update/unchanged/failed/orphan classification with compare-and-swap, confirming reads for ambiguous writes, and explicit prune authority; plus a deterministic intended-vs-observed evidence artifact. See the [reconciliation contract](/docs/contracts/standard-site-reconciliation.md).
- Added the explicit one-shot publish command `boris standard-site publish --profile PATH`, composing the merged identity discovery and OAuth authorization with the Standard.site projection, verification surfaces, and reconciliation: resolve the configured DID, verify the DID document's PDS against the profile-bound PDS before the browser opens, authorize once in-memory, reconcile per-record with zero writes for unchanged state, and emit intended-vs-observed evidence to `--out` or stdout. `--plan` validates a committed plan byte-for-byte before any network mutation, `--prune` is the explicit prune authority, and `--source-commit` records the source revision. Exit codes 4–8 classify denial, timeout, compatibility, partial-publication, and verification failures; no secret ever appears in output or evidence. See the [standard-site](/docs/contracts/standard-site.md) and [reconciliation](/docs/contracts/standard-site-reconciliation.md) contracts.
- Added persistent Standard.site sessions: `boris standard-site login` authorizes a DID in the browser and persists the DPoP-bound session under a user-scoped, `0600`, atomically-replaced store; `boris standard-site sessions` lists stored DIDs; `boris standard-site logout` securely erases one session. `standard-site publish` now reuses a stored session and refreshes it in place (rotate-or-die, fail-closed after an ambiguous timeout) instead of re-opening the browser every run, and re-verifies the session's DID, PDS, and authorization server against fresh discovery before any write. Exit code 9 classifies session-layer failures. See the [sessions contract](/docs/contracts/atproto-sessions.md) and the [diagnostics contract](/docs/contracts/diagnostics.md).
- Added a deterministic semantic plain-text projection over the Oliver typed document (`render.renderPlainText`, `html_body.renderSourcePlainText`) and wired it into Standard.site `textContent`: links keep their labels, images keep their alt text, fenced code stays verbatim, and Markdown/HTML chrome is dropped. The projection is omitted — never substituted with raw source or HTML — when rendering fails or exceeds the 256 KiB record bound. See the [plain-text projection contract](/docs/contracts/plain-text-projection.md).
- Added the opt-in live interoperability smoke `boris standard-site smoke --did DID`, a manual, bounded gate that proves discovery, OAuth, XRPC writes, readback, verification surfaces, and cleanup against a real test identity. Every created record uses a unique `boris-smoke-<…>` namespace, is read back and verified before success is claimed, and cleanup deletes only the two rkeys the run created. The run emits a deterministic, secret-free `boris-live-smoke-result` artifact recording the exact server identity and specification baseline; indexer observation is reported but never gates the result. The live path is CLI-only and excluded from `zig build test` and all default CI paths. See the [live smoke contract](/docs/contracts/atproto-live-smoke.md).
- Added offline NIP-23 signing: `boris nostr sign --plan PLAN --key-stdin` reads the plan artifact from `boris nostr plan`, reads the secret key once from stdin (hex or `nsec`, never argv/profile/env), and writes a signed-event bundle with the exact NIP-01 event id and BIP-340 signature for every article (bitcoin-core/secp256k1 `v0.8.0`, pinned; fresh aux randomness, context randomization, signature self-verification before any bundle is written). `--prior` reuses unchanged prior events and enforces the strict `created_at` update-ordering tie-break for changed intentions. See the [Nostr publication contract](/docs/contracts/nostr-publication.md).
- Added online NIP-23 publishing: `boris nostr publish --plan PLAN --bundle BUNDLE` sends the exact signed events from a `nostr sign` bundle to the plan's configured relays over a bounded in-repo RFC-6455 WebSocket client (`ws_client.zig`, `std.net` + `std.crypto.tls` with hostname verification and system CA roots). Nothing is sent before the bundle is cross-verified against the plan (digest, expected pubkey, event ids, BIP-340 signatures). Every relay interaction is bounded by per-read deadlines and produces per-relay evidence; the run always reaches a `complete` / `partial` / `failed` / `incomplete` verdict, and relays that demand NIP-42 authentication are reported honestly as `auth-required` (unsupported in v1, #493) while the remaining relays are still attempted. A hostile mock-relay conformance matrix covers fragmented `OK`, Ping/Pong, Close-before-OK, masked server frames, timeout, malformed messages, wrong event ids, oversized frames, bad handshakes, retries with identical event bytes, and mixed multi-relay classification. See the [Nostr publication contract](/docs/contracts/nostr-publication.md).
- `boris init` writes `standard-site.json`, an obviously-fake Atmosphere starter (placeholder DID and URL, no `pds`) so first testers do not copy the contract fixture. See the [operator path](/docs/standard-site.md) and [#528](https://github.com/drawmeanelephant/boris/issues/528).
- `boris --profile PATH` on the HTML build emits Standard.site verification surfaces (head links + well-known) when the profile target is `standard-site`. `standard-site verify` can now pass against a CLI-built `dist/`. See the [Standard.site contract](/docs/contracts/standard-site.md) and [#533](https://github.com/drawmeanelephant/boris/issues/533).
- Boris now classifies Cooklang amount strings as empty, scalable, or fixed and scales only the scalable ones as exact rationals ([#554](https://github.com/drawmeanelephant/boris/issues/554), [the Cooklang contract](/docs/contracts/cooklang-compatibility.md)). Source `.cook` files and `graph.json` are unchanged. A CLI that prints the scaled view is a later slice.
- `boris nostr plan` emits NIP-19 `author.npub`, per-article `naddr`, and `naddr_uri`. Profile `nostr.pubkey` accepts `npub1…` as well as hex. See the [Nostr publication contract](/docs/contracts/nostr-publication.md) and [#566](https://github.com/drawmeanelephant/boris/issues/566).
- `boris --profile PATH` emits `<link rel="alternate" href="nostr:naddr1…">` on eligible allowlisted pages when `nostr.enabled` is set. See the [Nostr publication contract](/docs/contracts/nostr-publication.md) and [#571](https://github.com/drawmeanelephant/boris/issues/571).
- Shipped a first-class theme catalog under [`themes/`](/themes/README.md) (`boris`, `reference`, `press`, `showcase`, `archive`) and moved their specimen content to sample sites under [`examples/`](/examples/README.md).
- Promoted the original-voice example themes into [`themes/`](/themes/README.md) (`field-notes`, `compact`, `cards`, `cozy`, `journal`, `ledger`) and added [`reading`](/themes/reading/) for `:lang` typesetting. Sample sites remain under [`examples/`](/examples/README.md).
- Thickened the six framework-inspired studies into first-class themes ([`semantic`](/themes/semantic/), [`columns`](/themes/columns/), [`service`](/themes/service/), [`engineering`](/themes/engineering/), [`civic`](/themes/civic/), [`tokens`](/themes/tokens/)) over one specimen at [`examples/studies-site/`](/examples/studies-site/).
- Finished the two prototype shells as first-class themes ([`corporate`](/themes/corporate/) and [`minimal`](/themes/minimal/)): real graph nav, no `#` links or dead buttons, first-party search only on Corporate.
- `boris recipe-scale --input DIR --id PAGE --factor TEXT` prints a derived Cooklang scale view as JSON. Ingredients and cookware scale; timers stay put. Source `.cook` files and `graph.json` are unchanged ([#596](https://github.com/drawmeanelephant/boris/issues/596), [the CLI contract](/docs/contracts/cli.md), [the Cooklang contract](/docs/contracts/cooklang-compatibility.md)).
- The editor Recipe pane can ask `boris recipe-scale` and show the derived view. Scale recipe and Reset scale do not rewrite `.cook` files ([#597](https://github.com/drawmeanelephant/boris/issues/597), [the Cooklang contract](/docs/contracts/cooklang-compatibility.md)).
- The Oliver render seam now compiles for `wasm32-freestanding` and a spike module produces byte-identical HTML for the compile golden, with no host imports. See [the embedding contract](/docs/contracts/embedding.md) and [#301](https://github.com/drawmeanelephant/boris/issues/301) M0.
- Added `boris-job-runner`, a hosted archive-to-native-`boris` runner with a Cloudflare Containers Worker example. This is not a verified publication target. See the [hosted-runner contract](/docs/contracts/cloudflare-container-runner.md).
- The IR compile path can read an in-memory source bundle through a [source-provider](/docs/contracts/source-provider.md) seam; the native CLI keeps the filesystem adapter. See [#607](https://github.com/drawmeanelephant/boris/issues/607).
- IR publication can emit through an in-memory [artifact sink](/docs/contracts/artifact-sink.md); the native CLI keeps stage+rename on disk. See [#608](https://github.com/drawmeanelephant/boris/issues/608).
- Native [`compileBundle`](/docs/contracts/embedding.md) compiles an in-memory source list to structured diagnostics and JSON IR without a host directory. See [#609](https://github.com/drawmeanelephant/boris/issues/609).
- [`compileBundle`](/docs/contracts/embedding.md) can emit Oliver HTML through the in-memory artifact sink after a successful IR compile. See [#610](https://github.com/drawmeanelephant/boris/issues/610).
- A `wasm32-wasi` [`compileBundle` ABI](/docs/contracts/embedding.md) exports files-in / diagnostics-and-IR-out through pointer/length handles. Hosts trap unused WASI imports. See [#611](https://github.com/drawmeanelephant/boris/issues/611).
- [`compileBundle`](/docs/contracts/embedding.md) can emit the target-local artifacts/checks/claims/touches chain from sink bytes, with native-vs-Wasm parity and no successful claims after a failed compile. See [#612](https://github.com/drawmeanelephant/boris/issues/612).
- An official Cloudflare Worker [host example](/hosts/cloudflare-worker/README.md) wraps the embed Wasm ABI, enforces host limits, and uploads successful artifacts to R2. It is not a `publication.target`. See [#613](https://github.com/drawmeanelephant/boris/issues/613).
- The embed Worker's artifact manifest makes SHA-256 digests opt-in via `include_sha256` (default off): hashing costs host CPU and response bytes per artifact (~0–7 ms at 89 artifacts, with R2 put overhead the dominant cost), so the lean default stands unless a caller requests integrity digests. See the [embedding contract](/docs/contracts/embedding.md) and [PR #633](https://github.com/drawmeanelephant/boris/pull/633).
- Added bounded open semantic relation kinds, deterministic `{{relations}}` / `{{backlinks}}` HTML slots, and page-local incremental fingerprints for backlink rendering. See [the semantic-relations contract](../contracts/semantic-relations.md).
- Added the opt-in app-password credential path for Standard.site: `boris standard-site login --app-password (--did DID | --handle HANDLE)` resolves the identity, discloses the broad write access it grants, reads the app password from stdin (never argv, environment, profile, logs, or evidence), authenticates with `com.atproto.server.createSession`, and persists a `boris-app-password-v1` session under the same `0600`, atomically-replaced store as OAuth sessions. `standard-site publish` and `standard-site smoke` reuse a stored app-password session through the Bearer XRPC path and refresh it with the same rotate-or-die rule; OAuth remains the primary path and never falls back to a credential. See the [app-password RFC](/docs/contracts/atproto-app-password.md) and the [sessions contract](/docs/contracts/atproto-sessions.md).
- Added `boris standard-site plan --profile PATH [--out PATH]`, a pure-offline command that renders the deterministic Standard.site plan (publication + document records, `textContent` digests, exclusions, verification surfaces) to stdout or a file with no network authority. It shares the compile and projection pipeline with `publish`, so the emitted bytes match the plan `publish --plan` validates. See the [Standard.site target contract](/docs/contracts/standard-site.md).
- Added `boris watch --serve [--port N]`: loopback-only static serving of the built HTML tree (default `127.0.0.1:8090`) that reloads the browser after each successful rebuild via a server-generated helper page and SSE stream; the output directory on disk is never modified, and multi-target builds serve the first canonical-order target. See the [CLI contract](/docs/contracts/cli.md).
- `boris build --report PATH` / `validate --report PATH` include an informational `ILAYOUTSELECTED` finding per rule-selected page, recording the selector and winning layout path; fallback layouts emit nothing, and the finding never affects `errorCount` or exit codes. See [the diagnostics contract](/docs/contracts/diagnostics.md).
- Added `--report PATH` for HTML builds and validate: a deterministic JSON diagnostics report (`html-build-report-0.1.0`) covering parse/graph, component, include, wiki-link, asset, link-audit, and layout diagnostic classes with stable codes, content-root-relative source paths, and positions; stderr, exit codes, and artifact bytes are unchanged. Schema twin: [`html-build-report-0.1.0.schema.json`](/docs/contracts/schemas/html-build-report-0.1.0.schema.json).
- Added the opt-in `--target-profile NAME=xhtml` output profile: an XML-compatible serialization of the same normalized document that fails closed on verbatim raw HTML (`RawHtmlNotXmlWellFormed`), valid for `build` and `validate` and rejected elsewhere; the default `html` output stays byte-identical. See the [multi-target contract](/docs/contracts/multi-target-isolated-output.md) and [Oliver renderer contract](/docs/contracts/oliver-renderer.md).
- `boris watch --watch-json` now emits a machine-readable event stream: one NDJSON object per line on stderr (`hello` version handshake, `build-started`, `build-succeeded`, `build-failed` with structured diagnostics, `watcher-started`, `serve-started`, `watch-error`, `watch-stopped`). The stream is exclusively NDJSON — compile progress and prose diagnostics are suppressed for the lifetime of each build — and `--quiet` is implied for the compile path while exit codes stay unchanged. The single-target watch recovery set now matches the multi-target path (all author-correctable content failures, including broken wiki-links and link-audit failures, keep the watcher alive instead of exiting). Pinned end-to-end by `zig build test-watch-json-contract` and documented in the [watch-mode contract](/docs/contracts/watch-mode.md).
- `boris-editor` now documents and pins its subprocess contract: exactly one `BORIS_EDITOR_URL=http://127.0.0.1:<port>/#token=<32 hex chars>` line on stderr after bind, `--port 0` (default) reporting the bound port, the token in the URL fragment (or the `x-boris-editor-token` header for API calls), and an unchanged loopback/token/`Host`/`Origin`/CSP posture. `SIGINT` and `SIGTERM` now stop accepting, close the listener, and exit `0` — the same shutdown contract as `boris watch` — so embedders treat an uncaught-signal termination as cancel rather than crash. Pinned by the editor host test and documented in the [editor README](/editor/README.md).
- `boris validate --watch` starts a zero-write validation daemon (issue #647): the same debounced watch coordinator as HTML watch mode re-runs the `validate` preflight on every change and writes nothing — no target, cache, search, or evidence trees ever appear. `--watch-json` carries each cycle on the NDJSON event stream with `mode` `"validate"` and `pages_written` `null`, and `--report PATH` is replaced (never appended) every cycle. `--html-dir`, `--target`, `--serve`, and `--port` are usage errors with it; the daemon exits `0` on SIGINT/SIGTERM. Pinned by the extended `zig build test-watch-json-contract` and documented in the [watch-mode](/docs/contracts/watch-mode.md) and [validation](/docs/contracts/validation.md) contracts.
- `boris-editor` accepts an optional `open=<project-relative path>` fragment parameter on its launch URL; the shell opens that author-owned file on launch (unsafe paths are ignored with a status message, missing files surface the host's `file_not_found`, and the editor still boots to the project file list). See [the editor launch contract](/editor/README.md) and [issue #649](https://github.com/drawmeanelephant/boris/issues/649).
- The editor host adopts `boris validate --watch --report` as a long-lived validation daemon per project (issue #652): when the installed compiler accepts `--watch`, the first validate demand spawns one zero-write daemon (`validate --input content --report .boris/html-build-report.json --watch`, with `--cooklang` on Cooklang trees) and `/api/commands/run` validate serves the newest report instead of spawning a compiler subprocess per request. The host watches the report file (mtime + size), maps each cycle's `ok` to the one-shot outcome convention (0 success / 1 content failure), reaps unexpected daemon deaths non-blockingly and recovers with bounded exponential backoff, and SIGTERMs the daemon on host exit (no orphans). `GET /api/validate-state` exposes `{supported, state, cycle, failure_class, problems_count}` and `/api/version` advertises `supported.validate_watch`; the shell polls the cycle counter and refreshes the problems surface only when the daemon rewrites the report. Compilers without `--watch` keep the byte-identical one-shot validate path. Pinned by the new `editor/scripts/test-validation-daemon.sh` host integration and the Playwright suite; documented in [editor/README.md](/editor/README.md).
- The editor Problems section names the live validation state from the `validate-state` channel (issue #654): the shell renders the daemon's last reported `idle` / `running` / `success` / `failed` / `stale` state verbatim (`Validation passed (cycle N).`, `Validation failed — N problem(s) (cycle N).`, `Validation daemon is restarting with backoff.`, …) and, when the open buffer is dirty, notes that the shown problems reflect saved files rather than the unsaved buffer. Host and compiler are unchanged — the labels come only from the `GET /api/validate-state` payload, so no daemon state is fabricated, and shells against a compiler without `validate --watch` show no daemon labels. Pinned by the Playwright suite; documented in [editor/README.md](/editor/README.md).
- While the open buffer is dirty, the editor marks a problem **possibly stale** when the caret sits on a line whose text changed since the report, in both the Problems pane and the Source pane's inline problem list ([#660](https://github.com/drawmeanelephant/boris/issues/660)).
- The editor's per-problem "possibly stale" mark now also covers **line-number drift** (#662, follow-on to #660): when the open buffer's line count changed and the first divergence from `baseline` sits strictly above a problem's line, the problem is marked possibly-stale even when the text at its reported line is unchanged (adjacent identical lines, so a deletion above slides the others into place). Deleting a line below never marks, and a pure modification above (line count unchanged) still never marks; the mark still clears on caret move or save. The rule is the documented approximation from [#662](https://github.com/drawmeanelephant/boris/issues/662): identical-line insertion above stays ambiguous from text alone. Shell-only — no host or compiler change. Pinned by two new Playwright cases (delete-above marks, delete-below never marks) alongside the existing A20 cases. See [the editor README](/editor/README.md).
- `boris-testdata` gains a `bounded-nav-v1` profile (and an optional `"nav"` profile field) whose generated theme bounds per-page navigation to breadcrumb plus direct children, keeping scale-corpus anchors and memory flat as page count grows. See the [testdata generator](/tools/testdata-generator/README.md) and [#729](https://github.com/drawmeanelephant/boris/issues/729).
- Unchanged incremental builds now reuse the committed publication-evidence reports under a strict digest gate instead of re-deriving them, and `--refresh-evidence` forces full re-derivation on demand. The reuse gate now also pins the compiler identity (`compiler_id`), so an upgraded binary automatically rejects stale evidence from a prior version. See [publication-checks](/docs/contracts/publication-checks.md#incremental-evidence-reuse) and [#728](https://github.com/drawmeanelephant/boris/issues/728).
- Layouts may write `{{nav depth=N}}` (N ≥ 1) to cap the site-nav forest at N rendered levels (level 1 = root Trunks), keeping per-page nav bytes and memory bounded on large sites; plain `{{nav}}` stays unbounded and malformed depth arguments fail layout load with `ELAYOUTNAVDEPTH`. See [the templating contract](/docs/contracts/templating-and-themes.md) and [the HTML output contract](/docs/contracts/html-output.md).
- Added the additive `boris --build-info` provenance query: one JSON line on stdout pairing the base compiler id with the VCS revision baked in at build time (`-Dvcs-revision` override; `.dirty` suffix; empty without git), so two builds of the same version are distinguishable without touching `--version`, exit codes, or artifact schemas. The HTML-path [`--report`](/docs/contracts/diagnostics.md) document mirrors the token as its additive `vcsRevision` field. See [the CLI contract](/docs/contracts/cli.md).
- Every standalone binary now answers `--version`/`-V` with a single `<tool>/<release>` id line on stdout and exit 0, mirroring the main compiler's `--version` contract ([#787](https://github.com/drawmeanelephant/boris/issues/787)): `boris-package`, `boris-source-rag`, `boris-content-audit`, `boris-search-index`, `boris-docs-maintenance`, `boris-migration-lab`, `boris-testdata`, and `boris-github-pages-audit`. Previously each printed a different unknown-flag error (or a bare usage dump with exit 1), so kit consumers had no uniform version probe; two of the three binaries shipped in agent kits were affected. Help text lists the new flag, and the flag wins position-independently over malformed option values where the tool already gave `--help` that precedence.
- The Boris Editor validation status now shows the daemon's newest completed cycle and live report age beside its existing state label, with an honest missing-age marker before the first report. The read-only state channel and shell behavior are documented in [the editor guide](/editor/README.md).
- `boris standard-site records --profile PATH [--out PATH]` dumps the full canonical Standard.site record payloads (publication + eligible documents, including each document's complete `textContent`) as `boris-standard-site-records` (schema v1). It shares the compile + projection pipeline with `plan`/`publish` and is fully offline: no discovery, OAuth, transport, or mutation. Byte-identical output for identical inputs. See the [Standard.site target contract](/docs/contracts/standard-site.md).
- `boris standard-site records --profile PATH [--out PATH]` dumps the full canonical Standard.site record payloads (publication + eligible documents, including each document's complete `textContent`) as `boris-standard-site-records` (schema v1). It shares the compile + projection pipeline with `plan`/`publish` and is fully offline: no discovery, OAuth, transport, or mutation. Byte-identical output for identical inputs.
- `boris standard-site verify --profile PATH [--dist DIR] [--out PATH]` cross-checks the built output against the freshly rendered projection offline: each eligible page's `site.standard.document` head link and the well-known file (or its base-path sideband) are compared byte-for-byte. Missing or mismatched surfaces fail with exit code 8 and zero writes; the result is a deterministic `boris-standard-site-verify` (schema v1) artifact. See the [Standard.site target contract](/docs/contracts/standard-site.md).
- `boris standard-site verify --profile PATH [--dist DIR] [--out PATH]` cross-checks the built output against the freshly rendered projection offline: each eligible page's `site.standard.document` head link and the well-known file (or its base-path sideband) are compared byte-for-byte. Missing or mismatched surfaces fail with exit code 8 and zero writes; the result is a deterministic `boris-standard-site-verify` (schema v1) artifact. No discovery, OAuth, transport, or mutation.

### Changed

- Incremental HTML builds no longer expand the dirty set with nested linear scans. `cache.NodeLookup` indexes entity ids and source paths once, and `expandDirtySet` resolves affected pages through hash lookups instead of scanning every page per affected id. Behaviour is unchanged; the previous path was quadratic in page count on builds where many pages are dirty. Measured ~5% faster on a cold 5k- and 10k-page incremental build.
- Documented the stable `build`, `check`, `impact`, and `watch` command surface; explicit `build` and `watch` spellings preserve the existing watch-flag compatibility path. The documentation-intelligence report is versioned with graph nodes, typed edges, source locations, and diagnostics. See the [CLI contract](/docs/contracts/cli.md) and [documentation-intelligence contract](/docs/contracts/documentation-intelligence.md).
- Migration-lab relationship evidence now recognizes the proven `{ slug: ... }` shape for `relatedHaiku` and `relatedLimerick` while preserving other object shapes as review-only. See [`tools/migration-lab/README.md`](/tools/migration-lab/README.md).
- Polished the default dogfood documentation layout with a responsive reading column, bounded navigation rail, accessible page hierarchy, and improved table/code presentation; the closed HTML layout markers remain unchanged. See [the HTML output contract](/docs/contracts/html-output.md).
- Allow deterministic multi-level documentation hierarchies: roots remain Trunks, every direct child remains a Satellite, and recursive navigation/RAG output now follows validated parent chains ([graph contract](/docs/contracts/ir-schema.md)).
- Advanced the working product and compiler identifier to **v0.8.1 candidate** while preserving base IR `0.2.0` and the historical erroneous v0.8.0 tag for release-owner recovery context. See the [IR contract](/docs/contracts/ir-schema.md).
- Made the [Instagram migration lab](/tools/migration-lab/README.md) copy unchanged media bytes to deterministic human-named theme assets, bounded compiler-safe page titles and local archive links, while retaining original Instagram URIs in provenance and reports.
- Align migration reports with Boris's eight-key frontmatter grammar and add deterministic field dispositions, hierarchy decisions, explained entity kinds, and bounded MDX component classifications. See [`tools/migration-lab/migration_semantics.zig`](/tools/migration-lab/migration_semantics.zig).
- Updated the [binary handoff routine](/scripts/agent-pack.sh) to discover and package every standalone tool build, including the scale-smoke harness.
- Clarified and verified arbitrary finite Trunk/Satellite parent chains across graph navigation, IR, HTML, and RAG outputs ([graph contract](/docs/contracts/ir-schema.md)).
- `boris-testdata run` and `republish-clean` now accept `--jobs N` (default `1`, valid range `1..64` matching Boris; both `--jobs N` and `--jobs=N` forms are accepted) and pass the requested worker upper bound to Boris as `--jobs N`. Zero, out-of-range, empty, malformed, duplicate, and missing values are rejected deterministically, and `generate`, `validate`, and `inspect` reject `--jobs` as a usage error.
- Run evidence moved to `boris-testdata-run/5` with a structured `execution.requestedJobs` record and no longer repeats the legacy flat `artifactInventorySha256`/`artifactInventoryFileCount` and `outputSnapshotSha256`/`outputSnapshotFileCount` fields. `republish-clean` evidence moved to `boris-testdata-republish-clean/2` with the same structured worker request.
- Added determinism tests proving publication bytes and recorded evidence are identical across worker counts (jobs 1/4/8), including a normalization helper that replaces only `execution.requestedJobs` before comparing parsed evidence.
- `generator.runFixture` and `generator.republishCleanFixture` now validate the requested worker bound through a shared `generator.validateJobs` before deleting output trees, spawning Boris, or writing evidence; out-of-range values return `error.InvalidJobs`. The CLI parser delegates to the same validator.
- The Boris subprocess argument vector is constructed by the shared `generator.buildBorisInvocation` helper, and tests assert the exact `--html-dir <path> --jobs <decimal requested value> --quiet` sequence for jobs 1, 4, and 64 plus that the recorded evidence value equals the value placed in the vector.
- `-h`/`--help` genuinely wins regardless of argument position or malformed/missing `--jobs` values; the parser honors help before validating anything else.
- Improved the deterministic Proof Pack `index.html` presentation: sections and navigation now follow the reading order Summary → Claims → Limitations → Findings → Checks → Artifacts → Relationships → Inputs (Claims and Limitations lead after the summary), the artifact inventory, relationship node inventory, and each relationship edge group collapse behind native `<details>` with exact-count summary labels while claims, limitations, findings, checks, summary, and input bindings stay fully visible, and each of the six closed edge kinds gains one brief human explanation beside its group. The embedded bounded CSS adds long-path/digest wrapping, horizontally scrollable wide tables, narrow-viewport behavior, stronger section hierarchy, and explicit print rules that expose closed `<details>` content and unclip wide tables, per the [publication proof pack contract](/docs/contracts/publication-proof-pack.md). The `proof-pack.json` bytes are unchanged.
- Removed obsolete frontmatter and historical harness modules; the active fuzz suite now exercises the authoritative `src/parser.zig` implementation. See the [frontmatter contract](/docs/contracts/frontmatter.md).
- Corrected the [templating-and-themes contract](/docs/contracts/templating-and-themes.md) to defer frontmatter authority to the canonical eight-key frontmatter contract instead of the obsolete five-key summary.
- Updated the accepted layout RFC and migration-lab guidance to reference the current grammar and the final Boris-parser gate for generated candidates.
- Product RAG now defaults to bounded, site-only working-context packs that preserve Boris-authorable Markdown and keep integrity metadata in a non-upload sidecar; use `--rag --complete` for the explicit full-corpus export. See the [RAG export contract](/docs/contracts/rag-export.md).
- Gate Greptile reviews behind the opt-in [`run-trex` label](/greptile.json), using a label-only workflow and a manual `@greptileai` trigger while automatic update and draft reviews remain disabled.
- Common published local links now use a caller-owned route-resolution fast path, while escaped and normalized references retain the existing slow path. See the [documentation-links contract](/docs/contracts/documentation-links.md).
- Build the IR reverse dependency index in one edge pass while preserving the sorted, deduplicated [`graph.json` reverseIndex](/docs/contracts/ir-schema.md#reverse-dependency-index) bytes.
- Made complete-corpus RAG hierarchy rendering linear in the frozen graph size while preserving deterministic [`graph/relations.md`](/fixtures/expected/rag/graph/relations.md) bytes; see the [RAG export contract](/docs/contracts/rag-export.md).
- Build the `llms.txt` parent-to-children index once per export while preserving deterministic hierarchy output and the existing [llms.txt contract](/docs/contracts/llms-txt.md).
- Boris now consumes Oliver's Cooklang stack as a **second, separately pinned Oliver dependency** (`.oliver_cooklang`, Oliver `main`) while the renderer stays pinned to the `boris-markdown-extensions` branch. The two feature sets live on different Oliver revisions while [oliver#39] is embargoed; when it merges, the dual pin collapses to one and `.oliver_cooklang` is deleted. See [the Oliver renderer contract](/docs/contracts/oliver-renderer.md).
- The in-tree Cooklang adapter is gone: Boris now parses `.cook` bodies with Oliver's Cooklang stack (pinned as `.oliver_cooklang`) and renders/validates through the seam in [`src/cooklang_seam.zig`](/src/cooklang_seam.zig) — there is deliberately no second parser in Boris. Malformed structure (an unclosed `{`, `(`, or `[-`, or a body-only frontmatter fence) now **degrades to literal text with a structured warning** instead of failing the build with `ECOOKLANG`, matching Oliver's documented behavior; refusals are limited to what protects published output (control characters, invalid recipe references, empty timers or sections, and the IR bounds). See [the Cooklang compatibility contract](/docs/contracts/cooklang-compatibility.md) and [the Oliver renderer contract](/docs/contracts/oliver-renderer.md).
- Cooklang structural warnings (an unclosed `{`, `(`, or `[-`) print exactly once on the HTML path instead of twice: the load-time validation pass — the only pass that runs once per build and covers every page, including the cache-reused pages an incremental build skips at render time — is the only printer. The exact stderr for both the pipeline and HTML paths is now pinned in [the Cooklang compatibility contract](/docs/contracts/cooklang-compatibility.md), including the real Oliver code for an unclosed preparation (`unclosed-preparation`, not the previously documented `unclosed-paren`) and the rule that a bare `(` in prose is not a construct and stays silent.
- The GitHub Pages guide now states the `.nojekyll` policy explicitly: artifact-based `deploy-pages` uploads are served as-is and never need the marker, because Jekyll processing applies only to branch-based publishing. See [`docs/github-pages.md`](../github-pages.md).
- New black-box regression step `test-cooklang-incremental-warnings` (part of `zig build test`) pins the warning-printing contract: Cooklang structural warnings print exactly once on the plain HTML, IR, and incremental HTML paths — including the no-change incremental rebuild whose cache-reused pages skip render entirely. See [`scripts/test-cooklang-incremental-warnings.sh`](/scripts/test-cooklang-incremental-warnings.sh).
- The reference-theme example is now guarded by a black-box test (`zig build test-reference-theme-layout`, part of `zig build test`): it builds with the layout rules in both declaration orders and asserts the documented `data-layout` winners on every page, byte-identical output trees, and the published theme/page-local assets. The layout-rule precedence contract (fixed rank, order-independent) can no longer drift silently.
- The [editor](/content/guides/editor.md) names open-project, save, preview, command, and completion-refresh waits and says how long they took ([#418](https://github.com/drawmeanelephant/boris/issues/418) M11).
- The version query + artifact provenance recipe is now guarded by a black-box test (`zig build test-version-pin`, part of `zig build test`): `boris --version` / `-V` must print exactly the base compiler id from `src/pipeline.zig`, real artifact sets (plain, Cooklang, and semantic-relations corpora) must record the base or a `+`-suffixed variant id in `manifest.json` and `completion.json`, and a tampered recorded id is rejected. The documented pin example in `docs/contracts/cli.md` must track the compiler id, so the recipe can no longer drift silently from the executable behavior.
- The `zig build test-doc-links` guard now walks every authored Markdown file under `docs/` (contracts, audits, dogfood, changelog.d, top-level docs) instead of just the README and authoring spine, so internal links rot loudly repo-wide. The first full-tree run surfaced and fixed real rot (a broken Trunk/Satellite anchor in `MIGRATION.md`, a deleted `src/cooklang.zig` reference, and a changelog.d-relative contract link); generated evidence code maps and fixture test data are skipped by design.
- The `zig build test-doc-links` guard's whole-tree and link-level exclusions moved into an explicit manifest ([`scripts/doc-links-exclusions.txt`](/scripts/doc-links-exclusions.txt)) with a comment per entry, and the guard fails hard on a missing or unparseable manifest — future exclusions are deliberate, reviewed acts rather than silent blind-spot widening. Also restored reference-style link checking on macOS CI (`\S` → POSIX character class).
- Hardened the in-repo RFC-6455 client and its conformance evidence:
- The publish transport now owns its socket reader/writer and TLS state in one heap box (`ws_client.TlsBox`). `std.crypto.tls.Client` stores `*Reader`/`*Writer` pointers to the socket interfaces inside itself, and `connect` returns the client by value; without the box those pointers dangled into the dead stack frame the moment `connect` returned, so every post-handshake `wss://` read operated on stale memory (observed as a spurious `ReadFailed` on the first frame read). The fix is a stable box the client value points at; the plain `ws://` path and all plaintext matrix scenarios were already green and stay green.
- Added seeded parser fuzz coverage: `encodeFrame`/`parseFrame` round-trip with random opcodes, lengths, mask bits, and fragmentation flags, plus a hostile "fuzz stream" matrix scenario that feeds random bytes to the client's frame reader and asserts it fails closed without a hang or crash.
- Added a real `wss://` end-to-end conformance test: a TLS mock relay (`scripts/nostr-mock-relay-tls.py`, Python `ssl`) bound to loopback, pinned by committed self-signed test credentials (`docs/contracts/fixtures/nostr-publication/tls/`, RSA-2048 leaf for the system Python's TLS 1.2-only LibreSSL). The positive test asserts the full publish round-trip completes over TLS; the negative test pins the same CA but connects to `127.0.0.1` and asserts hostname verification fails closed (`TlsFailed`).
- Hardened the write side of the in-repo RFC-6455 client and its conformance evidence:
- `sendText` now fragments outgoing text messages larger than `limits.max_fragment_bytes` (default 64 KiB) on the wire: an initial text frame with FIN clear, then continuation frames, the last with FIN set — RFC 6455 §5.4 requires every server to accept fragmented client messages. Control frames are never fragmented, and the message ceiling (`max_message_bytes`) and frame ceiling (`max_frame_payload`) still bound both directions.
- The frame encoder now emits the 8-byte extended-length form for payloads at or above 64 KiB (the `127` form was dead code behind a `maxInt(u16)` guard), matching the parser's 64-bit length handling.
- Added write-side fuzz coverage: a recording mock relay drives random payloads and fragmentation patterns (fragment sizes 1 through 65536, payload lengths across every length-encoding boundary) through `sendText` over a real loopback socket, and asserts what a server would receive — mask bit, FIN sequence, length codes, and the unmasked payload — is byte-exact against what was sent.
- Added a write-deadline conformance test: a relay that completes the handshake and then stops reading forces the client's flush to block; the per-write deadline must interrupt it mid-flush and surface `WriteTimeout` instead of hanging.
- The conformance mock relays (in-repo and the Python TLS relay) now reassemble fragmented client messages, as a conforming server must.
- First-tester Standard.site CLI polish: `sessions` prints DID, credential flavor, and PDS; `logout` accepts `--handle`; `smoke` without a stored session says to log in first; family usage errors print the family list instead of global help. See the [sessions contract](/docs/contracts/atproto-sessions.md) and issues [#529](https://github.com/drawmeanelephant/boris/issues/529), [#530](https://github.com/drawmeanelephant/boris/issues/530), [#540](https://github.com/drawmeanelephant/boris/issues/540), [#541](https://github.com/drawmeanelephant/boris/issues/541), and [#534](https://github.com/drawmeanelephant/boris/issues/534).
- Pinned Oliver to `d742494` (oliver#77) and collapsed Cooklang string scaling onto the library `classifyQuantity` / `scaleAmount` path. Mixed `1 1/2` stays scalable; leading zeros and `=` locks follow Oliver. [the Cooklang contract](/docs/contracts/cooklang-compatibility.md), [the Oliver pin](/docs/contracts/oliver-renderer.md).
- Fallback [`ILAYOUTSELECTED`](/docs/contracts/diagnostics.md) findings now emit only when the target has layout rules, so rule-less sites stay silent ([#557](https://github.com/drawmeanelephant/boris/issues/557)).
- HTML `--report` now emits an informational [`ILAYOUTSELECTED`](/docs/contracts/diagnostics.md) finding for fallback and default layout winners as well as rule-selected pages ([#557](https://github.com/drawmeanelephant/boris/issues/557)).
- Frontmatter accepts the closed Cooklang `servings` count (`serves` / `yield` are aliases). `boris recipe-scale --servings N` scales by `N / current` (missing current is 1). Every other Cooklang metadata name stays `EFRONTMATTER` ([#598](https://github.com/drawmeanelephant/boris/issues/598), [frontmatter](/docs/contracts/frontmatter.md), [Cooklang](/docs/contracts/cooklang-compatibility.md)).
- The [editor](/content/guides/editor.md) completion filter takes focus after a category change, and diagnostic packet buttons show a brief Copied! while keeping their full accessible name ([#615](https://github.com/drawmeanelephant/boris/issues/615), [#616](https://github.com/drawmeanelephant/boris/issues/616)).
- Collapsed Boris's two Oliver dependencies into one: the Markdown renderer extensions and the Cooklang stack now share a single `.oliver` pin at Oliver `main` `c0b3d2b` (oliver#39 merged, embargo lifted). The `.oliver_cooklang` split dependency (previously `bcf167fa`) is deleted; `cooklang_seam.zig` imports the shared module as `oliver`. The Cooklang seam therefore also absorbs the oliver#55/#56 audit fixes (scaling div-by-zero guard, NUL → U+FFFD in the HTML renderer). Pin table: [oliver-renderer.md](/docs/contracts/oliver-renderer.md).
- Re-pinned the Markdown renderer dependency (Oliver) from `872b002` to `42cf472` on the `boris-markdown-extensions` branch. The move absorbs the branch's rebase onto current Oliver `main` and fixes repeated footnote references: each `[^label]` occurrence now gets a unique `fnref-N` / `fnref-N-2` id with one backref per reference instead of duplicate ids. Boris's seam error set gained Oliver's `RawHtmlNotXmlWellFormed` member (structurally unreachable under the HTML profile; tracked for exact surface parity). Pin table: [oliver-renderer.md](/docs/contracts/oliver-renderer.md).
- `standard-site login --app-password` now suppresses terminal echo while the app password is typed, restoring the terminal attributes even on failure, so the credential never lands in scrollback. Interactive input reads exactly one line; piped secret files still read to end of stream, and empty input is rejected on both paths.
- Standard.site is now a first-tester surface: `boris standard-site` prints the family list instead of "unexpected argument", `smoke` accepts `--handle`, and the operator path lives at [docs/standard-site.md](/docs/standard-site.md). Browser OAuth is still documented as failing closed on bsky.social; the working live path is `login --app-password`. See the [CLI contract](/docs/contracts/cli.md) and the [live smoke contract](/docs/contracts/atproto-live-smoke.md).
- Added keyboard- and pointer-conformance sweeps that walk every editor dialog, the command palette, and the completion combobox, asserting each visible key hint still performs its action across recovery, deleted-conflict, reopen, filter-reset, and path-input variants ([#462](https://github.com/drawmeanelephant/boris/issues/462)).
- Added a static key-hint conformance lint for the editor UI as its own fast CI lane, extended across dialog close paths, palette state, resolution pending state, and surface state machines — closing real gaps where Esc or a success path left stale conflict state or half-typed paths behind ([#462](https://github.com/drawmeanelephant/boris/issues/462)).
- `boris standard-site` OAuth now requests granular repository scopes (`atproto repo:site.standard.document repo:site.standard.publication`) instead of the `include:site.standard.authFull` permission set, which public providers do not grant. Granular permissions are implemented on bsky.social and the self-hosted PDS distribution, so the browser-OAuth path can be verified by the live smoke rather than blocked by a provider scope gap. Contracts updated: [`atproto-oauth.md`](/docs/contracts/atproto-oauth.md), [`atproto-sessions.md`](/docs/contracts/atproto-sessions.md), [`atproto-live-smoke.md`](/docs/contracts/atproto-live-smoke.md), [`atproto-app-password.md`](/docs/contracts/atproto-app-password.md), [#531](https://github.com/drawmeanelephant/boris/issues/531).
- Clarified that an editor startup preview backed by existing `dist/` output is from an earlier build and must be refreshed, without falsely reporting the output as current. See the [editor preview guide](/editor/README.md) and [issue #617](https://github.com/drawmeanelephant/boris/issues/617).
- The IR `build-report.json` now records compiler identity under `compiler` (immediately after `schemaVersion`), identical to `manifest.json`'s value on the same run and written on both success and content-failure paths, so a tool reading diagnostics can attribute them to the exact compiler that produced them. Field names stay per-artifact (`compiler`, `compiler_id`, `compilerId`) and are now documented; `graph.json` remains identity-free by design. Links: [IR schema](/docs/contracts/ir-schema.md), [CLI contract](/docs/contracts/cli.md), [#638](https://github.com/drawmeanelephant/boris/issues/638).
- The workspace-containment rule is now specified, not discovered: every output tree (HTML, IR, RAG, context, `llms.txt`) is confined to the process cwd with a path-component boundary check, violations fail `WorkspaceEscape` (exit 2), and the workspace root / content root are `TargetOutputCollision`. Absolute output paths resolve inside the workspace are accepted uniformly across exporters — there is no IR-specific absolute-path rejection — and single-file `--report` outputs plus `--input` remain unconstrained. Pinned by unit tests and documented in the [CLI contract](/docs/contracts/cli.md).
- The editor's validation feedback now follows the newest save: a validate demand within 3 s of a save waits for the daemon's save-triggered cycle, and successful saves fire a debounced problems refresh, so results answer from after the change. See [the editor guide](/content/guides/editor.md).
- Removed the retired `repro/420` regression canary ([#420](https://github.com/drawmeanelephant/boris/issues/420)); the Touch Atlas streaming-checks parse bug it guarded is fixed on `afterparty` (the harness now exits with the expected *"did NOT reproduce"* result), and it was unwired from CI, so the dead canary no longer ships in the repository.
- Segmented the Boris Editor's 2542-line `App.svelte` monolith into scoped lib modules, components, and dialogs across six slices, ending at a ~250-line orchestrator with zero template or stylesheet change, stable ids, and green e2e gates throughout ([#670](https://github.com/drawmeanelephant/boris/issues/670), [editor README](/editor/README.md)).
- Dependency resolution builds its doclink source→node map once per pass via the shared #726 seam instead of rebuilding it for every page, removing an accidental O(pages × nodes) from the sequential pre-pass (~25× on a 5,000-page corpus; output bytes identical). Documented the measured scope and Amdahl ceiling of `--jobs N` page-render parallelism. Links: [parallel-rendering contract](/docs/contracts/parallel-rendering.md), [#731](https://github.com/drawmeanelephant/boris/issues/731).
- The HTML compile path builds its wiki and documentation-link node maps once per render pass instead of once per rendered page, making large-site builds measurably faster with byte-identical output. See [#726](https://github.com/drawmeanelephant/boris/issues/726) and [#732](https://github.com/drawmeanelephant/boris/pull/732); behavior is pinned by the shared-map equivalence test in [wikilink](/src/wikilink.zig).
- The incremental fingerprint pass builds its wiki node map once per build and folds a fixed-size digest of the site nav material into each page fingerprint, making large graph-chrome builds measurably faster. Fingerprint composition changes with cache format `boris-cache-v3-nav-digest`; older caches force the documented one-time cold rebuild. See [html-output](/docs/contracts/html-output.md) and [#727](https://github.com/drawmeanelephant/boris/issues/727).
- Unknown layout markers now fail with a dedicated `ELAYOUTUNKNOWNMARKER` diagnostic whose remediation enumerates the full closed marker set (eleven slots plus `{{asset-url PATH}}`) and states the once-per-layout rule. Contract table updated in [diagnostics](/docs/contracts/diagnostics.md) ([#737](https://github.com/drawmeanelephant/boris/issues/737)).
- `status: draft` pages on the default HTML target are now emitted but no longer advertised: `{{nav}}` prunes draft-rooted subtrees, `{{children}}` omits draft children, and the site-nav fingerprint material includes status so incremental rebuilds stay correct. Drafts keep rendering at their routes so links resolve; `archived` stays advertised. See [the HTML output contract](/docs/contracts/html-output.md).
- `html-build-report` 0.2.0 adds an optional `proofPack` section to `--report PATH`: when the build committed target evidence, the report mirrors per-check verdicts (`allPassed`, `checks[]`) from `_boris/proof/checks.json`, so CI sees check failures in the same file it already parses. Contract updated in [diagnostics](/docs/contracts/diagnostics.md); schema: [schemas/html-build-report-0.2.0.schema.json](/docs/contracts/schemas/html-build-report-0.2.0.schema.json) ([#741](https://github.com/drawmeanelephant/boris/issues/741)).
- Failed publication checks now print a stderr warning naming the check, the target, and where the per-finding evidence lives (`_boris/proof/checks.json` `findings[]`), visible even under `--quiet`; a failing check still never fails the committed target by design. See [publication-checks](/docs/contracts/publication-checks.md) ([#740](https://github.com/drawmeanelephant/boris/issues/740), [#741](https://github.com/drawmeanelephant/boris/issues/741)).
- `EREFERENCEMISSING` now appends a did-you-mean suggestion when a near-matching page entity id exists (for example, `[[nested/child]]` suggests `"deep/nested/child"`); suggestions are deterministic and never fire for unrelated targets. See [documentation-links](/docs/contracts/documentation-links.md) and [#742](https://github.com/drawmeanelephant/boris/issues/742).
- `boris-recipe-scale` view 0.2.0 marks every timer entry `"scaling": "locked"`, so an unchanged scalable timer amount is a visible, self-describing policy (cooking time does not scale with yield) instead of reading as a bug. Contract and goldens updated in [cooklang-compatibility](/docs/contracts/cooklang-compatibility.md) ([#743](https://github.com/drawmeanelephant/boris/issues/743)).
- Large HTML builds audit links up to ~10× faster: the output link audit's route resolution now normalizes dot-segment, query-suffixed, and root-relative references in caller-owned scratch instead of allocating per reference, and its resolution buffer is reused per document rather than re-poisoned per reference; published bytes are unchanged. [timings counters](/docs/contracts/cli.md), issue #759.
- Unsafe content-local SVG diagnostics now say `(file not referenced by any page)` when the offending file's path appears nowhere in the owning page's source, distinguishing dead files from live ones; the discovery-time whole-sibling-tree sweep is now stated in the [content-local assets contract](/docs/contracts/content-local-assets.md). Fail-closed behavior and exit codes are unchanged. Issue #765.
- `{{include}}` fragments are read and expanded once per build and shared across consuming pages instead of once per page, cutting duplicate file reads on sites with shared chrome fragments (#760). The `--timings` `include_reads` counter now reports unique fragment reads per build.
- An HTML target whose content root scans to zero pages still publishes successfully (proof/search/theme assets, exit 0), but the compiler now prints a stderr warning naming the input root — including under `--quiet` — so an empty or mistyped `--input` can no longer masquerade as a populated site. `--timings` counters were verified honest for such runs (all zeros means no page work happened; [#775](https://github.com/drawmeanelephant/boris/issues/775)); behavior is pinned in [the contract](/docs/contracts/html-output.md).
- The `boris-standard-site-plan` artifact is now self-contained for review: each document entry carries the full `textContent` (the deterministic plain-text projection) alongside its `text_content_sha256` digest, so an operator can read what will be indexed without a second artifact. The digest and all other fields are unchanged; metadata-only documents still emit `null`. See the [Standard.site target contract](/docs/contracts/standard-site.md).
- The `boris-standard-site-plan` artifact is now self-contained for review: each document entry carries the full `textContent` (the deterministic plain-text projection) alongside its `text_content_sha256` digest, so an operator can read what will be indexed without a second artifact. The digest and all other fields are unchanged; metadata-only documents still emit `null`.

### Fixed

- Clarified full-graph context projection metadata, distinguished full and selected relation counts, and made `--bundles-only` indexes, guides, graph notes, catalogs, and chunk provenance self-consistent. See the [context bundle contract](/docs/contracts/context-bundle.md) and [RAG export contract](/docs/contracts/rag-export.md).
- Added the contract-required `continuation` state to segmented RAG `manifest.json` chunk entries, matching `part_manifest.json` ([RAG export contract](/docs/contracts/rag-export.md)).
- Thread explicit `allocator` through `writeHeadingHarvestCache` in [`src/compile.zig`](/src/compile.zig), completing caller-controlled memory allocation across compiler cache serialization helpers.
- Instagram migration-lab JSON captions now repair Meta's escaped Latin-1/UTF-8 form when the result validates as UTF-8, with provenance and regression coverage for multipart exports. See [migration-lab guide](/tools/migration-lab/README.md).
- Instagram migration-lab now refuses media URIs that escape the dump on read or the output root on write (parent traversal, absolute paths, Windows separators, drive prefixes). Such records are classed `human_review` with an explicit rejection note instead of being copied and reported as `exact`.
- Instagram captions are fenced with a backtick run longer than any run they contain, so an untrusted caption can no longer close the fence and inject raw Markdown/HTML into generated pages.
- Instagram caption provenance distinguishes `suspected-mojibake-unrepaired` from `utf-8`: mixed escaped/genuine Unicode and doubly-encoded captions are flagged for review rather than reported as clean. See [migration-lab guide](/tools/migration-lab/README.md).
- `boris-source-rag` now scans the root `fixtures/` tree, which the contracts already describe as part of the fixture corpus but the exporter silently omitted. Adds 90 files to `--profile=all` and `--profile=tools`.
- Hardened RAG, Context, llms.txt, and HTML target publication against content-tree aliasing, workspace escapes, and absolute-path symlink components; incremental HTML now tracks resolved ordinary Markdown links without exporting them as semantic graph edges. See the [documentation-link contract](/docs/contracts/documentation-links.md) and [HTML output contract](/docs/contracts/html-output.md).
- Reject URL-significant entity-id characters, preserve relative links through arbitrarily deep output paths, and bound authoring-source reads before parsing. See the [identity contract](/docs/contracts/identity-and-paths.md) and [frontmatter limits](/docs/contracts/frontmatter.md).
- Preserve structured parser categories and source locations when defensive HTML-path checks reject a page, instead of exposing only a bare parse failure.
- Confined `assemble.scrubStaleAtomicTemps` orphan temp cleanup strictly to the `.boris-cache/` namespace, removing heuristic recursive live-tree deletion so published assets named like `assets/0123456789abcdef` or `assets/worker.tmp` are preserved across failed rebuilds. Links: [HTML output contract](/docs/contracts/html-output.md).
- Hardened source-RAG root/output path handling so normalized nested outputs are excluded and root collisions are rejected. See the [source-RAG guide](/tools/source-rag/README.md).
- Hardened the rendered-site search index CLI with documented flag forms, successful help behavior, duplicate/path/symlink validation, correct output exclusion, CLI coverage, and atomic index publication. See the [rendered search contract](/docs/contracts/rendered-search.md).
- Make migration-lab `link-audit` create its documented output directory before writing reports. See the [migration lab guide](/tools/migration-lab/README.md).
- Search marker detection now matches attribute names instead of raw substrings, so a marker name appearing inside another attribute's value — such as a slugified heading id on a page documenting the markers — no longer registers a second search root, and `aria-hidden="false"` no longer excludes visible content from the index. Links: [the rendered-search contract](/docs/contracts/rendered-search.md).
- Wiki-link, include, and content-asset diagnostics now report the full-source line of the offending construct instead of a line relative to the body, so a reference on file line 9 no longer points at line 4. Links: [the diagnostics contract](/docs/contracts/diagnostics.md).
- Kept matching inline-code spans literal so embedded include directives and wiki-links cannot affect Boris output or dependencies. Links: [includes and wiki-links contract](/docs/contracts/includes-and-wiki-links.md).
- RAG corpus documents now encode page-controlled values for the container they are written into. A `tags` item can no longer close the YAML flow sequence and inject top-level keys such as `category: system` into a document that ships to a knowledge base, and a `title` containing `|` can no longer forge extra columns in the `INDEX.md` and `graph/entity-catalog.md` tables. Output for content without these characters is byte-identical to before.
- Hardened [RSS 2.0 site URL validation](/docs/contracts/rss-2.0.md) and moved RSS XML rendering onto the audited structured emitter path.
- Made the migration-lab WordPress black-box compile proof use the managed [theme layout contract](/docs/contracts/templating-and-themes.md) and isolate its generated test data.
- Make the bounded Filed.fyi migration lab reject invalid UTF-8, BOM-prefixed, malformed, duplicate-key, and unterminated frontmatter instead of emitting plausible pages; keep comments and indentationless sequences review-only; and validate mapped titles before emission. See [`tools/migration-lab/filed.zig`](/tools/migration-lab/filed.zig).
- Support colon-separated relation prefixes in Filed migration scans so canonical Boris `relations` mappings resolve target identities cleanly. See [`tools/migration-lab/filed_scan.zig`](/tools/migration-lab/filed_scan.zig).
- Repaired `boris-testdata` post-publication profile sequencing and asset-gated fixture generation so clean artifact evidence remains distinct from poisoned output snapshots; see the [testdata-generator guide](/tools/testdata-generator/README.md).
- Watch mode now treats a missing include (`error.IncludeFailed`) as a recoverable content failure: the watcher stays alive for author correction, preserves the previously valid published output, and recovers in the same process session instead of exiting. The C06 same-session watch case proves the full lifecycle. Links: [watch-mode contract](/docs/contracts/watch-mode.md).
- Unsafe content-local SVG rejection now exits as a content failure (exit 1) instead of being misclassified as system I/O (exit 3): `AssetUnsafeSvg` maps to the content-error arm of `mapHtmlError`, and the multi-target aggregate classifies it as content, so no generic I/O summary line is printed. All nine rejected SVG constructs stay rejected and uncommitted, and the inert Unicode SVG case is unchanged. Links: [content-local-assets contract](/docs/contracts/content-local-assets.md), [conformance report](/docs/archived/audits/publication-conformance/REPORT.md).
- Unsafe-SVG content errors now also recover consistently in watch mode: an author replacing an inert SVG with an active construct fails as a recoverable content validation error (`error.AssetUnsafeSvg` in `isRecoverableBuildError`) in both the raw single-target and multi-target watch paths, so the watcher stays alive, preserves the prior published HTML and SVG byte-for-byte, and publishes the corrected asset in the same process session. Links: [watch-mode contract](/docs/contracts/watch-mode.md), [conformance report](/docs/archived/audits/publication-conformance/REPORT.md).
- Touch Atlas graph construction (`buildNodesAndEdges` and the expected-graph validation helpers) now releases every completed node ID and edge endpoint allocation when a later allocation fails, so an out-of-memory path is leak-free under a general-purpose allocator. Emitted `touches.json` bytes are byte-identical to the PR #294 first slice; new deterministic failing-allocator tests and a byte-identity golden pin the unchanged output. Links: [publication Touch Atlas contract](/docs/contracts/publication-touches.md).
- `llms.txt` summaries are now truncated at the 240-byte limit only on a valid UTF-8 scalar boundary, so a multibyte character is never split in the emitted file ([`llms.txt` contract](/docs/contracts/llms-txt.md)).
- The Proof Pack `index.html` print rules now target the `details::details-content` pseudo-element with `content-visibility: visible !important` and `display: block !important`, making closed-state HTML print reliably across browser engines that hide the disclosure content container through the UA `content-visibility` default. The existing `details > :not(summary)` rule is retained; the new rule ensures every `<details>` interior renders on paper without JavaScript or DOM modification, per the [publication proof pack contract](/docs/contracts/publication-proof-pack.md).
- [`boris-content-audit`](/tools/content-audit/) closes qualification-contract gaps found by independent black-box testing and Filed dogfooding: the output path is canonicalized and inspected for symlink components identically for absolute and relative `--root`/`--out` combinations; poetry-mode policies now require `eligible_collections` and `poetry_collections` as populated object fields (explicit empty objects remain valid); a closing fence line with trailing text no longer closes a fenced block; unregistered poetry shapes report one malformed/unsupported record consistently across per-record rows, verse totals, alignment, exceptions, and the Markdown/HTML reports; the reproduction command renders `--root=<project-root>`, `--policy=<policy-file>`, and `--out=<output-dir>` placeholders so no absolute host path is emitted; `--collection` filters are canonicalized (deduped, sorted) so reversed argument order is byte-identical; and the terminal summary reports the same scoped source/poetry totals as `report.json`.
- [`boris-content-audit`](/tools/content-audit/) closes the last two qualification gaps: density-band values must fit `u32` (a value above `4294967295` is a malformed policy, exit 4, instead of trapping or truncating), and every caller-controlled value in the reproduction command (`--content-root`, `--revision`, `--collection`, format, fail-on) is emitted with shell-safe argument boundaries — values with spaces, quotes, or shell metacharacters are single-quoted so each survives as exactly one argument in a POSIX shell, while plain values stay byte-identical.
- [`boris-content-audit`](/tools/content-audit/) fixes a deferred-free ownership error in the reproduction-command placeholder substitution used by the shell round-trip test: the intermediate replacement buffers were freed through a reassigned local, so both deferred frees acted on the final buffer while the first leaked. Each intermediate result is now a distinct constant with its own `defer`, making the helper correct under any allocator with an effective `free` (the arena allocator previously masked the error). A regression test runs the helper under the testing allocator, which detects the double free and leak the original code produced.
- Boris check now reports unreferenced_page findings without failing by default, with an explicit --fail-on-unreferenced opt-in for CI; HTML publication also rejects literal local Markdown routes that are absent from the intended output manifest. See the [CLI contract](/docs/contracts/cli.md), [Documentation Intelligence contract](/docs/contracts/documentation-intelligence.md), and [documentation-link contract](/docs/contracts/documentation-links.md).
- Enforced the normalized GitHub Pages origin and base path across generated HTML/public metadata, sitemap, RSS, and location-aware `llms.txt` output; mismatches now fail before publication. Hosted `llms.txt` links use Boris's actual `.html` output routes, and rendered `<base href>` context is audited with the first effective base, including fragment-only and empty references that resolve to a base document. See the [GitHub Pages contract](/docs/github-pages.md).
- Replaced the scanner's linear directory-identity cycle checks with an inode identity set while preserving the documented symlink rejection and cycle precedence. See the [scanner contract](/docs/contracts/scanner.md).
- Semantic-relation target validation now reuses one page-identity index per graph pass, keeping relation-heavy validation near-linear while preserving the existing diagnostics and ordering ([semantic-relations contract](/docs/contracts/semantic-relations.md)).
- Fixes release-safe publication crashes, restores fatal diagnostics under `--quiet`, and keeps public search projections aligned with draft visibility; see the [CLI contract](/docs/contracts/cli.md) and [documentation-link contract](/docs/contracts/documentation-links.md).
- `boris impact <ID>` now accepts flags before the positional target id (`boris impact --quiet ID`), matching the `init [DIR]` flag-ordering fix. Exactly one positional is still enforced, and a missing id (`boris impact` or `boris impact --quiet`) remains a usage error (exit 2).
- Kept Markdown inline code spans literal during content-local image asset rewriting and Aside/Details component tokenization, so `![x](y)`-shaped and `<Tag>`-shaped syntax inside backticks (as in image-syntax and raw-HTML documentation) no longer fails `EASSET` or `ECOMPONENT`. A span is skipped only when a matching equal-length closer exists ahead (mirroring the existing wiki-link and include scanners), so an unmatched backtick cannot suppress scanning for the rest of the document and a line-start fence run cannot close the span state mid-document. Links: [content-local assets contract](/docs/contracts/content-local-assets.md), [components contract](/docs/contracts/components.md).
- The reference-theme example now states the authoritative layout-rule precedence: fixed rank (exact `id:` → most-specific `glob:` → `role:` → fallback), order-independent, with equal-specificity matching globs rejected as ambiguous. This matches the executable behavior, the normative contract in [`templating-and-themes.md`](../contracts/templating-and-themes.md) §4.2, and the static-theme-showcase example; the previous "declaration order; first match wins" claim was incorrect.
- The theme slot contract now states the multiplicity and empty-output rules explicitly: the ten slot markers are single-use (`{{content}}` exactly once), the `{{asset-url PATH}}` helper is **repeatable**, and a slot that is omitted or empty for a page emits no wrapper of its own. The reference-theme and static-theme-showcase example docs teach the same contract their layouts already exhibit. See [`templating-and-themes.md`](../contracts/templating-and-themes.md) §3.
- Layouts that exceed the `{{asset-url}}` / segment bounds now report the real reason: `LayoutTooManyAssetUrls` (max 16 occurrences) or `LayoutTooManySegments` (max 32 total segments), instead of the misleading `LayoutInvalidAssetUrl` / `LayoutUnknownMarker`. Both bounds are now pinned by unit tests. See [`templating-and-themes.md`](../contracts/templating-and-themes.md) §3.
- The [editor](/content/guides/editor.md) probes the open file for external edits, deletes, and permission changes while you work, and retries transient filesystem errors instead of failing the session ([#418](https://github.com/drawmeanelephant/boris/issues/418) M11).
- The [editor](/content/guides/editor.md) names the 8 MiB file bound and 50,000-file list bound instead of a generic failure, and tells you to retry after a terminated Boris process ([#418](https://github.com/drawmeanelephant/boris/issues/418) M11).
- The [editor](/content/guides/editor.md) snapshots unsaved work on the first dirty change and when the tab hides, and names **Restart boris-editor** if the host process stops ([#418](https://github.com/drawmeanelephant/boris/issues/418) M11).
- The [editor](/content/guides/editor.md) no longer paints every project file into the tree and command palette at once: the Project pane shows a bounded window, and a named filter finds the rest ([#418](https://github.com/drawmeanelephant/boris/issues/418) M11).
- The [editor](/content/guides/editor.md) serializes overlapping saves so a second Save cannot race the fingerprint, and one corrupt recovery snapshot no longer hides the valid ones ([#418](https://github.com/drawmeanelephant/boris/issues/418) M11).
- The [editor](/content/guides/editor.md) keeps serving when `graph.json`, `completion.json`, or a Proof Pack is stale or from an unsupported schema, and names Build diagnostics / Build HTML as the replace path ([#418](https://github.com/drawmeanelephant/boris/issues/418) M11).
- The Touch Atlas derivation no longer fails with `InvalidChecksReport` for checks reports whose skipped string values straddle the 64 KiB streaming chunk boundary — the failure previously moved with the report's byte length (a `public`-target report died while the identical `default`-target content parsed). The streaming parser now consumes partial string/number tokens to their completing token instead of treating them as whole values (#420, #417).
- Missing RSS channel metadata now reports the actual missing options (`--site-url`, `--rss-title`, `--rss-description`) instead of a phantom "missing value for --rss" / "--rss-path". The same misdiagnosis class is fixed for `--sitemap` without `--site-url` and a partial `--pages-base-*` trio. Mode flags are never blamed for unknown-option errors that occur after them.
- Scoped context exports no longer print two ambiguous page counts: the bundle log reports the selected pages written under `pages/` and the CLI wrapper reports the full validated graph, with explicit "selected"/"graph" labels.
- The Cozy Corner and Node Tracker example themes no longer use the stylesheet asset URL as the `href` of navigation-like links; those visual-only controls are now explicit `static-control` placeholders, matching the convention Node Tracker already used.
- `boris-editor` now resolves a path-like `--boris` value against the editor's working directory at startup (bare command names still resolve through `PATH`), so the documented relative invocation works and bad paths fail fast. See [the host README](/editor/README.md).
- `boris-content-audit`'s terminal summary now lists exactly the report files emitted for the selected `--format`, instead of always claiming `report.json`, `REPORT.md`, and `site/` (a `--format=json` run no longer overclaims the Markdown and HTML outputs).
- `boris validate` now runs the output link audit in memory over the exact assembled page bytes, so `EROUTEMISSING`, `EROUTEESCAPE`, and `EPUBLICATIONLOCATION` fail validation exactly as they fail compilation — previously `validate` let broken local links and publication-location escapes pass silently while remaining write-free. The audit reuses the shared render/splice path and the same diagnostics reporter as `build` (issue #430), and the validation contract now documents the in-memory audit surface.
- The prototype examples' manual-review notes now match the shipped layouts: the Corporate review documents its real compiled-search integration and static theme/settings buttons instead of claiming a zero-JS design, the Minimalist layout's search input and icon buttons carry accessible names and explicit static markers, and the orphaned copy-button CSS rules were removed from both themes.
- `boris-github-pages-audit` now follows redirects correctly. `resolveRedirect` viewed the scratch buffer **past** the copied `Location` bytes, so the first redirect any audit observed resolved to a corrupt URL (uninitialized memory) and was rejected by the location policy even when the target was inside the declared location — e.g. the canonical no-trailing-slash → trailing-slash 301 on a GitHub Pages base URL, which failed the `rss` check for any feed whose channel link is the site root ([#441](https://github.com/drawmeanelephant/boris/issues/441)). The function also leaked its 16 KiB scratch buffer on every call. Regression tests cover the absolute and relative `Location` forms, and the observer's fixture suite now runs in CI.
- Clicking a [completion option](/content/guides/editor.md) in the editor now only selects it; the explicit **Insert selected completion** action inserts exactly one token, so the select-then-insert workflow can no longer duplicate an inserted completion ([#446](https://github.com/drawmeanelephant/boris/issues/446)).
- Activating the [editor](/content/guides/editor.md) **Skip to workspace** link now moves focus to the workspace landmark and no longer replaces the session-token URL fragment with `#workspace`, so the token stays valid ([#447](https://github.com/drawmeanelephant/boris/issues/447)).
- The publication `checks` evidence phase no longer rescans each page from byte 0 per id/reference: `doctor.scanPage` now advances an incremental (line, column) cursor (O(page length) instead of O(references × page length)), and id-fragment lookups use a binary search over the sorted id list. A 2000-page ReleaseFast build dropped from ~231 s to ~9 s (checks 226.6 s → 3.4 s) with identical `checks.json` output (issue #456).
- Pressing `Enter` in the [editor](/content/guides/editor.md) **Create file** and **Rename file** dialog inputs now submits the dialog's primary action, the same action as activating the visible Create/Rename button; invalid empty paths still refuse to submit ([#459](https://github.com/drawmeanelephant/boris/issues/459)).
- The [editor](/content/guides/editor.md) modal dialogs (Create file, Rename file, Delete file, External changes) now trap keyboard focus while open; Tab and Shift+Tab wrap between the dialog's controls instead of escaping into background panes ([#460](https://github.com/drawmeanelephant/boris/issues/460)).
- The [editor](/content/guides/editor.md) **Delete file** dialog now renders a named placeholder when no file is selected: the confirmation reads "Delete selected file?" and the danger button reads "Delete file" instead of interpolating an empty target with trailing whitespace ([#461](https://github.com/drawmeanelephant/boris/issues/461)).
- The [editor](/content/guides/editor.md) dirty-buffer resolution dialog now also covers running Boris commands and rebuilding the preview: instead of only a status warning, running a command or rebuilding while the active buffer has unsaved changes offers Save & Run / Discard & Run (or Save & Rebuild / Discard & Rebuild) and Cancel ([#462](https://github.com/drawmeanelephant/boris/issues/462)).
- The [editor](/content/guides/editor.md) dirty-buffer resolution dialog now also covers restoring recovered work: clicking Restore while the active buffer has unsaved changes offers Save & Restore / Discard & Restore and Cancel ([#462](https://github.com/drawmeanelephant/boris/issues/462)).
- The [editor](/content/guides/editor.md) no longer locks file navigation when the active buffer has unsaved changes; clicking another file in the Project files sidebar now opens a resolution dialog with Save & Switch, Discard & Switch, and Cancel ([#462](https://github.com/drawmeanelephant/boris/issues/462)).
- The [editor](/content/guides/editor.md) workspace no longer stacks the Problems and Preview panes below the fold on desktop viewports; on screens at least 1280px wide it uses a side-by-side Files | Editor | Preview/Diagnostics layout so authors can edit and verify previews concurrently ([#463](https://github.com/drawmeanelephant/boris/issues/463)).
- Rendered search no longer indexes shared layout chrome (`<nav>`, `<header>`, `<aside>`, `<footer>`) or nested sidebar copy when a page has no declared content root, and honors `data-boris-search-ignore` / `data-boris-noindex` alongside `data-boris-search-exclude`. Links: [the rendered-search contract](/docs/contracts/rendered-search.md), [issue 485](https://github.com/drawmeanelephant/boris/issues/485).
- The editor command palette can be dismissed with Cancel or a backdrop click, secondary dialog actions now carry the same key-hint pattern as cancel/primary, and dismissing a dialog returns focus to the control that opened it. Closed dialogs stay out of the accessibility tree so generic names such as Cancel do not collide ([#464](https://github.com/drawmeanelephant/boris/issues/464), [#525](https://github.com/drawmeanelephant/boris/issues/525), [#526](https://github.com/drawmeanelephant/boris/issues/526), [#527](https://github.com/drawmeanelephant/boris/issues/527)). See the [editor guide](/content/guides/editor.md).
- Nostr publish now records the SHA-256 of the signed-bundle bytes (not a copy of the plan digest), classifies a plain relay `OK false` as `rejected` and a mismatched OK as `wrong-id`, re-verifies reused prior signatures, refuses a bundle whose article set does not match the plan, and rejects incoming WebSocket frames larger than the receive buffer. See the [Nostr publication contract](/docs/contracts/nostr-publication.md).
- OAuth XRPC now sends `Authorization: DPoP <access_token>` and a separate `DPoP` proof header (RFC 9449). The native adapter admits GET 3 / POST 4 headers for that shape. See the [OAuth contract](/docs/contracts/atproto-oauth.md) and [#536](https://github.com/drawmeanelephant/boris/issues/536).
- Standard.site publish no longer requires profile `pds`. Omit it to bind to the PDS discovered from the DID document; if you set it, it must match that origin after parse. See the [Standard.site contract](/docs/contracts/standard-site.md) and [#537](https://github.com/drawmeanelephant/boris/issues/537).
- `boris nostr publish` resolves named relays (`wss://relay.example.org`, `ws://localhost`) through DNS instead of treating the hostname as an IP literal. See the [Nostr publication contract](/docs/contracts/nostr-publication.md) and [#545](https://github.com/drawmeanelephant/boris/issues/545).
- Standard.site login and session reuse now fail closed on four reachable mistakes: handle login requires the DID-document `alsoKnownAs` backlink, empty app-password input is a usage error rather than a fake PDS denial, a corrupt session file is no longer treated as “try the other credential,” and `getRecord` treats HTTP 404 as a missing record. See the [sessions contract](/docs/contracts/atproto-sessions.md) and issues [#547](https://github.com/drawmeanelephant/boris/issues/547), [#548](https://github.com/drawmeanelephant/boris/issues/548), [#549](https://github.com/drawmeanelephant/boris/issues/549), and [#550](https://github.com/drawmeanelephant/boris/issues/550).
- `boris nostr publish` no longer treats a TLS 1.3 `NewSessionTicket` (or a partial ciphertext record) as a failed WebSocket upgrade. `wss://` relays can complete the HTTP 101 handshake. See the [Nostr publication contract](/docs/contracts/nostr-publication.md) and [#552](https://github.com/drawmeanelephant/boris/issues/552).
- Rendered search now keeps table cells and line breaks as separate searchable words, and decodes HTML entities in the `<title>` fallback and heading `fragment` ids so result links match the live DOM. Links: [the rendered-search contract](/docs/contracts/rendered-search.md).
- Example framework themes now mark in-main TOC and sidebar rails with `data-boris-search-exclude`, so repeated kickers such as “On this page” stay out of the search index without changing extractor policy for authored asides. Links: [the rendered-search contract](/docs/contracts/rendered-search.md), [issue 564](https://github.com/drawmeanelephant/boris/issues/564).
- Standard.site publish now accepts a plan whose `inputs.pds_origin` is `null` (profile omitted `pds`) by binding to the session PDS, and planned document tags are owned copies so `renderPlan` cannot use freed page input slices. See the [reconciliation contract](/docs/contracts/standard-site-reconciliation.md) and issues [#580](https://github.com/drawmeanelephant/boris/issues/580) and [#579](https://github.com/drawmeanelephant/boris/issues/579).
- `boris-job-runner build` now succeeds when the process cwd is the filesystem root. The workspace-prefix check in `hasAbsPathPrefix` required a component boundary after the prefix, so with cwd `/` (the container image's runtime environment) every absolute output path was rejected as `WorkspaceEscape`. The root is now a valid prefix for every absolute path, with boundary assertions added. The example container image also ships the default `boris` theme at `/themes/boris` — boris resolves the default layout against cwd — so a content-only source archive builds inside the image instead of failing `ELAYOUT`. See [the container-runner contract](/docs/contracts/cloudflare-container-runner.md) and [#300](https://github.com/drawmeanelephant/boris/issues/300).
- Kept the standalone [`boris-content-audit`](/tools/content-audit/) frontmatter parser aligned with Boris's 128-relation semantic frontmatter contract so valid pages no longer fail the documented structural audit gate.
- The native AT Protocol HTTPS adapter now admits the closed JSON/Bearer request shapes used by `standard-site login --app-password` and XRPC record calls, instead of rejecting them as `UnexpectedRequest` before a socket opened. Live `deleteRecord` accepts the lexicon `commitMeta` object, and live-smoke readback tolerates extra remote keys such as a PDS-injected `$type`. OAuth form+DPoP POSTs and discovery GETs are unchanged. See the [app-password RFC](/docs/contracts/atproto-app-password.md) and the [live smoke contract](/docs/contracts/atproto-live-smoke.md).
- Scoped context and RAG bundle metadata are kept internally consistent: scoped-context graph metadata is documented as intentionally full-graph, bundles-only references no longer dangle after content pages are removed, total-byte split-cap semantics are clarified, and full/selected relation counts are recorded in the manifest. See the [rag-export](/docs/contracts/rag-export.md) and [context-bundle](/docs/contracts/context-bundle.md) contracts and [PR #196](https://github.com/drawmeanelephant/boris/pull/196).
- `boris-source-rag` scan reads are bounded to `--max-bytes + 1`, so oversized source files are skipped without allocating or reading arbitrarily large inputs, with a regression test for oversized source reads. See [PR #220](https://github.com/drawmeanelephant/boris/pull/220).
- The standalone [`boris-docs-maintenance`](/tools/docs-maintenance/) tool preserves source paths while parsing dossier marker regions: it previously retained borrowed marker-path slices after freeing the marker buffer, corrupting source paths and producing false `source_without_dossier` / `dossier_without_source` relationships even for valid fixtures. See [PR #229](https://github.com/drawmeanelephant/boris/pull/229).
- The output link audit scans each tag once (one AttrIter pass collecting href/src/meta content instead of a rescan per attribute name, preserving first-match semantics and emission order) and route resolution takes an identity-decode fast path for targets with no `%` escapes or normalization. A 2000-page ReleaseFast build dropped from ~7.6 s to ~6.2 s, and slow-path route resolution from 194 to 125 ns per resolve, with byte-identical findings. See [PR #465](https://github.com/drawmeanelephant/boris/pull/465).
- `boris-job-runner build` now succeeds when the process cwd is the filesystem root. The workspace-prefix check in `hasAbsPathPrefix` required a component boundary after the prefix, so with cwd `/` (the container image's runtime environment) every absolute output path was rejected as `WorkspaceEscape`. The root is now a valid prefix for every absolute path, with boundary assertions added. The example container image also ships the default `boris` theme at `/themes/boris` — boris resolves the default layout against cwd — so a content-only source archive builds inside the image instead of failing `ELAYOUT`. See [the container-runner contract](/docs/contracts/cloudflare-container-runner.md) and [#300](https://github.com/drawmeanelephant/boris/issues/300).
- Watch mode now treats graph-validation failures (`error.GraphValidationFailed` — duplicate ids, missing/self/cyclic parents, and other hard topology errors) as recoverable content failures, matching `ParseFailed`: the watcher stays alive for author correction, preserves the previously valid published output, and recovers in the same process session instead of exiting. Links: [watch-mode contract](/docs/contracts/watch-mode.md), [#640](https://github.com/drawmeanelephant/boris/issues/640).
- The editor Problems pane now names its empty states — "No validation report yet" versus "No problems in the newest report (cycle N)" — so an unvalidated tree no longer looks identical to a clean one ([#658](https://github.com/drawmeanelephant/boris/issues/658)).
- The [archive-layout audit fixture](/docs/contracts/fixtures/archive-layout-audit/README.md) no longer overflows the page horizontally at phone widths: pages containing a `<table>` rendered up to 145 px wider than a 375 px viewport because the theme's `table { min-width: 32rem }` forced the table past its container and the `overflow-x: auto` sat on the table element itself. The horizontal overflow now lives on the table's parent (`article { overflow-x: auto }`), so the table keeps its readable minimum width and scrolls internally while the page stays fixed — confirmed by the real-browser pass recorded in [BROWSER-REVIEW.md](/docs/contracts/fixtures/archive-layout-audit/BROWSER-REVIEW.md) at 375 / 768 / 1440 px, with `test/archive-layout-audit.sh` still green.
- Fix a SIGABRT in the Starlight migration lab when an MDX body line ends with `</`; the truncated closing tag is now neutralized instead of slicing backwards. See [`tools/migration-lab/starlight.zig`](/tools/migration-lab/starlight.zig) and [#711](https://github.com/drawmeanelephant/boris/issues/711).
- Fix Starlight migration-lab frontmatter parsing so the earliest `---` terminator wins instead of a whole-file CRLF probe; an LF-closed file whose body contains a CRLF horizontal rule no longer swallows the body. See [`tools/migration-lab/starlight.zig`](/tools/migration-lab/starlight.zig) and [#713](https://github.com/drawmeanelephant/boris/issues/713).
- Fix WordPress WXR parsing so an attributed `<item wp:post_id="…">` that precedes a bare `<item>` is no longer skipped; `nextItemSlice` now takes the earliest of the two open forms. See [`tools/migration-lab/wordpress.zig`](/tools/migration-lab/wordpress.zig) and [#714](https://github.com/drawmeanelephant/boris/issues/714).
- Route Starlight and Astro-archaeology migration outputs through the shared owned/staged publication path so a reused or nested `--out` is refused (or replaced only when lab-owned) instead of silently overwriting user files. See [`tools/migration-lab/publication.zig`](/tools/migration-lab/publication.zig) and [#715](https://github.com/drawmeanelephant/boris/issues/715).
- Fix divergent JSON emitters in the migration lab so Starlight, Filed, and link-audit manifests escape all control characters (not just `\t`) and link-audit findings escape quotes/backslashes, keeping machine-readable output valid for hostile hrefs/filenames. See [`tools/migration-lab/starlight.zig`](/tools/migration-lab/starlight.zig) and [#716](https://github.com/drawmeanelephant/boris/issues/716).
- Correct content-audit exit-4 and duplicate-key documentation, classify oversized files before UTF-8 validation, fail closed on unreadable symlink-walk components, free leaked policy arrays, and require path-segment boundaries in docs-maintenance file classification. See [`tools/content-audit/src/frontmatter.zig`](/tools/content-audit/src/frontmatter.zig) and [#718](https://github.com/drawmeanelephant/boris/issues/718).
- `boris check` no longer reports `unreferenced_page` for pages consumed through `{{include}}` composition; an incoming include edge now counts as inbound use. Contract vocabulary and acceptance fixtures updated in [documentation-intelligence](/docs/contracts/documentation-intelligence.md) ([#739](https://github.com/drawmeanelephant/boris/issues/739)).
- Input-family mismatch diagnostics now blame the offending family: a `.cook`-only tree built without `--cooklang` reports `ECOOKLANG` with a `--cooklang` remediation instead of pointing at Textile, symmetrically for `.textile`. See [the scanner contract](/docs/contracts/scanner.md) and [#744](https://github.com/drawmeanelephant/boris/issues/744).
- The standalone `boris-search-index` no longer indexes Boris-owned `_boris/` evidence such as `_boris/proof/index.html`: recursive discovery prunes that subtree, explicit `--pages-file` entries under it fail closed, and the tool's own CLI tests now run in CI. A regenerated or `--check` index over a normal build output therefore matches the in-build index. Links: [rendered-search contract](/docs/contracts/rendered-search.md), [#750](https://github.com/drawmeanelephant/boris/issues/750).
- The rendered-search publication check now treats an emitted `status: draft` page as an ineligible subject instead of reporting a missing search document for intended state. The artifact inventory records per-page advertisement (`"advertised": true/false/null`, optional-on-parse), and the check's eligible subject set mirrors the search producer's own filtered slice while staleness detection stays active. Links: [publication-checks contract](/docs/contracts/publication-checks.md), [publication-artifacts contract](/docs/contracts/publication-artifacts.md), [#752](https://github.com/drawmeanelephant/boris/issues/752).
- Test and release-gate scripts resolve workspace roots and output paths physically (`pwd -P`), so checkouts reached through symlinked paths (e.g. macOS `/tmp` → `/private/tmp`) no longer false-fail the compiler's `WorkspaceEscape` target-containment guard. Links: [scripts/test-reference-theme-layout.sh](/scripts/test-reference-theme-layout.sh), issue #757.
- `--llms` export now emits root-relative `.html` links (the same flat output-relative paths as the HTML target) instead of pretty `/id/` directory URLs, so `llms.txt` links resolve against a default static serve of the built site. Links: [the contract](/docs/contracts/llms-txt.md).
- A fresh `boris init` site now passes `boris-search-index --require-root-marker` out of the box: the starter layout's content root carries the `<main data-boris-search-root>` marker preferred by [rendered search](/docs/contracts/rendered-search.md). Default indexing is unchanged — the same element was already the unmarked fallback root. Issue #763.
- `zig build test` green runs no longer print phantom `failed command:` failure blocks: expected negative-path diagnostic prose is suppressed in unit-test binaries (the Zig build runner echoes a passing test binary's captured stderr as if the step had failed), while CLI `--quiet` semantics and watch-json suppression are unchanged. A new `test-quiet-pass` guard keeps the echo from regressing. See [src/diag.zig](/src/diag.zig) and [#768](https://github.com/drawmeanelephant/boris/issues/768).
- CLI usage diagnostics are self-attributing: out-of-workspace `--theme` / `--html-layout` values name their own flag instead of a scanned argv token (`invalid value for --input`), and unambiguous conflicting-options errors name both tokens as typed (`check conflicts with --theme`); the `--help` conflict matrix gains the analyzer×HTML-selector and HTML-selector×explicit-`--out` rows. See [the CLI contract](/docs/contracts/cli.md).
- Missing-content-root failures on the HTML path now name the probed content root and the create-or-`--input` remediation (#779), matching the IR pipeline wording; the `EIO` exit class is unchanged. [diagnostics contract](/docs/contracts/diagnostics.md).
- Usage errors (exit 2) print their self-attributing cause plus one synopsis line instead of the full help text; full options remain opt-in via `--help`, and the standard-site family keeps its subcommand list (#777). [cli contract](/docs/contracts/cli.md).
- Rendered-site search now joins successive code fragments with single spaces and keeps word boundaries around inline-code spans, so indexed terms such as `otool -L` match as whole tokens instead of one concatenated blob (#778); the text/code field split is unchanged. Evidence-chain goldens were re-pinned for the new index bytes. [rendered-search contract](/docs/contracts/rendered-search.md).

### Security

- Enforced export-path safety policy on direct IR mode, rejecting output equal to or nested under content root, workspace escapes, or output symlinks, mapping configuration/path errors to exit code 2 (usage), and reserving compiler-derived stage paths per [multi-target isolated output contract](/docs/contracts/multi-target-isolated-output.md).
- Prevent HTML publication from following symlinks below output root by validating destination parent directory components with no-follow semantics during staging commit. Links: [HTML output contract](/docs/contracts/html-output.md#symlink-safety-below-output-root-h-03).
- The rendered search index no longer ships invalid JSON. `writeJson` in [`src/search_index.zig`](/src/search_index.zig) escaped quotes, backslashes and the three whitespace escapes but not the remaining C0 control characters, so a single control byte in any page's text emitted a bare control code inside a JSON string. `search-index.json` then failed to parse and client search went dead for the whole site, not just that page. The escaper was a hand-copied variant of [`src/json_out.zig`](/src/json_out.zig)'s with one branch missing; it now delegates there, and a regression test parses the emitted index with `std.json`.
- `zig build test` now fails when a machine-facing emitter bypasses the output encoder. [`src/artifact_invariants.zig`](/src/artifact_invariants.zig) audits published bytes for structural breakouts, [`src/emitter_hostile_test.zig`](/src/emitter_hostile_test.zig) compiles the hostile trees under [`fixtures/hostile-output/`](/fixtures/hostile-output) through the real emitters, and [`src/emitter_discipline_test.zig`](/src/emitter_discipline_test.zig) requires every `src/*.zig` to be classified as an emitter with its encoder or explicitly as a non-emitter — so a new module of any name fails the build until someone records what it is. `fixtures/hostile-output/legitimate-punctuation/` asserts the encoders leave ordinary content untouched.
- An inline `data:` image destination must now declare a real image media type. [`src/content_asset.zig`](/src/content_asset.zig) accepted any `data:` prefix as passthrough, so `data:text/html;base64,…` — a document, in an image slot — reached `dist/` unexamined. Only `image/png`, `image/jpeg`, `image/gif`, `image/webp` and `image/avif` pass; `image/svg+xml` is excluded because an inline SVG is a script-bearing document rather than a picture. Anything else fails the build with `EASSET` and a message naming the accepted types ([contract](/docs/contracts/content-local-assets.md)).
- Refuse content-local SVG assets with active or document-embedding constructs before publication, reporting `EASSET` without rewriting the author’s file. See the [content-local asset contract](/docs/contracts/content-local-assets.md).
- Content source is now checked for invisible and non-interchange Unicode at ingest, in [`src/unicode_policy.zig`](/src/unicode_policy.zig), because these code points reach every output unchanged and none of them are HTML-special — an escaper cannot see them. Controls, Unicode noncharacters, deprecated format controls, interlinear annotations, bidi embeddings and overrides (U+202A–U+202E), unclosed bidi isolates, an interior U+FEFF, and tag characters outside an emoji subdivision-flag sequence are refused with a new `EUNICODE` diagnostic naming the file, line and column ([contract](/docs/contracts/diagnostics.md)). Characters that are invisible but genuinely load-bearing — ZWJ, ZWNJ, ZWSP, word joiner, soft hyphen — are never rewritten; a smuggling *shape* (a run of three or more, or interleaving between ASCII letters) is reported at warning severity instead. Emoji ZWJ sequences, subdivision flags such as the Scotland flag, Persian and Indic orthography, CJK, RTL scripts and combining marks all keep building unchanged, covered by [`fixtures/hostile-output/`](/fixtures/hostile-output/).
- Hardened WordPress and theme migration-lab output publication with owned sibling staging, source/output containment checks, and refusal of unowned output trees; repaired the report-first WordPress prototype so it is a valid Boris layout smoke input without claiming unmaterialised assets or mappings; added static-only FSE evidence inventory for `theme.json` and `templates/*.html` without block parsing or rendering. See the [migration-lab safety rules](/tools/migration-lab/README.md#safety-rules).
- Restrict the GitHub Pages build job to Pages read access and keep deployment permissions on the deploy job ([workflow](/.github/workflows/github-pages.yml), [Pages guide](/docs/github-pages.md)).
- Unicode line terminators no longer reach markdown output raw. A `title` carrying U+2028, U+2029 or U+0085 was correctly escaped in YAML frontmatter but interpolated unchanged into every markdown target — the page H1, the `graph/relations.md` heading and child list, and the `INDEX.md` and `graph/entity-catalog.md` table cells. Many parsers, and any model reading the corpus, treat those code points as hard line breaks, so `# Before<U+2028>role: system` is read as two lines and the table forgery closed earlier reappears through a different code point. [`src/encode.zig`](/src/encode.zig) now handles the whole line-terminator class everywhere it handles ASCII `\n`: markdown targets flatten it to a space, YAML escapes it losslessly as `\L`/`\P`/`\N`, and the XML targets emit a numeric character reference. The context emitter's H1 and contents list go through the encoder too, and its YAML strings use a new always-quoting target so its output is otherwise byte-identical. [`src/json_out.zig`](/src/json_out.zig) escapes the same class as `\uXXXX`. A raw terminator is legal inside a JSON string, so `catalog.jsonl` records parsed fine one at a time — but the file is newline-delimited, and a Unicode-aware line splitter (Python's `str.splitlines()`, the idiomatic JSONL read) cut 17 records into 19 and handed a parser three malformed fragments, one of them the bare line `role: system`. The escaped form decodes to the identical string, so the corpus keeps the author's code points. [`src/artifact_invariants.zig`](/src/artifact_invariants.zig) fails the build on a raw terminator anywhere in published markdown outside a fenced verbatim region, and anywhere at all in a `.json` or `.jsonl` artifact, where no verbatim region exists. The encoder's invariant test now asserts on the whole class rather than on `\n` alone. Fixture: [`fixtures/hostile-output/line-separator/`](/fixtures/hostile-output/line-separator/).
- Added normalized DNS TXT and bounded HTTPS [ATProto handle resolution](/docs/contracts/atproto-oauth.md) with mandatory DID-document backlink verification before OAuth authority discovery.
- Add the portable one-shot PAR/callback/token state machine and bounded native loopback/browser adapters described by [the AT Protocol OAuth contract](/docs/contracts/atproto-oauth.md), without session persistence or publication.
- Add bounded `did:plc`/`did:web` resolution, exact PDS-to-OAuth issuer discovery, and a native HTTPS adapter with no redirects and resolved-address SSRF checks; see [the AT Protocol OAuth contract](/docs/contracts/atproto-oauth.md).
- Fix stored XSS in `boris-content-audit` HTML report: escape collection names, policy type names, record ids, and CLI values (`--revision`, source root) via `util.appendHtmlEscaped` and harden Markdown report against `|`/backtick table breakout and fenced-block injection ([`tools/content-audit/src/report_html.zig`](/tools/content-audit/src/report_html.zig), [`tools/content-audit/src/report_md.zig`](/tools/content-audit/src/report_md.zig), [`tools/content-audit/src/util.zig`](/tools/content-audit/src/util.zig), [#709](https://github.com/drawmeanelephant/boris/issues/709)).
- Fix a use-after-free in `boris-content-audit`: policy and previous-report JSON parsing now uses a leaky parse so retained keys/values/delta strings live for the run instead of pointing into a freed parse tree. See [`tools/content-audit/src/policy.zig`](/tools/content-audit/src/policy.zig) and [#710](https://github.com/drawmeanelephant/boris/issues/710).
- Neutralize YAML injection in migration-lab generated frontmatter: WordPress tags/preserved titles and Starlight/Filed titles are now quoted/escaped, and control characters are dropped, so hostile taxonomy names or `": "` titles can no longer inject keys or emit invalid YAML. See [`tools/migration-lab/wordpress.zig`](/tools/migration-lab/wordpress.zig) and [#712](https://github.com/drawmeanelephant/boris/issues/712).
- Harden migration-lab conversion: sanitize untrusted JSX attribute values before replay, require path-segment boundaries for WordPress slug link resolution, stop silent asset overwrites when collision disambiguation is exhausted, and keep scanning after an unterminated attribute value. See [`tools/migration-lab/starlight.zig`](/tools/migration-lab/starlight.zig) and [#717](https://github.com/drawmeanelephant/boris/issues/717).

### Docs

- Added canonical agent completion-report template and updated agent protocol rules. See [`COMPLETION-REPORT-TEMPLATE.md`](/docs/COMPLETION-REPORT-TEMPLATE.md) and [`AGENTS.md`](/AGENTS.md).
- Documented a bounded, local-only Emoji Kitchen portability prototype and contract fixture without changing Boris rendering behavior. See the [proposal](/docs/proposals/emoji-kitchen-extension.md) and [prototype cases](/docs/contracts/fixtures/emoji-kitchen-prototype/README.md).
- Added a provider-neutral [takeout migration-lab intake contract](/docs/contracts/takeout-lab-intake.md) with ignored raw-local boundaries, a synthetic social fixture, and importer evidence requirements. Real Facebook, Instagram, and Google Takeout samples are still required before provider adapters can claim compatibility.
- Reorganized the dogfood documentation into Start Here, Learn, Reference, Architecture, and Archive paths so readers can find a useful next page before entering the project history ([documentation status](/docs/STATUS.md)).
- Added a repeatable [archive-layout audit fixture](/docs/contracts/fixtures/archive-layout-audit/README.md) covering layout selection, graph-backed children, responsive-risk guardrails, and generated-site link validation.
- Consolidated the public documentation experience into the compiled [`content/`](/content/) tree, with practical command, output, diagnostic, relationship, and migration references plus a reader-first default managed theme and copied stylesheet.
- Added a reader-facing [page-building and search guide](/content/guides/building-pages.md).
- Completed Passes 1–3 of the Boris documentation site overhaul with a refined product spine, standardized authoring guides, modern presentation layout, publishable evidence assets, and comprehensive truth-and-artifact corrections across site formats, CLI references, search UI, and machine export specifications.
- Corrected the search guide's layout marker names to the normative `data-boris-search-root` / `data-boris-search-exclude`, and documented that an ordinary `boris` build publishes the search index itself rather than requiring a separate standalone run. Links: [the rendered-search contract](/docs/contracts/rendered-search.md).
- Added the canonical [publication model contract](/docs/contracts/publication-model.md) to separate document facts, publication facts, migration provenance, independently governed projections, and scoped verification claims without widening frontmatter or adding a publication runtime.
- Added retained C02/C03/C04/C08 publication-conformance fixtures, exact output goldens, an executable verifier, and parser-boundary evidence; see the [publication conformance report](/docs/archived/audits/publication-conformance/REPORT.md).
- Recorded a [test-throughput audit](/docs/archived/audits/test-throughput-audit.md): the `zig build test` graph is already fully sibling-parallel; scaling `-j1`→`-j8` is ~3x and the residual wall-time floor is structural (~8.8x shared-suite re-execution across four co-dominant test roots), so no build-graph change was made.
- Reconciled the public content site with the v0.8.1 candidate CLI, closed frontmatter grammar, compiler-owned search, output routes, and publication boundaries. See the [command reference](/content/reference/commands.md) and [validation contract](/docs/contracts/validation.md).
- Record full-browser visual, keyboard, and accessibility audit for Boris Editor across M0–M5 authoring workflows in [`docs/audits/editor-browser-audit.md`](/docs/archived/audits/editor-browser-audit.md) ([#418](https://github.com/drawmeanelephant/boris/issues/418)).
- The CLI contract now specifies the version query for tooling: `boris --version` / `-V` print the compiler id (`pipeline.compiler_id`, e.g. `boris/0.8.1`) as a single stdout line and exit 0, with pinning and artifact-provenance recipes. See [`cli.md`](/docs/contracts/cli.md) § Version query.
- The retained Apex-era changelog fragments (vendored ApexMarkdown pin and its IR-schema build dependency) are disposed of as superseded by the Oliver renderer, and the v0.1 orientation record now marks its links to the removed Apex pipeline as archival by intent.
- Added the Boris Editor as step 7 of the [authoring spine](/docs/authoring-spine.md) teaching layer, linking the new [editor guide](/content/guides/editor.md) so the shortest-path trail reaches the schema- and graph-aware authoring surface.
- Recorded the publisher-platform identity (issue [#538](https://github.com/drawmeanelephant/boris/issues/538)): HTML `dist/` is the default target, not the whole product. Reconciled [STATUS](/docs/STATUS.md), [README](/README.md), [AGENTS](/AGENTS.md), the [authoring spine](/docs/authoring-spine.md), the [contracts index](/docs/contracts/README.md), and the compiled [content site](/content/index.md) to that choice. Retired the per-module source dossier under `docs/boris/`, the sibling `docs/tools/` dump, and the leftover `docs/design/` / `docs/designs/` notes. Implemented design work now lives in contracts and `src/`. Unfinished Doctor work is a [STATUS](/docs/STATUS.md) line item. Retired `docs/dogfood/`, `docs/evidence/`, and `docs/retrospectives/` the same way. Replacement hallway: [source map](/docs/SOURCE-MAP.md).
- Recorded a disposable-identity Nostr publish as a secret-free first-tester fixture (`partial`: nos.lol, nostr.mom, and primal accepted; damus handshake `BadStatus`). See the [live-smoke fixture](/docs/contracts/fixtures/nostr-live-smoke/README.md) and the [Nostr publication contract](/docs/contracts/nostr-publication.md).
- Nostr stays off the verified-target seam on purpose: relays are not a host, so `nostr` is not a third `publication.target`. See the [platform contract](/docs/contracts/publication-platforms.md) and the [Nostr publication contract](/docs/contracts/nostr-publication.md).
- Front-door copy now names the shipped embed surface and example Worker host, and keeps it off the publication-target registry. See [the embedding contract](/docs/contracts/embedding.md) and [#301](https://github.com/drawmeanelephant/boris/issues/301).
- Recorded a passing `boris standard-site smoke` against a dedicated bsky.social test identity via the opt-in app-password path, as a secret-free `boris-live-smoke-result` fixture. See the [live-smoke fixture](/docs/contracts/fixtures/standard-site-live-smoke/README.md) and the [live smoke contract](/docs/contracts/atproto-live-smoke.md).
- Recorded a bounded, licensed Twenty Twenty 3.1 theme-materialization dogfood pass: deterministic archaeology and static draft generation, explicit PHP/JS refusals, a representative Boris build, and zero-finding local link audit. See the Labs table in [STATUS](/docs/STATUS.md).
- The CLI contract now specifies the stdout machine surface — the closed set of commands/flags that emit one document on stdout (`--version`, `--timings`, `plan`, `standard-site plan|records|verify|publish|smoke`, `nostr plan|sign|publish`, `recipe-scale`) and the empty-stdout rule for everything else — and documents per-mode `--report` semantics, fixing the misleading `--help` text that claimed `--report` wrote "instead of stdout". Links: [CLI contract](/docs/contracts/cli.md), [diagnostics](/docs/contracts/diagnostics.md), [#639](https://github.com/drawmeanelephant/boris/issues/639).
- Correct the [archive-layout status](/docs/STATUS.md) and retained [browser evidence](/docs/contracts/fixtures/archive-layout-audit/BROWSER-REVIEW.md) so viewport measurements and programmatic focus traversal are not presented as completed trusted-keyboard or screen-reader verification, and historical roadmap-number references do not become stale after renumbering.
- Polish `docs/STATUS.md:1` afterparty tip `5021261` (`#670` segmentation) and `editor/voice-certification.md:1` links to active spoken-voice sub-issue [#677](https://github.com/drawmeanelephant/boris/issues/677) (re-verified 112/112 in [#679](https://github.com/drawmeanelephant/boris/issues/679), reconciled in [#678](https://github.com/drawmeanelephant/boris/issues/678)). Links: [`docs/STATUS.md`](/docs/STATUS.md), [`editor/voice-certification.md`](/editor/voice-certification.md).
- Archive `docs/ROADMAP-post-f8.md` to `docs/archived/ROADMAP-post-f8.md` as a historical record (562 lines) and remove it from active agent context. Living direction remains in [project status](/docs/STATUS.md); deferred F10 external-asset edges and external-stylesheet allowlist are tracked in the [templating and themes contract](/docs/contracts/templating-and-themes.md).
- Slim [`CHANGELOG.md`](/CHANGELOG.md) to `[Unreleased]` + `[0.8.0]` (83 lines) per [#691](https://github.com/drawmeanelephant/boris/issues/691): archive pre-0.8.0 history (≈1243 lines, 0.7.0–0.1.0) to [`docs/archived/CHANGELOG-pre-0.8.md`](/docs/archived/CHANGELOG-pre-0.8.md) and update [`AGENTS.md`](/AGENTS.md) standing context to bound future growth, plus pointer updates in [`docs/STATUS.md`](/docs/STATUS.md), [`docs/SOURCE-MAP.md`](/docs/SOURCE-MAP.md), [`docs/contracts/README.md`](/docs/contracts/README.md), [`docs/AGENT-PLAYBOOK.md`](/docs/AGENT-PLAYBOOK.md), and [`README.md`](/README.md). Links: [`CHANGELOG.md`](/CHANGELOG.md), [`docs/archived/CHANGELOG-pre-0.8.md`](/docs/archived/CHANGELOG-pre-0.8.md), [`AGENTS.md`](/AGENTS.md).
- Slim [`docs/STATUS.md`](/docs/STATUS.md) to a phase banner + pointer table (<80 lines) per [#692](https://github.com/drawmeanelephant/boris/issues/692): archive v0.8 capability matrices to [`docs/archived/capability-matrix-v0.8.md`](/docs/archived/capability-matrix-v0.8.md), move risk and environment notes to [`docs/contracts/html-output.md`](/docs/contracts/html-output.md) and [`docs/contracts/validation.md`](/docs/contracts/validation.md), move the documentation map to [`docs/SOURCE-MAP.md`](/docs/SOURCE-MAP.md), and update [`AGENTS.md`](/AGENTS.md) standing context. Links: [`docs/STATUS.md`](/docs/STATUS.md), [`docs/archived/capability-matrix-v0.8.md`](/docs/archived/capability-matrix-v0.8.md), [`docs/SOURCE-MAP.md`](/docs/SOURCE-MAP.md), [`AGENTS.md`](/AGENTS.md).
- Archive completed audits (`optimization-audit.md`, `optimization-backlog.md`, `publication-surface.md`, `project-health-surface.md`, `test-throughput-audit.md`, `editor-browser-audit.md`, and `publication-conformance/REPORT.md` — ~4,700 lines) from `docs/audits/` to `docs/archived/audits/` as a historical record; fixtures remain in `docs/audits/publication-conformance/` for `zig build test-publication-conformance`. See the [archived audits index](/docs/archived/audits/README.md) and the [source map](/docs/SOURCE-MAP.md).
- Move completion report template to GitHub templates and slim the docs pointer per [#694](https://github.com/drawmeanelephant/boris/issues/694): add [`.github/PULL_REQUEST_TEMPLATE.md`](/.github/PULL_REQUEST_TEMPLATE.md) and [`.github/ISSUE_TEMPLATE/completion-report.md`](/.github/ISSUE_TEMPLATE/completion-report.md) with the canonical 12-field evidence block, slim [`docs/COMPLETION-REPORT-TEMPLATE.md`](/docs/COMPLETION-REPORT-TEMPLATE.md) to a one-paragraph pointer (<10 lines), and update [`AGENTS.md`](/AGENTS.md) and [`docs/AGENT-PLAYBOOK.md`](/docs/AGENT-PLAYBOOK.md). Links: [`.github/PULL_REQUEST_TEMPLATE.md`](/.github/PULL_REQUEST_TEMPLATE.md), [`docs/COMPLETION-REPORT-TEMPLATE.md`](/docs/COMPLETION-REPORT-TEMPLATE.md), [`AGENTS.md`](/AGENTS.md).
- README and `boris init` next-steps now teach the reserved `content/includes/` fragment library and the `<stem>.assets/` image convention up front instead of only by failure ([#738](https://github.com/drawmeanelephant/boris/issues/738), [#744](https://github.com/drawmeanelephant/boris/issues/744)).
- Completed the cache-discriminator rename in the contracts: the multi-target isolation contract and the layout-rules fixture README now name `boris-cache-v3-nav-digest` as the current cache format instead of the retired `boris-cache-v2-layout-rules`, matching [cache.zig](/src/cache.zig) and the probe fixed in [#746](https://github.com/drawmeanelephant/boris/issues/746). See [multi-target-isolated-output](/docs/contracts/multi-target-isolated-output.md).
- `boris --help` documents the frontmatter `status:` enum (`draft` | `published` | `archived`) and the draft visibility rule — drafts render but stay out of nav, search, sitemap, RSS, and publication projections; behavior unchanged and still normative in [the frontmatter contract](/docs/contracts/frontmatter.md).

---

## [0.8.0] — 2026-07-21

The v0.8.0 release keeps base IR `0.2.0` and conditional semantic-relation IR
`0.3.0`; it packages post-v0.7 release hardening, migration review tooling,
source-RAG upload ergonomics, and the ApexMarkdown v1.1.12 vendor update.

### Added

- Added deterministic whole-file source-RAG bundle partitioning with
  `--split-size`, ordered `part_manifest.json` provenance, and documented
  oversized-file and `--no-bundles` behavior. See the
  [source-RAG guide](/tools/source-rag/README.md).
- Added `boris-source-rag --bundles-only` plus `upload_manifest.json` for
  combined upload bundles without the per-file `files/**` tree. See the
  [source-RAG guide](/tools/source-rag/README.md).
- Added deterministic, review-first Astro/Starlight relationship candidate
  extraction with source provenance and explicit product-bound evidence. See
  the [migration-lab guide](/tools/migration-lab/README.md).
- Added migration-lab `frontmatter-review` mode for preserving unknown source
  frontmatter as an explicit review report without widening Boris core grammar.
  See the [migration-lab README](/tools/migration-lab/README.md).

### Changed

- Upgraded the vendored ApexMarkdown Unified engine to upstream `v1.1.12` with
  identical Boris HTML, Aside, RAG, diagnostics, and ABI behavior on the
  representative gates. See [`vendor/apex-markdown/VENDOR.md`](vendor/apex-markdown/VENDOR.md).

### Fixed

- Package archive publish no longer deletes the live tar before the replacement
  is complete; install uses move-aside so a failed write preserves any previous
  archive. See the [package module](/src/package.zig).
- Fixed Starlight migration matching so prefix-colliding components such as
  `<Asides />` remain explicit manual-review fallbacks instead of producing
  unterminated Boris [`<Aside>` blocks](/docs/contracts/components.md).
- Hardened [`theme-materialize`](/tools/migration-lab/README.md) so static
  assets with companion remote or traversal evidence in an archaeology ledger
  are refused rather than copied into a Boris theme draft.

### Docs

- Added and updated real-site Filed.fyi, WordPress Theme Test Data, Starlight,
  agent roll-call, contest homepage, link-audit, and release-honesty evidence
  while keeping migration labs bounded developer aids.
- Clarified bounded [`--jobs` HTML workers](/docs/contracts/parallel-rendering.md),
  sanitizer evidence, frontmatter `relations`, and current release status.

---

Full history before v0.8.0: see [archived changelog](docs/archived/CHANGELOG-pre-0.8.md).
