# RFC: deterministic page layout selection

**Status:** Accepted and implemented (CLI `--layout-rule` slice; no project manifest)

**Scope:** HTML page layout selection after F9.2

**Normative dependencies:**
[`templating-and-themes.md`](../contracts/templating-and-themes.md),
[`multi-target-isolated-output.md`](../contracts/multi-target-isolated-output.md),
[`frontmatter.md`](../contracts/frontmatter.md), and
[`identity-and-paths.md`](../contracts/identity-and-paths.md)

This RFC resolves the post-F9.2 layout-selection decision. It is a design
proposal, not an implemented product claim. The contracts above remain
authoritative until an implementation PR amends them and lands fixtures.

## Decision summary

Adopt repeatable, target-qualified CLI rules:

```text
--layout-rule <TARGET> <SELECTOR> <LAYOUT_PATH>
```

Selectors are explicit and closed:

```text
id:<entity-id>       exact final entity id
glob:<pattern>       segment glob; `*` is one complete segment
role:trunk           existing validated graph role
role:satellite       existing validated graph role
```

The decision is:

1. Layout selection is build-owner configuration, not page frontmatter.
2. Exact id rules beat globs; the uniquely most-specific glob beats a role
   rule; a role rule beats the existing target/global fallback layout.
3. Rule order has no meaning. Duplicate or tied winning rules fail with a
   usage error; Boris never uses first-declaration-wins.
4. A target may select several layouts but has exactly one theme/asset owner.
   Managed layouts for one target must share one theme root. Targets remain
   isolated and may use different themes and rule tables.
5. Incremental state records the effective layout per target/page. Rule edits
   dirty pages only when their effective selected layout changes; layout and
   referenced-asset edits dirty their actual consumers.
6. The first slice adds no project manifest. A future general Boris config may
   project into the same canonical rule model, but requires its own contract.

## 1. Problem and goals

Boris currently selects one layout per target through `--html-layout`,
`--target-layout`, or `--theme`. Real documentation sites commonly need a
distinct home page, reference shape, or graph-role landing page while retaining
one content graph and one static theme asset inventory.

The design must:

- preserve the closed five-key frontmatter grammar;
- make the same content and CLI configuration choose the same layout on every
  run, independent of argument and filesystem enumeration order;
- fail before an affected target publishes when selection is invalid or
  ambiguous;
- preserve target-owned output, cache, staging, layouts, and assets;
- integrate with existing content-addressed incremental and watch behavior;
- keep layouts as trusted static HTML with the existing closed marker
  vocabulary; and
- require no Node, runtime JavaScript, subprocess renderer, network fetch, or
  second SSG.

## 2. Author and build-configuration surface

### 2.1 Page-author surface

There is no new page-author field. In particular, these remain invalid:

```markdown
---
layout: home
---
```

```markdown
---
template: reference
---
```

Both are unknown frontmatter keys and continue to produce `EFRONTMATTER`.
There is no alias, permissive extras map, or migration-only parser. Authors may
affect selection only through already-valid inputs:

- the final canonical entity id, including an existing valid `id:` override;
- the Trunk/Satellite role derived from the existing `parent` field; or
- a source move that changes a path-derived id.

The `.mdx` extension does not add execution semantics. Layout rules do not
enable expressions, imports, components, or unbounded MDX.

### 2.2 CLI grammar

The recommended first shipping surface is:

```text
--layout-rule <TARGET> <SELECTOR> <LAYOUT_PATH>
```

The flag consumes exactly three following arguments and is repeatable. Using
separate arguments avoids overloading `=` or `:` characters that may legally
occur in an entity id or path. Shell glob expansion is avoided by quoting glob
selectors.

Examples:

```bash
boris --theme themes/docs \
  --layout-rule default id:index themes/docs/layouts/home.html \
  --layout-rule default 'glob:reference/*' themes/docs/layouts/reference.html \
  --layout-rule default role:trunk themes/docs/layouts/section.html
```

```bash
boris \
  --target public=dist/public \
  --target-layout public=themes/docs/layouts/main.html \
  --target preview=dist/preview \
  --target-layout preview=themes/plain/layouts/main.html \
  --layout-rule public id:index themes/docs/layouts/home.html \
  --layout-rule preview role:trunk themes/plain/layouts/compact.html
```

Rules may appear before or after their `--target` and `--target-layout`
declarations. Boris collects all declarations, synthesizes the single target
named `default` when applicable, sorts targets by canonical name, attaches
rules, and then validates. An unknown rule target is a usage error. When named
`--target` declarations are present, no implicit `default` target is created.

`--layout-rule` is HTML-only, implies explicit HTML mode like
`--target-layout`, and conflicts with IR, RAG, Context Bundle, `check`, and
`impact` modes. The first slice accepts at most 256 rules per target; excess
rules are a usage error rather than an unbounded allocation surface.

### 2.3 Why CLI first

Boris has no general project-config contract today. A layout-only manifest
would create a second target-configuration path before the complete site
configuration model is known. Repeatable CLI rules extend the existing target
surface with the least new machinery and can be persisted in a documented
invocation or CI configuration.

A future Boris-owned config file may represent these rules only if it preserves
the selector grammar, precedence, duplicate rejection, limits, and canonical
in-memory ordering defined here. It must not reinterpret page frontmatter or
make rule declaration order significant.

## 3. Selector grammar and matching

Selection runs against the frozen, validated page graph. Exact and glob rules
match the final canonical entity id, not the source filename. Role rules use
the resolved `trunk` or `satellite` role; they do not infer a second hierarchy.

| Selector | Valid form | Match rule |
|---|---|---|
| Exact id | `id:<entity-id>` | Byte-exact, case-sensitive equality with the final entity id. |
| Glob | `glob:<segment-pattern>` | Byte-exact, case-sensitive segment match. A segment exactly equal to `*` matches one non-empty entity-id segment. |
| Role | `role:trunk` or `role:satellite` | Match the existing graph role after parent validation. |

Glob patterns follow entity-id path shape: `/` is the separator; absolute,
empty, `.`, `..`, and backslash segments are invalid. `*` is special only as
an entire segment. Partial wildcards such as `ref*`, recursive `**`, regular
expressions, character classes, and brace expansion are rejected in this
slice. An entity id containing a literal `*` can still be addressed by an
exact `id:` selector.

Rules are data, not templates. Selectors cannot query title, status, tags,
body text, headings, layout output, environment variables, or generated files.

## 4. Precedence and ambiguity

For each `(target, page)` pair, choose the layout in this order:

| Rank | Candidate | Decision rule |
|---:|---|---|
| 1 | Exact id rule | The sole exact rule for the page id wins. |
| 2 | Glob rule | The matching glob with the greatest count of literal segments wins. |
| 3 | Role rule | The sole rule for the page's resolved role wins. |
| 4 | Target fallback | Existing `--target-layout NAME=PATH`, when set. |
| 5 | Global fallback | Existing `--html-layout PATH`, including `--theme ROOT` sugar. |
| 6 | Product default | `layouts/main.html`. |

Each exact selector value and each role selector may be declared at most once
per target; different exact entity ids may have different rules. Duplicate
selectors are rejected even if they name the same layout. When no exact rule
matches, glob specificity is the number of literal segments. If two or more
matching globs have the same specificity, selection is ambiguous and the
invocation fails with a usage error, even when the tied rules name the same
layout.

For example, both `glob:reference/*` and `glob:*/configuration` match
`reference/configuration` with one literal segment. That is an error, not an
argument-order tie-break. `glob:reference/*` beats `role:satellite` for the
same page. `id:reference/configuration` beats both.

If no rule matches, normal fallback applies. If a winning rule names an
invalid, missing, or unreadable layout, Boris reports that failure; it does
not silently try the next rule or fallback layout.

Canonical rule order is `(target name, selector rank, selector bytes,
normalized layout path)`, all ascending bytewise where applicable. This order
is used for diagnostics, planning, and configuration digests, never as match
precedence.

## 5. Planning and deterministic failures

The coordinator retains the existing sequential graph phases and adds a
selection phase before bounded page workers:

```text
parse CLI and rules
  -> validate/sort targets and static rule grammar
  -> discover, parse, resolve, and freeze the content graph
  -> select a layout for every target/page in canonical order
  -> build immutable per-target layout/theme plans
  -> fingerprint and choose dirty pages
  -> render with bounded workers
  -> commit each target through its existing staging boundary
```

Workers receive an immutable selected layout and never mutate rule tables,
the frozen graph, theme inventory, or shared output state.

### 5.1 Error classes

| Failure | Classification and exit | Publication behavior |
|---|---|---|
| Missing rule argument, unknown selector kind, invalid glob, rule limit exceeded | `EUSAGE`, exit 2 | Abort before discovery or output/cache mutation. |
| Duplicate selector, unknown target, mixed/cross-theme target rule | `EUSAGE`, exit 2 | Abort before discovery or output/cache mutation. |
| Equal-specificity matching globs | `EUSAGE`, exit 2 | Detect while selecting canonical target/page pairs; abort before any target publishes. |
| Invalid page frontmatter or graph | Existing content diagnostic, exit 1 | Shared graph failure aborts all targets before selection/publication. |
| Missing or unreadable declared layout | Existing I/O classification, exit 3 when pure I/O | Preserve the affected target's prior final output/cache. |
| Invalid layout UTF-8/marker/asset reference or invalid theme bytes | Existing content/layout classification, exit 1 | Preserve the affected target's prior final output/cache. |
| Target/output/layout overlap or target symlink | Existing target configuration classification, exit 2 | Abort before discovery or publication. |

Existing diagnostic categories remain closed; implementation must not invent a
new stable code without a contract amendment. New CLI/config failures use
`EUSAGE`. Existing layout error names and exit mappings remain unchanged.

Diagnostics for rule failures include the canonical target name, selector,
normalized workspace-relative layout path, and entity id when ambiguity is
page-dependent. Multiple diagnostics are sorted by `(target, entity id,
selector, layout path)`. `--quiet` suppresses text only; exit behavior and
artifact preservation are unchanged.

Static rule/configuration failures are global and prevent all publication.
After valid selection, target-local layout or I/O failures retain the existing
multi-target policy: the failing target keeps its previous output, while an
independent valid target may finish and publish; the aggregate exit remains
nonzero.

## 6. One theme and asset owner per target

Layout selection must not become theme selection. For every target, derive and
normalize the theme root of its fallback layout and every rule layout using the
existing `.../layouts/<file>.html` convention.

Exactly one of these plans is valid:

1. **Managed target:** every fallback/rule layout derives the same non-null
   theme root.
2. **Legacy target:** every fallback/rule layout is an unmanaged legacy layout
   with no derived theme root.

Mixing managed and legacy layouts or selecting layouts from two managed roots
within one target is a usage error. Different targets may use different roots.
A shared read-only theme input is allowed, but each target still owns its
output assets, stage, cache, and manifest.

All distinct declared layouts are normalized, deduplicated by resolved path,
loaded at most once per target plan, and split with the existing closed marker
parser. A declared layout is validated even if the current content tree does
not select it, so a stale rule cannot hide a broken template. No layout file is
auto-discovered merely because it exists below `layouts/`.

For a managed target:

- one theme-wide `footer.html` remains the value of `{{footer}}` for all
  selected layouts;
- one sorted theme `assets/` inventory is copied to the target;
- every selected layout resolves `{{asset-url ...}}` against that same
  inventory;
- page/asset collision checks use the complete page output set and complete
  theme inventory;
- orphan asset scrub remains target-wide after successful publication; and
- CSS and other asset bytes remain opaque and are never parsed, rewritten,
  fetched, or built by Boris.

For a legacy target, existing behavior remains: no theme-owned footer/assets,
no asset scrub, and `asset-url` still fails because no managed theme root
exists. Layout rules do not create per-page asset namespaces or merge themes.

## 7. Multi-target isolation

Each immutable target plan contains:

```text
target name and output root
fallback layout
canonical target-owned rule table
selected layout per entity id
deduplicated loaded layouts
single theme identity and asset inventory, if managed
target-owned stage and cache namespace
```

Selection is evaluated independently for every target over the same frozen
page graph. The same page may use `home.html` in `public` and `compact.html` in
`preview`; neither target reads the other's layout, generated HTML, assets,
stage, or cache. Canonical target-name order remains the execution and
diagnostic order.

Page workers may be shared as the existing bounded `--jobs` mechanism permits,
but a job is target-keyed and receives only its target's selected layout and
theme bundle. Layout rules do not authorize concurrent target commits or a new
shared-mutable concurrency path.

## 8. Cache, fingerprint, and watch effects

### 8.1 Canonical configuration material

The target manifest records a canonical digest of its parsed rule table for
diagnostics and re-planning. The digest uses length-delimited, bytewise-sorted
fields and normalized workspace/theme-relative paths. It contains no absolute
machine path, timestamp, argv declaration order, filesystem enumeration order,
or network response.

Changing only the order of equivalent `--layout-rule` flags must produce the
same plan digest and output bytes.

### 8.2 Per-page fingerprints

Each target/page cache record stores the effective selected layout identity.
The page render fingerprint includes:

- all existing source, transitive include/reference, graph-chrome, and target
  inputs;
- normalized identity and bytes of the effective selected layout;
- the theme footer bytes when that selected layout uses `{{footer}}`;
- each `asset-url` path and referenced asset bytes in that layout; and
- existing target-keyed cache discrimination.

The complete rule table is not hashed into every page render fingerprint.
Instead, every invocation re-evaluates selection and compares the resulting
effective layout with the prior target/page record. This gives the required
dirtying behavior:

| Change | Dirty/publish effect |
|---|---|
| Reorder equivalent rules | No page dirty; plan and output identical. |
| Add/change a rule that changes no page's effective layout | No page HTML dirty. |
| Rule changes a page from layout A to B | That target/page is dirty. |
| Layout A bytes change | Pages selecting A are dirty; pages selecting B are not. |
| Footer changes | Pages whose selected layout uses `{{footer}}` are dirty. |
| Referenced asset changes | Pages whose selected layout references it are dirty; asset recopied. |
| Unreferenced asset inventory/bytes change | Target asset publication/manifest updates; page HTML need not be dirty. |
| Page id or role changes | Selection is recomputed in every target; pages whose effective render inputs change are dirty. |

Cache records remain target-keyed; an equal entity id and layout bytes in two
targets do not permit cross-target reuse. Because the cache manifest gains a
per-page selected-layout field, implementation should bump the HTML cache
format discriminator (recommended `boris-cache-v2-layout-rules`) and perform a
safe one-time cold rebuild. This is not an IR schema change.

### 8.3 Watch mode

Watch observes every configured layout path and the existing managed theme
footer/assets. A changed layout fans out only to targets that declare it and
pages that select it. Theme asset and content changes retain the dependency
behavior above. Rules are argv configuration and therefore immutable for the
life of a watch process; changing a persisted invocation requires restarting
watch. A future config-file watcher is outside this slice.

## 9. Migration and backward compatibility

Adoption is additive:

1. With no `--layout-rule`, selection and output remain exactly the current
   one-layout-per-target behavior.
2. Existing `--html-layout`, `--target-layout`, `--theme`, bare `boris`, and
   `layouts/main.html` retain their meanings and form the fallback chain.
3. Existing layouts need no new marker. `{{content}}` remains required exactly
   once; all optional markers retain current semantics.
4. A legacy site may add multiple unmanaged layout files and exact/glob/role
   rules without adopting assets. It retains legacy no-theme behavior.
5. A site needing managed assets first moves layouts under one theme root,
   verifies the current one-layout build, then adds rules whose paths remain
   under that root.
6. Multi-target sites add rules one target at a time. There is no implicit rule
   inheritance between targets.
7. The first incremental build after the cache-format bump is cold; subsequent
   builds regain selective reuse. Published HTML identity and IR/RAG schemas do
   not change merely because the cache format changes.

No migration adds `layout`, `template`, `parentEntry`, or `parent_entry` to
author source. Existing unknown-key failures remain intentional. No fallback
alias or compatibility parser is introduced.

## 10. Explicit non-goals

- A `layout` or `template` frontmatter key, full YAML, or a second author
  metadata dialect.
- A general Boris project manifest in the first slice.
- Template conditionals, loops, expressions, imports, arbitrary partials,
  user-defined functions, runtime hydration, or executable/unbounded MDX.
- Selector queries over tags, status, title, body text, headings, environment,
  or generated output.
- Recursive `**`, regex, CSS-selector, or declaration-order rule semantics.
- Silent fallback when a winning layout is missing or invalid.
- Per-page theme roots, merged asset inventories, target-to-target assets, or
  generated output as an input.
- CSS parsing/rewriting, Tailwind/DaisyUI execution, Node/bundler integration,
  live CDN fetching, or external stylesheet policy changes.
- New IR `layout` or `asset` edge kinds under schema `0.2.0`; those remain the
  deferred F10 decision.
- A new scheduler, unbounded workers, or target-parallel publication.

## 11. Acceptance matrix

The implementation is accepted only when contract fixtures cover the matrix
below in full, incremental, repeated incremental, and relevant `--jobs` modes.

| Case | Expected result |
|---|---|
| No rules | Existing fallback layout and HTML bytes remain unchanged. |
| Exact id plus matching glob/role | Exact layout wins. |
| Two matching globs with different literal counts | More literal segments wins. |
| Equal-specificity matching globs | Exit 2; target/page/selectors named; no target publishes. |
| Role plus fallback | Trunk/Satellite rule wins; unmatched role uses fallback. |
| Duplicate exact, glob, or role selector | Exit 2 independent of whether layout paths are equal. |
| Rule flags permuted | Same canonical plan digest, diagnostics, HTML, assets, and cache manifest bytes. |
| Unknown rule target | Exit 2 before discovery/publication. |
| Malformed/unsupported selector or 257th rule | Exit 2 before discovery/publication. |
| `layout:` or `template:` frontmatter | `EFRONTMATTER`, exit 1; no alias accepted. |
| Final `id:` override | Exact/glob selection uses the override, not source path. |
| Parent edit changes role | Graph revalidates; selection changes deterministically or graph failure blocks it. |
| Winning layout missing | Exit 3 for pure I/O; no fallback and prior target output/cache preserved. |
| Winning/declaration-only layout has invalid marker or UTF-8 | Exit 1; no fallback and prior target output/cache preserved. |
| Managed layouts share one root | One footer/assets inventory is used and copied once per target. |
| Managed layouts cross roots or mix with legacy | Exit 2 before publication. |
| Referenced asset missing/collides/is symlink | Existing fail-closed F9 behavior; no affected target commit. |
| Orphan asset removed or renamed | Successful managed publish scrubs the old target-owned asset. |
| Public and preview use different rules/themes | Each emits its own expected layout/assets/cache; no leakage. |
| One target has target-local layout I/O failure | Its prior output remains; independent valid target may publish; aggregate nonzero. |
| Rule change affects one page | Only that target/page is re-rendered; repeated run is a cache hit. |
| Layout A changes | Only pages selecting A are re-rendered; target asset behavior remains correct. |
| Equivalent sequential, `--jobs`, and repeated `--jobs` builds | HTML/assets/manifests are byte-identical. |
| IR/RAG/Context invocation with a layout rule | Exit 2; no schema or artifact change. |
| Watch layout edit | Only declaring targets and selecting pages rebuild; no output-loop event. |

At minimum, the future implementation gate runs:

```bash
zig build
zig build test
zig build test-apex-hostile
zig build package
./scripts/release-gate.sh
```

Sanitizer evidence is reported separately; a skipped or unavailable sanitizer
is never called a pass.

## 12. Staged implementation plan

### Stage 0 — contract closure

- Amend `templating-and-themes.md` §4/§12 with this CLI grammar, role selector,
  precedence, one-theme-per-target rule, and acceptance behavior.
- Amend multi-target, watch, HTML-cache, diagnostics/help, and migration docs
  only where their normative surfaces change.
- Add a changelog bullet under Unreleased. Do not change IR schema or add IR
  edge kinds.

### Stage 1 — CLI and canonical rule model

- Add bounded rule storage to CLI options and target specs.
- Parse three-argument repeatable rules, attach them after target synthesis,
  reject unknown targets/duplicates, and canonicalize order.
- Add CLI unit tests for flag order, selector grammar, conflicts, limits, and
  `default` behavior. Existing rule-free CLI tests remain unchanged.

### Stage 2 — frozen-graph selector planner

- Add a pure selector module over canonical entity id and resolved graph role.
- Resolve all target/page choices in stable target/id order before workers.
- Reject equal-specificity glob matches with deterministic `EUSAGE` context.
- Test exact/glob/role precedence, case/byte behavior, id overrides, and
  declaration-order independence without filesystem rendering.

### Stage 3 — target layout/theme plans and rendering

- Deduplicate/load declared layouts once per target and enforce a single
  managed root or all-legacy plan.
- Pass immutable selected layouts into existing compile/assemble workers.
- Preserve current slot, footer, asset-url, collision, staging, and orphan
  scrub behavior for each target.
- Add a focused multi-layout theme fixture plus adversarial cross-root,
  invalid-layout, missing-asset, and ambiguity cases.

### Stage 4 — cache and watch integration

- Bump the HTML cache format and store effective selected layout per page.
- Canonically digest rule plans without hashing the whole rule table into every
  page render key.
- Extend dirty-set and watch fan-out to selected layout consumers while keeping
  page/target cache namespaces isolated.
- Compare full, incremental, repeated incremental, sequential, and repeated
  parallel output on identical inputs.

### Stage 5 — release closure

- Add fixture commands to the release gate and run the independent gates in
  the acceptance matrix before the aggregate gate.
- Update help, README/STATUS/CHANGELOG, migration guidance, and normative
  contracts in the implementation change set.
- Record measured behavior only. Keep external CSS, DaisyUI, and IR layout/
  asset edges deferred unless separately contracted.

## 13. Approval checklist

Implementation may begin when maintainers accept these five decisions:

1. CLI-only first surface: `--layout-rule TARGET SELECTOR LAYOUT_PATH`.
2. Closed selectors: exact id, one-segment glob, and existing graph role.
3. Precedence: exact > most-specific glob > role > existing fallback.
4. One managed theme root (or all legacy layouts) per target.
5. Per-page effective-layout cache identity with an HTML cache-format bump,
   and no IR schema change.
