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
- Self-audit: [`docs/AUDIT-v0.1.md`](docs/AUDIT-v0.1.md).
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
| `[0.1.1]` | Doc↔code reconciliation + release gate; product `boris/0.1.1` |
| `[0.1.0]` | First content-compiler checkpoint |
| Later `0.1.x` | Fixes/docs within same IR minor if schema stays `"0.1.0"` |
| `0.2.0` / new `schemaVersion` | Deliberate IR or product phase bump |
