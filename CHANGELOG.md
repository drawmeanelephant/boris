# Changelog

All notable changes to Boris are documented here.

Format inspired by [Keep a Changelog](https://keepachangelog.com/).
Versioning: product **v0.1.x** with IR `schemaVersion` **`0.1.0`** and compiler id
**`boris/0.1.1`**. Breaking IR changes must bump `schemaVersion` and update
`docs/contracts/`. Product patch bumps may update `compiler_id` / `boris_version`
without changing IR schema.

How to use going forward:

- Add bullets under **`[Unreleased]`** as you land work.
- When cutting a tag, move Unreleased into a dated section and reset Unreleased.
- Prefer one short bullet per user-visible or contract-visible change.
- Link related contracts or fixtures when the IR or acceptance surface moves.

---

## [Unreleased]

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
| `[0.1.1]` | Doc↔code reconciliation + release gate; product `boris/0.1.1` |
| `[0.1.0]` | First content-compiler checkpoint |
| Later `0.1.x` | Fixes/docs within same IR minor if schema stays `"0.1.0"` |
| `0.2.0` / new `schemaVersion` | Deliberate IR or product phase bump |
