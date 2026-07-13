# Contracts

This directory holds **normative machine contracts** for Boris: schemas,
acceptance rules, diagnostics codes, and related specifications that future
implementations must match.

## Milestone 2 note

Milestone 2 establishes **contracts and a fixture inventory**. The default
product CLI remains a help stub (milestone 1). Presence of a contract is **not**
proof that scanning, parsing, graph validation, Apex, RAG, or HTML output works.

| Layer | Status |
|-------|--------|
| Normative docs under `docs/contracts/` | **In force for design** |
| Fixture corpus under `fixtures/` | **Inventory + manifest tests only** |
| Compiler pipeline on default CLI | **Not implemented** |

## Normative documents (v0.1)

| Document | Topic |
|----------|-------|
| [frontmatter.md](frontmatter.md) | Closed frontmatter grammar; keys `id`, `title`, `parent`, `status`, `tags` only |
| [identity-and-paths.md](identity-and-paths.md) | Source paths, entity ids, `/` separators, `.md`/`.mdx` case rules |
| [diagnostics.md](diagnostics.md) | Stable categories (`EDUPLICATEID`, …), severity, exit codes |
| [ir-schema.md](ir-schema.md) | Trunk/Satellite graph, deterministic JSON under `.boris/` |
| [rag-export.md](rag-export.md) | Optional future RAG export; schema versioning; `:::kind` as export-only |

Supporting / historical drafts may remain in this tree; **if they conflict**,
the five documents above win. Prefer linking those names from new work.

## Fixture corpus

Machine-oriented content fixtures live at the **repository root**:

```text
fixtures/
  manifest.json          # inventory + expected invalid categories
  content/valid/         # pages that must compile cleanly (when implemented)
  content/invalid/       # pages that must fail with a documented category
  expected/              # stable notes useful before IR goldens exist
```

Tests: `src/fixtures_test.zig` — verifies fixture files exist and that the
manifest’s invalid categories are consistent. **Does not** run the compiler
against fixtures yet.

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

## Explicit non-goals (this milestone)

- Implementing scanner, parser, graph, or IR emit
- Apex / HTML output
- Product RAG generation
- Concurrency
- Full YAML frontmatter
