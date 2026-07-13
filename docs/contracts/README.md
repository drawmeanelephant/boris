# Contracts

This directory holds **normative machine contracts** for Boris: schemas,
acceptance rules, diagnostics codes, and related specifications that future
implementations must match.

## Status note

Normative contracts are in force. Implementation status is tracked in
[`docs/STATUS.md`](../STATUS.md). Presence of a contract is **not** proof that
every surface is implemented (e.g. HTML `dist/` remains experimental).

| Layer | Status (m10 / v0.1 harden) |
|-------|-------------|
| Normative docs under `docs/contracts/` | **In force** |
| Fixture corpus under `fixtures/` | **Inventory + IR/RAG goldens + tests** |
| Compiler IR on default CLI | **Implemented** |
| Optional product RAG (`--rag`) | **Implemented** (includes `:::kind` export) |
| Aside component tokenizer | **Implemented** (`components.md`) |
| Apex C ABI + Zig wrapper | **Implemented** (linked + tested; not default pipeline) |
| Experimental HTML path | **Implemented** (Aside stream; not default CLI) |
| HTML `dist/` default CLI | **Not** default product |

## Normative documents (v0.1)

| Document | Topic |
|----------|-------|
| [frontmatter.md](frontmatter.md) | Closed frontmatter grammar; keys `id`, `title`, `parent`, `status`, `tags` only |
| [identity-and-paths.md](identity-and-paths.md) | Source paths, entity ids, `/` separators, `.md`/`.mdx` case rules |
| [scanner.md](scanner.md) | Deterministic discovery walk, sort key, symlink policy (m4) |
| [diagnostics.md](diagnostics.md) | Stable categories (`EDUPLICATEID`, …), severity, exit codes |
| [ir-schema.md](ir-schema.md) | Trunk/Satellite graph, deterministic JSON under `.boris/` |
| [rag-export.md](rag-export.md) | Optional RAG export; schema versioning; `:::kind` export-only |
| [components.md](components.md) | Constrained `<Aside>` tokenizer, kinds, id grammar, nested policy (m10) |
| [apex-abi.md](apex-abi.md) | In-process Apex C ABI, allocator lifetime, Zig error rules (m8) |
| [html-output.md](html-output.md) | Experimental HTML Whiteboard, Aside stream, layout splice, Atomic publish |

Supporting / historical drafts may remain in this tree; **if they conflict**,
the documents above win. Prefer linking those names from new work.

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

## Explicit non-goals (remaining)

- HTML `dist/` as default product CLI (experimental path exists; not default)
- Markdown-native `:::` **authoring** (export representation only)
- Generic multi-component systems / MDX / concurrency
- Full YAML frontmatter
- Child-process markdown rendering (forbidden; see apex-abi.md)
