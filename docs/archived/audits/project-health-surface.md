> **Archived 2026-08-21 — issue [#693](https://github.com/drawmeanelephant/boris/issues/693).**
> This file was moved from `docs/audits/project-health-surface.md` to `docs/archived/audits/project-health-surface.md`
> as a historical record. Do not load this file as standing agent context. Git history preserves the original.

# Boris project-health surface audit

**Status:** repository audit and design input; no product behavior change

**Audited revision:** `afterparty` at `41c094eb73e9`

**Audit date:** 2026-07-29

**Product state:** v0.8.1 candidate; base IR schema `0.2.0`

This audit resolves what a deterministic, offline, read-only Boris Doctor can
prove from the current repository. It does not add a public command or
change `check`, `impact`, compilation, publication, README, or public content.
The shipped kernel is [`src/doctor.zig`](../../src/doctor.zig).

## Executive conclusion

The strongest v1 boundary is a **publication-snapshot auditor**, not a wider
Documentation Intelligence command.

Doctor should validate the source and frozen graph, then compare an explicitly
selected publication plan with the already-rendered target trees and their
target-owned search, sitemap, RSS, llms.txt, and asset artifacts. It should
reuse existing validators and renderers, add only objective structural checks,
and emit a separate versioned report. It must never fetch a URL, score a site,
rewrite source, or claim external compliance.

This boundary complements the current commands:

- `check` remains the fast graph/dependency policy gate;
- `impact` remains the transitive-dependent query;
- `doctor` becomes the slower publication-level consistency audit.

The first implementation slice should be an internal, one-target rendered HTML
and search-artifact audit. It should reuse the product route resolver, add real
ID/fragment indexing, and remain unexposed in the CLI until the report and
complete v1 checks are ready. Rewriting Documentation Intelligence would add
risk without adding evidence.

## Authority and method

This is review plus design guidance. Product-code fixes were not authorized.
Evidence was resolved in repository order:

1. executable behavior and current code;
2. normative contracts;
3. repository policy and current status;
4. release gates and fixtures;
5. public `content/` and a generated dogfood publication.

The requested `src/analysis.zig` path does not exist at the audited revision.
The current analysis implementation is
[`src/intelligence.zig`](../../src/intelligence.zig), with command adaptation
and report rendering in [`src/main.zig`](../../src/main.zig) and routing in
[`src/cli.zig`](../../src/cli.zig). This is **Non-issue / packet drift**, not a
missing product module.

The audit inspected at minimum:

- all contracts named in the request, plus diagnostics, frontmatter,
  documentation-link, heading-ID, and IR contracts reached from them;
- `src/intelligence.zig`, `src/cli.zig`, `src/main.zig`,
  `src/compile.zig`, `src/link_audit.zig`, and `src/html_scan.zig`;
- search, sitemap, RSS, llms.txt, content-asset, and publication-profile
  implementations;
- migration-lab `link-audit` and `frontmatter-review`;
- Documentation Intelligence, rendered-search, graph, HTML, asset, and
  release-gate fixtures;
- the release-gate script and focused build steps;
- the complete public `content/` tree, default theme, and generated dogfood
  HTML/search/sitemap/RSS/llms/IR artifacts.

Generated directories were evidence only and remain ignored, not review
currency.

## Capability inventory

### Already implemented core facts

| Fact Boris can already prove | Current authority and implementation | Doctor reuse boundary |
|---|---|---|
| Source parses under the closed frontmatter grammar | `frontmatter.md`; parser/pipeline diagnostics | Call the existing compile/validate path. Do not copy the grammar. |
| Entity IDs, parents, cycles, relations, includes, and wiki references validate | graph, dependency, relation, and heading contracts; `pipeline.compile` and HTML graph gate | Validation is a prerequisite. Invalid content returns existing diagnostics, not a partial Doctor report. |
| Page/source dependency edges and transitive dependents are deterministic | `documentation-intelligence.md`; `src/intelligence.zig` | Reuse analysis values. Do not alter `check`/`impact` JSON, human output, or exits. |
| Unreferenced pages and thresholded fan-in are graph facts | `src/intelligence.zig` | Map them into Doctor’s separate finding model; keep Doctor severity policy independent. |
| Canonical page output paths are safe and deterministic | identity and HTML contracts | Build the expected page set from canonical IDs, never from guessed URLs. |
| Content-local assets have exact ownership, safe path grammar, no symlinks, safe SVG, collisions, and sorted inventory | `content-local-assets.md`; `src/content_asset.zig` | Reuse discovery and expected output-path inventory without copying or scrubbing. |
| Theme assets and layout references are bounded and target-owned | HTML/theme contracts and compile preflight | Reuse inventory; compare expected bytes and paths with the rendered target read-only. |
| Rendered local `href`/`src` routes do not escape and resolve against the intended output manifest | `src/link_audit.zig`; HTML commit gate | Extract a shared manifest/path-resolution kernel. Keep the existing compiler diagnostic mapping unchanged. |
| Search JSON can be re-derived deterministically from final HTML | `rendered-search.md`; `src/search_index.zig` | Re-index in memory and compare with the configured artifact. |
| Sitemap bytes and eligible routes can be re-derived from page paths and site URL | `xml-sitemap.md`; `src/sitemap.zig` | Re-render in memory; do not crawl the target or the deployment URL. |
| RSS eligibility, order, metadata, URLs, and bytes are deterministic | `rss-2.0.md`; `src/rss.zig` | Re-render from the validated graph and configured channel metadata. |
| llms.txt order, summaries, links, and bytes are deterministic | `llms-txt.md`; `src/llms.zig` | Refactor the private renderer for borrowed read-only use; preserve legacy bytes. |
| Publication profile schema v1 has strict parsing, path containment, metadata rules, and static ownership validation | `publication-profile.md`; `src/publication_profile.zig` | Use the typed immutable plan as Doctor’s configuration identity. Dynamic publication execution remains out of scope. |

The existing HTML link audit is stronger than a filesystem probe: it resolves
against the current intended page/asset manifest, catches decoded traversal,
and rejects references to stale files that merely happen to remain on disk.
That behavior is the correct reusable base.

### Reusable migration-lab behavior

| Lab behavior | Reusable | Must not be promoted unchanged |
|---|---|---|
| Read-only input discipline and output-only reports | Yes | Doctor’s default remains stdout; only explicit `--report` may write. |
| Deterministic path ordering and paired JSON/human reports | Yes, as a pattern | Doctor needs a new schema and shared finding model, not either lab format. |
| Link-audit concepts: local route, fragment, source output path, line, reason | Yes | The lab scanner only finds double-quoted lowercase `href`, uses filesystem existence, ignores same-page fragments, string-matches `id="…"`, and does not safely JSON-escape every value. |
| Frontmatter-review provenance, file/line evidence, incompatible-fence reporting | Yes, as evidence ergonomics | Its independent five-key allowlist has drifted from the normative eight-key grammar. Doctor must use the product parser. |
| Source immutability and two-run determinism fixture style | Yes | These become required Doctor hostile tests. |

The migration-lab link audit remains useful for migrated non-Boris trees, but
Doctor must reuse the product tokenizer and manifest semantics instead. The
lab’s ability to append `.html` or probe a directory is migration policy, not a
Boris publication fact.

### New deterministic checks

These checks require new report logic but no network, browser, LLM, or source
mutation:

| Check family | Objective fact |
|---|---|
| Publication inventory | Expected graph page is missing; selected target/artifact is absent; symlink or unsafe path appears below a selected root. Extra HTML is not provably stale until publication records an owned-output manifest. |
| HTML parse completeness | A selected document contains an unterminated or structurally unrecoverable tag, comment, quote, or raw-text element, so downstream inspection cannot be complete. |
| ID and fragment integrity | IDs are empty or duplicated; a local same-page or cross-page fragment is absent after HTML entity and URL-fragment decoding. |
| Asset integrity | Expected target-owned asset is missing, stale in an owned namespace, a symlink, or byte-different from its source/theme owner. |
| Structural accessibility | `img` lacks an `alt` attribute; document heading level jumps by more than one; the document lacks `html[lang]` or exactly one `main`. Empty `alt` is accepted and never judged. |
| Metadata presence | Missing/empty/multiple document title; missing charset; public page lacks one configured canonical URL. |
| Metadata consistency | Canonical URL does not equal configured site URL plus canonical output path; multiple pages publish the same canonical URL. |
| Search consistency | Artifact format/schema/types are valid; documents exactly match rendered pages; stored title, sections, fragments, prose, and code equal an in-memory re-index. |
| Sitemap consistency | XML shape is valid; URL set exactly matches non-draft eligible HTML routes and configured site URL; duplicates and stale/missing URLs are findings. |
| RSS consistency | Channel metadata matches configuration; item set/order/content exactly matches eligible graph nodes and limit; item links resolve to current HTML. |
| llms.txt consistency | Generated bytes and page-link set match current source/graph behavior; links resolve according to the llms.txt contract’s current `/<id>/` form rather than being silently rewritten to HTML routes. |

“Malformed HTML” must be a first-class finding, not a reason to skip silently.
If one document cannot be inspected completely, Doctor reports that document
and does not claim its downstream checks passed.

### Checks requiring rendered output

The following cannot be proved from Markdown or graph metadata alone:

- actual local `href`/`src` route resolution after Apex and layout assembly;
- same-document and cross-document fragment membership;
- duplicate rendered IDs, including Apex’s documented duplicate heading IDs;
- missing rendered `alt`, heading-level jumps, `html[lang]`, and `main` shape;
- final `<title>`, canonical link, charset, and canonical collisions;
- target-owned asset presence after staging/cleanup;
- rendered search extraction and its exact artifact freshness;
- sitemap/RSS/llms links resolving against the target actually being audited.

Doctor must inspect exact final bytes. Re-rendering Markdown as a substitute
would create a second compiler path and could miss layout/raw-HTML behavior.

### Checks requiring network access

These are not Doctor v1 capabilities:

| Desired claim | Why local evidence is insufficient |
|---|---|
| External URL returns success | Requires DNS, connection, protocol, redirects, and time-dependent remote state. |
| Redirect target is correct or permanent | Requires remote policy and often deployment history. |
| TLS/certificate/HTTP-header health | Exists only at the deployed endpoint. |
| robots.txt, remote sitemap discovery, or crawler access | Depends on deployed origin and crawler behavior. |
| Search engine indexing, ranking, snippets, or canonical selection | Controlled by external systems; local tags are inputs, not outcomes. |
| Performance or Lighthouse results | Requires a browser, server, device/network model, and time-varying execution. |

Doctor should skip every scheme-bearing or protocol-relative rendered URL
without a request. It may validate configured HTTP(S) URL syntax using the
existing local parser.

### Subjective or unsafe checks to reject

- numeric SEO, accessibility, editorial, readability, or “health” scores;
- keyword density, tone, style, completeness, usefulness, or content-quality
  judgments;
- judging whether alt text is good, descriptive, or redundant;
- automatically generating alt text, summaries, headings, redirects, or
  canonical URLs;
- inferring that two pages should redirect, merge, split, or supersede one
  another;
- LLM review, embeddings, hosted APIs, or remote validators;
- accessibility certification or claims of WCAG conformance;
- claims of Lighthouse or search-engine compliance;
- source rewriting, output repair, or a generic fix/plugin interface.

Doctor may report a structurally missing attribute. It must not turn that fact
into a certification or editorial verdict.

## Material observations

Each observation is classified once using the repository review vocabulary.

### O1 — current core route audit is reusable, but fragment audit is absent

- **Classification:** Documented limitation
- **Severity:** P2 for Doctor scope; not a current release defect
- **Locus:** `src/link_audit.zig:41`; diagnostics reserve
  `EFRAGMENTMISSING`
- **Evidence:** the module explicitly skips same-document fragments and states
  that real ID parsing and URL decoding are required. The compiler tests cover
  missing/escaping routes, quotes, raw-text exclusions, and intended-manifest
  semantics.
- **Impact:** current HTML publication proves route existence but not arbitrary
  rendered fragment integrity. Wiki fragments are separately validated only
  through the authored wiki-link pipeline.
- **Smallest remediation card:** extract the manifest/path resolver, build a
  rendered per-document ID index, then add a Doctor-only missing-fragment
  finding before considering compiler-gate changes.
- **Verification:** focused resolver/fragment hostile tests plus unchanged
  `zig build test` and `check`/`impact` goldens.

### O2 — migration-lab link-audit behavior is evidence, not a product kernel

- **Classification:** Documented limitation
- **Severity:** P2 if copied into Doctor
- **Locus:** `tools/migration-lab/link_audit.zig`
- **Evidence:** it substring-scans only `href="`, probes the filesystem, ignores
  hash-only links, and string-matches target IDs. The product link audit already
  has tag-aware scanning, generic scheme exclusion, traversal decoding, and
  intended-manifest membership.
- **Impact:** direct promotion would miss valid attribute forms and could call a
  stale or escaped route healthy.
- **Smallest remediation card:** reuse only its finding concepts and
  deterministic report lessons; share product code for resolution.
- **Verification:** hostile single/double/unquoted attributes, comments/raw
  text, stale files, encoded traversal, and same/cross-page fragments.

### O3 — frontmatter-review’s independent allowlist has drifted

- **Classification:** Confirmed defect
- **Severity:** P2, migration-lab report correctness
- **Locus:** `tools/migration-lab/frontmatter_review.zig:23`
- **Evidence/reproduction:** the normative grammar accepts `relations`,
  `published_at`, and `summary`. Running frontmatter-review over
  `docs/contracts/fixtures/semantic-relations/content` reported all three valid
  `relations` occurrences as unsupported.
- **Impact:** migration authors can be told to review or discard valid Boris
  metadata. Doctor must not reuse this allowlist.
- **Smallest remediation card:** separately update the lab to consume a shared
  closed-key declaration or keep an explicit contract-conformance test. That is
  outside this design-only PR.
- **Verification:** the semantic-relations fixture produces zero
  `relations`-unknown findings while genuine unknown keys remain reported.

### O4 — publication-profile facts are static-plan facts today

- **Classification:** Documented limitation
- **Severity:** P2 for sequencing
- **Locus:** `docs/contracts/publication-profile.md`;
  `src/publication_profile.zig`
- **Evidence:** schema-v1 parsing and static validation are implemented, but no
  public `--profile` command or publication coordinator exists. Dynamic
  page/asset/artifact ownership is explicitly deferred.
- **Impact:** Doctor can safely reuse the typed plan, but its implementation must
  amend the profile/CLI contracts before exposing `doctor --profile`; it cannot
  claim that a successful profile build exists.
- **Smallest remediation card:** make Doctor the first explicitly read-only
  profile consumer, audit every v1-selected target artifact in scope, and report
  out-of-scope machine editions in coverage rather than silently ignoring them.
- **Verification:** strict profile hostile tests, no profile discovery, and
  black-box proof that Doctor creates no publication output.

### O5 — public draft-output prose conflicts with current artifact behavior

- **Classification:** Confirmed defect
- **Severity:** P2, public documentation accuracy
- **Locus:** `content/guides/building-pages.md:42`, `:48`, `:96`, and `:104`
- **Evidence/reproduction:** the normative grammar has eight keys, not five.
  A build of `docs/contracts/fixtures/valid/content` emitted the draft page into
  HTML, rendered search, JSON IR, and llms.txt; the sitemap correctly excluded
  it. Current RSS also excludes drafts. The implementation has per-artifact
  eligibility rather than one universal “published pages” set.
- **Impact:** Doctor would produce false stale/missing findings if it assumed one
  page set across every artifact.
- **Smallest remediation card:** after this PR, correct the public content or
  deliberately change and contract product eligibility. Do not silently make
  Doctor choose the policy.
- **Verification:** a status matrix fixture pins HTML/search/sitemap/RSS/llms/IR
  eligibility and the public guide states that matrix accurately.

### O6 — duplicate rendered heading IDs are accepted by contract

- **Classification:** Documented limitation
- **Severity:** warning-level Doctor finding
- **Locus:** `docs/contracts/heading-ids.md:48`; Apex-rendered output
- **Evidence:** the heading contract records that duplicate headings may emit
  the same ID and that wiki-fragment matching is set membership. The dogfood
  `comparison.html` contains duplicate `id="why-choose-boris"`.
- **Impact:** the link target exists, but the rendered fragment is ambiguous and
  the document violates ID uniqueness expected by common HTML consumers.
- **Smallest remediation card:** Doctor reports `HTML_DUPLICATE_ID` as a warning;
  it does not rename IDs or change Apex behavior.
- **Verification:** duplicate-ID hostile fixture yields one stable warning and
  leaves HTML unchanged.

### O7 — a missing canonical link is not currently a Boris defect

- **Classification:** Non-issue / packet drift
- **Severity:** none under current contracts
- **Locus:** default theme and HTML contract
- **Evidence:** no current contract requires canonical metadata, and the default
  theme emits none. A configured site URL currently belongs to RSS/sitemap, not
  HTML.
- **Impact:** Doctor may introduce a warning-level metadata policy only when a
  selected public target has a configured site URL. It must not retroactively
  claim current HTML violates an existing contract.
- **Smallest remediation card:** define the Doctor finding without changing HTML
  emission; a later product slice may add canonical output deliberately.
- **Verification:** no-site-URL profile skips the check; a public configured
  target without canonicals reports warnings; mismatched/duplicate canonicals
  report deterministic errors.

## Dogfood publication evidence

The current public `content/` was built into an ignored audit directory from one
source revision with HTML+search+sitemap, llms.txt, RSS, and JSON IR.

| Artifact fact | Observed |
|---|---:|
| HTML pages | 22 |
| Search documents | 22 |
| Sitemap URLs | 22 |
| llms.txt links | 22 |
| IR manifest pages | 22 |
| RSS items | 0 |
| Existing compiler route findings | 0 |
| Migration-lab local route/fragment findings | 0 |
| Duplicate rendered IDs found by evidence probe | 1 value in one page |
| Heading jumps greater than one | 1 (`h1` to `h3`) |
| Rendered `img` elements missing `alt` | 0 |

Zero RSS items is a **Non-issue**: public content has no RSS-eligible
`published_at` plus `summary` pairs. The count equality among the other current
artifacts is evidence for this revision, not a universal eligibility rule.

The generated default HTML has non-empty titles, UTF-8 metadata, viewport
metadata, `html lang="en"`, and one search root. It has no canonical links,
which is permitted today.

## Recommended boundary

Doctor v1 should cover only:

1. graph and source health using existing validators and Documentation
   Intelligence facts;
2. internal rendered routes and fragments;
3. expected target-owned assets and owned-namespace stale assets;
4. narrowly structural accessibility facts;
5. title/language/charset/canonical presence and configured consistency;
6. exact search/sitemap/RSS/llms consistency with the current graph, rendered
   pages, and selected publication plan.

It should require an explicit schema-v1 publication profile, perform no profile
discovery, audit every declared HTML target, and apply public-artifact checks to
the one declared public target. Project IR/RAG/Context editions remain reported
as out of Doctor v1 coverage; they are not silently treated as healthy.

The shipped kernel is [`src/doctor.zig`](../../src/doctor.zig). There is
still no public `boris doctor` command; see [`docs/STATUS.md`](../STATUS.md).
