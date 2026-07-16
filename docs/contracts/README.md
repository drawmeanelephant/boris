# Contracts

This directory holds **normative machine contracts** for Boris: schemas,
acceptance rules, diagnostics codes, and related specifications that future
implementations must match.

## Status note

Normative contracts are in force. Implementation status and the post-P2/P3
roadmap are tracked in [`docs/STATUS.md`](../STATUS.md). Presence of a contract
is **not** proof that every surface is the default CLI product.

| Layer | Status (post-P2 / post-P3) |
|-------|-------------|
| Normative docs under `docs/contracts/` | **In force** |
| Fixture corpus under `fixtures/` | **Inventory + IR/RAG goldens + tests** |
| Compiler IR on CLI (`--out` / `--no-rag`) | **Implemented** (opt-in; not bare default) |
| Optional product RAG (`--rag`) | **Implemented** (includes `:::kind` export) |
| Aside component tokenizer | **Implemented** (`components.md`) |
| Apex C ABI + Zig wrapper | **Implemented** (ApexMarkdown Unified host adapter; U1–U17 tested) |
| HTML path (default CLI) | **Implemented** — bare `boris` → `dist/`; also `--html` / `--html-dir` / `--target` |
| P2 dependency indexes / incremental HTML | **Implemented** (`--incremental`; fingerprints + affected set) |
| Parallel HTML workers / watch | **Implemented** (`--jobs`, `--watch`; see contracts below) |
| Multi-target isolated outputs | **Implemented** — CLI, isolation, stage commit, selective watch (P3.3) |
| HTML `dist/` default CLI | **Implemented** (Feature 2) |
| Templating + theme assets (F9.1 / F9.2) | **Implemented** — closed plan, target-owned assets, UTF-8 layout gate, orphan asset scrub; see `templating-and-themes.md` |
| Semantic relations (IR 0.3) | **Implemented** — bounded author relations with deliberate schema change; see `semantic-relations.md` |
| AI Context Bundle (`--context`) | **Implemented** — deterministic provenance-rich export; see `context-bundle.md` |
| Includes + wiki-links (HTML) | **Implemented** — pre-Apex; see `includes-and-wiki-links.md` |
| IR 0.2 dependency edges + reverse index | **Implemented (F8.1–F8.3 shipped)** — `--out` emits typed edges and `reverseIndex`; incremental HTML uses the same reverse-walk dirty-set (v0.3.1) |
| Documentation Intelligence | **Implemented first slice** — `check` / `impact`; see [documentation-intelligence.md](documentation-intelligence.md) |

## Canonical ownership (one document per topic)

Use **only** these files as normative sources of truth. One canonical owner
per topic:

| Topic | Canonical normative document |
|-------|------------------------------|
| Frontmatter grammar | [frontmatter.md](frontmatter.md) |
| Source paths and entity IDs | [identity-and-paths.md](identity-and-paths.md) |
| Discovery / scanning | [scanner.md](scanner.md) |
| Parent / graph validation (Trunk / Satellite) | [ir-schema.md](ir-schema.md) (graph section); `parent` field shape in [frontmatter.md](frontmatter.md) |
| JSON IR (manifest, graph, build-report) | [ir-schema.md](ir-schema.md) |
| Diagnostics | [diagnostics.md](diagnostics.md) |
| RAG export | [rag-export.md](rag-export.md) |
| Aside / components | [components.md](components.md) |
| Apex C ABI | [apex-abi.md](apex-abi.md) |
| HTML output (default CLI) | [html-output.md](html-output.md) |
| Parallel rendering | [parallel-rendering.md](parallel-rendering.md) |
| Watch Mode | [watch-mode.md](watch-mode.md) |
| Multi-target isolated outputs | [multi-target-isolated-output.md](multi-target-isolated-output.md) |
| Includes + wiki-links | [includes-and-wiki-links.md](includes-and-wiki-links.md) |
| Heading IDs + wiki fragments | [heading-ids.md](heading-ids.md) |
| Templating + themes (F9.1 / F9.2) | [templating-and-themes.md](templating-and-themes.md) |
| Semantic relations (IR 0.3) | [semantic-relations.md](semantic-relations.md) |
| AI Context Bundle | [context-bundle.md](context-bundle.md) |
| Documentation Intelligence | [documentation-intelligence.md](documentation-intelligence.md) |

### Normative documents (IR v0.2 target) — full list

| Document | Topic |
|----------|-------|
| [frontmatter.md](frontmatter.md) | Closed frontmatter grammar; keys `id`, `title`, `parent`, `status`, `tags` only |
| [identity-and-paths.md](identity-and-paths.md) | Source paths, entity ids, `/` separators, `.md`/`.mdx` case rules |
| [scanner.md](scanner.md) | Deterministic discovery walk, sort key, symlink policy (m4) |
| [diagnostics.md](diagnostics.md) | Stable categories (`EDUPLICATEID`, …), severity, exit codes |
| [ir-schema.md](ir-schema.md) | Trunk/Satellite graph, typed dependency edges, reverse index, deterministic JSON under `.boris/` |
| [rag-export.md](rag-export.md) | Optional RAG export; schema versioning; `:::kind` export-only |
| [components.md](components.md) | Constrained `<Aside>` tokenizer, kinds, id grammar, nested policy (m10) |
| [apex-abi.md](apex-abi.md) | In-process Apex C ABI, allocator lifetime, Zig error rules (m8) |
| [html-output.md](html-output.md) | HTML Whiteboard, Aside stream, layout splice, Atomic publish (default CLI) |
| [parallel-rendering.md](parallel-rendering.md) | Bounded worker pool parallel rendering, thread/memory isolation, deterministic order |
| [watch-mode.md](watch-mode.md) | Opt-in watch mode, event coalescing/normalization, rebuild serialization, safe recovery |
| [multi-target-isolated-output.md](multi-target-isolated-output.md) | Multi-target CLI/config, output isolation, cache namespaces (P3.3) |
| [includes-and-wiki-links.md](includes-and-wiki-links.md) | `{{include}}` + `[[wiki]]` pre-Apex; cycles; fragment tree; IR 0.2 edge projection |
| [heading-ids.md](heading-ids.md) | Apex heading `id` harvest; `[[entity#heading]]` match + URL rules |
| [templating-and-themes.md](templating-and-themes.md) | Closed layout plan, theme assets, UTF-8/orphan hardening (F9.1 / F9.2) |
| [semantic-relations.md](semantic-relations.md) | Bounded author relations and deliberate IR 0.3 schema plan |
| [context-bundle.md](context-bundle.md) | Deterministic provenance-rich AI context export (`--context`) |
| [documentation-intelligence.md](documentation-intelligence.md) | Read-only graph health and impact analysis (`check` / `impact`) |

## Redirect / compatibility paths (non-normative)

These filenames are **not** competing contracts. They exist only so old links
do not go dark. They carry **no** independent normative claims. On any
conflict, the canonical document **wins**.

| Compatibility path | Redirects to (canonical) |
|--------------------|--------------------------|
| [parent-relationships.md](parent-relationships.md) | [ir-schema.md](ir-schema.md) (graph); [frontmatter.md](frontmatter.md) for `parent` key |
| [source-path-and-id.md](source-path-and-id.md) | [identity-and-paths.md](identity-and-paths.md) |
| [json-ir-and-manifest.md](json-ir-and-manifest.md) | [ir-schema.md](ir-schema.md) |

Supporting / historical drafts may also remain in this tree. Prefer linking the
**canonical** names from new work.

| Supporting (non-normative) | Role |
|----------------------------|------|
| [acceptance.md](acceptance.md) | v0.1 acceptance checklist |
| [v0.1-overview.md](v0.1-overview.md) | Orientation; points at canonical contracts |
| [../STATUS.md](../STATUS.md) | Living status + next work |
| [`../../archive/`](../../archive/) | Historical reviews/audits (not normative; optional) |

## Fixture corpus

Machine-oriented content fixtures live at the **repository root**:

```text
fixtures/
  manifest.json          # inventory + expected invalid categories
  content/valid/         # pages that must compile cleanly (when implemented)
  content/invalid/       # pages that must fail with a documented category
  expected/              # stable notes useful before IR goldens exist
```

Tests: `src/fixtures_test.zig` — inventory only (paths + categories). Compiler
runs against contract fixtures / hardening suites separately (`pipeline`,
`hardening_test`, release-gate).

## Rules of use

1. **Contracts are normative.** If code and contracts disagree, fix the code or
   deliberately amend the contracts (with a version bump when IR shape changes).
2. **Narrative docs are not contracts.** Architecture stories, RAG seeds, and
   README prose describe intent; they do not substitute for machine-checked
   fixtures and tests.
3. **Presence of a doc is not presence of a feature.** Do not treat a contract
   as evidence that the binary implements it.
4. **Author-facing parent key is only `parent`.** Never document `parentEntry`
   as accepted compiler frontmatter.
5. **Redirect paths are not sources of truth.** Cite the canonical file from
   the ownership table above, not a compatibility redirect.

## Explicit non-goals (remaining)

- Markdown-native `:::` **authoring** (export representation only)
- Generic multi-component systems / MDX / unrestricted executable content
- Full YAML frontmatter
- Child-process markdown rendering (forbidden; see apex-abi.md)
- Unbounded shared-mutable concurrency outside the documented HTML `--jobs`
  contract (IR/RAG and pre-render coordinator phases stay sequential)
