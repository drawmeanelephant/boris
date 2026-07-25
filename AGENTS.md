# Agent rules — Boris

This file is binding project policy for AI coding agents (and humans pairing with them).

## Session start (read this first)

1. Skim [`docs/STATUS.md`](docs/STATUS.md) for current phase, known gaps, and module map.
2. Skim the top of [`CHANGELOG.md`](CHANGELOG.md) (`[Unreleased]` + latest release).
3. For compiler semantics, open the relevant file under [`docs/contracts/`](docs/contracts/) — those docs are **normative**.
4. Run `zig build test` (or `./scripts/release-gate.sh` for IR-facing work) before and after substantive changes.

## Codex / ChatGPT review rules

Use this protocol for repository audits, release reviews, and reviews based on an
external AI packet. It supplements the implementation rules below; it does not
turn a review-only request into permission to edit product code.

### Scope and authority

- Resolve the requested mode first: **review only**, **review plus agent/docs
  guidance**, or **implement fixes**. In review-only mode, do not patch a defect
  merely because the fix looks small. Explicitly requested `AGENTS.md` or review
  guidance may still be edited without widening permission to product code.
- Treat external review packets as leads, not repository truth. Record their
  stated release/version, then compare it with code, canonical contracts,
  `docs/STATUS.md`, and `CHANGELOG.md`. Stale module spellings, commands, or
  version claims are packet drift, not product defects.
- Use this evidence order: executable behavior and current code → canonical
  `docs/contracts/` → this file → `docs/STATUS.md` → `CHANGELOG.md` → release
  gate docs/scripts → README and narrative RAG seeds → external/historical notes.
- Do not cite a contract or passing happy-path smoke as proof of implementation.
  Verify the relevant code path, test, fixture, or black-box behavior.

### Finding discipline

Classify every material observation as exactly one of:

- **Confirmed defect** — reproduced failure, unsafe reachable code path, or a
  direct code/contract contradiction.
- **Likely defect** — strong code-path evidence, but no reliable reproduction.
- **Insufficient evidence** — a material claim cannot be established by the
  available tests, code, or environment.
- **Documented limitation** — behavior matches an explicit current limitation.
- **Non-issue / packet drift** — concern is contradicted by current authoritative
  evidence or applies only to stale briefing text.

For actionable findings, report: severity, classification, exact locus,
evidence/reproduction, user or release impact, the smallest remediation card,
and the verification command. Keep speculative hardening separate from defects.

### Gate and environment handling

- Capture the initial `git status --short`; preserve unrelated work and report
  whether review commands created ignored/generated artifacts.
- Run the smallest relevant gates independently before the aggregate gate so a
  single failure does not hide other evidence. For microreleases, normally check
  `zig build`, `zig build test`, `zig build test-apex-hostile`,
  `zig build test-apex-sanitize`, `zig build package`, and then
  `./scripts/release-gate.sh` when scope permits.
- Distinguish a real failure from sandbox/tooling interference. A Zig global-cache
  `PermissionDenied`, unavailable sanitizer, or denied symlink operation is not
  a product failure; rerun with an allowed cache/location or report the exact
  evidence boundary. A sanitizer skip is never a sanitizer pass.
- When a test's cleanup path panics after an earlier assertion/error, report the
  primary failure and the masking cleanup defect separately. Do not weaken or
  delete the test to make the gate green; preserve the underlying signal.
- For concurrency or determinism claims, compare sequential output, parallel
  output, and a repeated parallel run on the same input. A passing small smoke
  narrows a stress-test failure but does not overrule it.
- A required gate that reproducibly fails is a ship blocker until fixed or the
  release claim is explicitly narrowed in current docs/contracts.

## Git and Sandbox Safety

- **Commit early, commit often:** To prevent automated environment or sandbox sync events from resetting local progress, make small, incremental git commits as milestones are reached rather than waiting for the entire milestone to finish.
- **Recovery of lost work:** If the working copy is accidentally reset or wiped, remember that the IDE preserves a byte-perfect, chronological history of every single code write and replacement chunk under:
  `<appDataDir>/brain/<conversation-id>/.system_generated/logs/transcript_full.jsonl`
  Run or write a quick Python script to parse and replay the chronological `write_to_file` and `replace_file_content` calls to automatically heal the workspace.

## Branch discipline (multi-agent)

`main` is the integration line. Agents and humans do not share a dirty working
tree on `main` as a default workspace. Treat concurrent agent sessions as
separate writers that must not land on top of each other without a merge base.

### Hard rules for agents

1. **Never commit or push directly to `main`** unless the user explicitly orders
   a direct land (hotfix, docs-only fast path they named). Default path is a
   topic branch → PR → merge.
2. **Start every substantive task on a fresh branch** from up-to-date `main`:
   `git fetch origin && git checkout main && git pull --ff-only && git checkout -b <name>`.
3. **Branch names:** short, owned prefix when useful — `codex/…`, `grok/…`,
   `feat/…`, `fix/…`, `docs/…`, `chore/…`. One concern per branch.
4. **Do not rewrite shared history** on `main` or on someone else's published
   branch (`push --force`, `reset --hard` of published commits) unless the user
   explicitly requests it.
5. **Before starting work,** check `git status`, current branch, and whether
   another agent already owns the files you need. If `main` moved, rebase or
   merge your topic branch before opening/updating a PR.
6. **One agent owns a branch** until it is merged or abandoned. Do not two-write
   the same branch or the same hot files without an explicit handoff.
7. **Land via PR** when remote collaboration or CI matters. Preferred merge is
   squash or merge commit per repo default; keep history readable. After merge,
   delete the topic branch and return local checkout to `main`.
8. **Generated / ignored outputs** (`dist/`, `rag/`, `source-rag/`, zig cache)
   are not branch currency — do not commit them to “win” a merge.

### Intended GitHub protection on `main`

When the hosting plan allows repository rulesets or classic branch protection
(private repos need **GitHub Pro**; public repos can use free rulesets), enable:

| Rule | Setting |
|------|---------|
| Target | `refs/heads/main` only |
| Direct pushes | Blocked (require pull request) |
| Force push | Blocked (`non_fast_forward`) |
| Branch deletion | Blocked for `main` |
| Stale reviews | Dismiss on new push |
| Required approvals | `0` while solo (raise when co-maintainers exist) |
| Required status checks | CI job(s) from `.github/workflows/ci.yml` once stable green |
| Admin bypass | Allowed for repo admin during bootstrap; narrow later |

Until GitHub enforces the above, **these AGENTS rules are binding** for every
coding agent in this repo. Do not treat a missing GitHub lock as permission to
drive-by `main`.

| Doc | Role |
|-----|------|
| `README.md` | Human front door — outcomes + CLI |
| `AGENTS.md` (this file) | Hard constraints and long-term direction |
| `docs/STATUS.md` | Living “where we are” + next work |
| `docs/RELEASE-GATE.md` | Mechanical ship checks; `scripts/release-gate.sh` |
| `CHANGELOG.md` | What changed; add bullets under Unreleased as you land work |
| `docs/contracts/` | Normative IR, frontmatter, graph, diagnostics, fixtures |
| `docs/rag/system/` | Curated narrative seeds (product RAG) |
| `content/AGENT-DIRECTIVE.txt` | Sample-content rebuild brief (not a site page) |
| ~~`archive/`~~ | **Removed** — historical reviews/audits no longer in-tree |
| `rag/` | **Generated** product corpus — do not treat as source of truth |
| `tools/source-rag/` | Standalone **source-code** RAG tool (`zig build source-rag`) |
| `source-rag/` | **Generated** source pack — gitignored |

## Identity

**Boris is a Zig documentation compiler:** Markdown in → validated graph → HTML
site (default), JSON IR, or RAG pack. Not a Node SSG stack.

Named for the folk **Zouave** improviser known as **Boris** (calm under fire,
practical chain-thinking, wipe-and-continue) — independent homage, **not**
affiliated with any commercial tobacco or rolling-paper brand. Teaching rhythm:
**Load → Roll → Ignite → Reset**. Narrative:
[`docs/rag/system/10-name-and-metaphor.md`](docs/rag/system/10-name-and-metaphor.md).

- **User outcomes first:** a shippable `dist/` site, real Apex Markdown, fail-loud
  Trunk/Satellite graph, optional IR/RAG — see README/STATUS, not spark-plug tours.
- **Default CLI:** `boris` → HTML under `dist/`. IR via `--out` / `--no-rag`. RAG via `--rag`.
- **Language:** Zig **0.16+**. Markdown: **Apex** linked **in-process** (C ABI host
  adapter). **Not** a subprocess, **not** a JS markdown pipeline.
- **Content model:** Trunk / Satellite pages + in-page **Aside** tokens (not graph nodes).
- **Performance shape:** lean per-page publish (stream layout + body; wipe page
  scratch; optional incremental/parallel). Prefer measured claims over slogans.
- **Metaphor → engineering:** Load = discover; Roll = frontmatter + graph; Ignite =
  emit/render; Reset = free page scratch. No branded component jargon (“Broside”).

### Where to edit by task

| Task | Prefer these modules |
|------|----------------------|
| Compiler IR, FM grammar, graph validation, diagnostics | `pipeline`, `discover`, `frontmatter`, `graph`, `diag`, `json_out`, `pathutil` |
| Product RAG export packaging | `src/rag.zig` (+ seeds in `docs/rag/system/`) — not on m1 default CLI |
| Source pack for LLM notebooks | `tools/source-rag/` (`zig build source-rag` → `source-rag/`) |
| Apex / Aside / HTML assemble experiments | `apex`, `aside`, `parser`, `compile`, `assemble`, `scanner`, `page` |

Author-facing frontmatter parent key is **`parent` only** (product parser on
IR, RAG input, and experimental HTML). Legacy names `parentEntry` /
`parent_entry` are **rejected** as unknown keys (`EFRONTMATTER`), not aliased.
RAG export may still use the field name `parent_entry` in catalog/export
packaging for the same parent id — that is not author grammar. Non-product
helpers (`frontmatter.zig` fuzz, historical `harness.zig`) must not reintroduce
a second accepted dialect. Do not “fix” one path by silently changing another
without tests.

## Hard constraints (do not violate unless the user explicitly requests a deviation)

1. **Do not introduce another application language** for Boris itself  
   No TypeScript/JavaScript app layer, no Python build stage, no Go/Rust rewrite, no Ruby plugins, no JVM services.  
   Exceptions that are already allowed:
   - **C** only for Apex (or other explicitly approved C-ABI native engines) under `vendor/`.
   - Shell one-liners only if unavoidable for local debugging — never as the product architecture.

2. **Do not institute additional frameworks or SSG stacks**  
   Forbidden by default: Next.js, Astro, Hugo, Eleventy, Gatsby, Vite/Webpack app shells, React/Vue/Svelte as the site compiler, Deno/Bun toolchains as the build system.  
   Boris *is* the compiler. External frameworks are out of scope unless the user names them and asks.

3. **Do not spawn processes to render markdown**  
   No `ChildProcess` / per-page CLI markdown. Apex (or a drop-in C-ABI successor) is called via memory pointers.

4. **Do not replace Zig’s build system**  
   Keep `build.zig` / `build.zig.zon`. Do not migrate the project to npm, cargo, cmake-as-primary, or Make-as-primary for the core product.

5. **Do not “web-app-ify” the core**  
   No requirement for Node modules, bundlers, or client hydration frameworks to produce `dist/`. Layout is HTML templates + zero-copy splice, not a component framework runtime.

6. **Stay on the phased architecture**  
   Prefer extending: scan → parse → Apex → whiteboard compile → assemble → RAG export.  
   Do not invent a parallel pipeline in another stack “for convenience.”

## Allowed without special permission

- Pure Zig modules under `src/`.
- C ABI under `vendor/` for Apex (or an explicitly approved native engine with the same integration style).
- Author content under `content/` (markdown + optional registered components such as `<Aside>`).
- HTML layouts under `layouts/`.
- Curated RAG seeds under `docs/rag/` and generated corpus under `rag/`.
- Compiler contracts under `docs/contracts/` (v0.1 content-compiler IR is normative).
- Tests via `zig build test`.
- Small static assets if needed for the site output — still produced or copied by Boris/Zig, not a JS asset pipeline.

## Explicit permission required

Before doing any of the following, **stop and get a clear user request**:

- Adding Node, Python, Rust, Go, or other language toolchains as product dependencies
- Adding a JS/TS frontend framework or alternative SSG
- Calling out to external CLI tools in the hot path (markdown, image, minify, etc.)
- Multi-threaded / multi-process redesign (the monolith is intentional for phase stability)
- Replacing Apex with a non–C-ABI or non-native approach
- Changing entity/graph semantics away from Trunk–Satellite without design agreement
- Arbitrary MDX / executable components / JS expressions in content

## When the user *does* request a deviation

- Scope it narrowly.
- Keep the Zig + Apex path working unless they asked to remove it.
- Document the exception in the PR/commit message and, if durable, in `docs/rag/system/` and a `CHANGELOG.md` Unreleased bullet.

## When you change behavior

- **Contracts first for IR:** if emit shape, frontmatter, graph rules, or diagnostics change, update `docs/contracts/` (and fixtures) in the same change set, or deliberately note temporary drift in `docs/STATUS.md`.
- **Changelog:** feature/fix PRs add one uniquely named fragment under `docs/changelog.d/` instead of editing `CHANGELOG.md`'s `[Unreleased]` section. Follow `docs/changelog.d/README.md`; the release owner assembles and removes or archives fragments at the release cut. User-visible or contract-visible work still requires one short changelog bullet, and IR work must link its updated contract.
- **Status:** update `docs/STATUS.md` when phase, primary CLI surface, or known-gap list changes — not for every tiny fix.
- **Tests:** extend fixture or unit tests under the module you touch; `zig build test` is the gate.
- **Breaking IR:** bump `schemaVersion` and `pipeline.compiler_id` / related constants; do not silently reshape `"0.1.0"`.

## Implementation taste (Zig-side)

- Prefer `std` over new dependencies.
- Prefer in-memory, single-pass, arena-friendly designs.
- Prefer explicit data structures (`Page`, frontmatter, parse-time `Aside` / component tokens) over stringly HTML soup.
- Match existing module boundaries (`scanner`, `parser`, `aside`, `apex`, `compile`, `assemble`, `rag`).
- Target current Zig APIs in this repo (0.16 `std.process.Init`, `std.Io`, unmanaged `ArrayList`, etc.) — do not regress to obsolete std patterns without cause.
- Do not brand ordinary docs features with mascot names. Use Aside, admonition, component, directive.

## Quick “should I?” checklist

| Idea | Default answer |
|------|----------------|
| Rewrite the SSG in TypeScript | **No** |
| Add React for the layout system | **No** |
| Shell out to `pandoc` / `marked` | **No** |
| Extend Apex C ABI / improve Zig pipeline | **Yes** |
| Add a Zig module for RAG / graph / new content feature | **Yes** |
| Python script to generate the RAG zip | **No** — implement in Boris (`src/rag.zig`) |
| Standalone HTML/RAG pages per aside | **No** — asides stay in document order |
| Arbitrary executable MDX components | **No** — registry + allowlisted attrs only |
| User explicitly asks for a one-off experiment in another language | Ask scope; isolate; do not make it the default path |

## Long-term build-system direction

Boris is intended to grow into a graph-native static-site build system for
large Markdown sites. Its long-term value is not a proprietary content caste
system; it is explicit, validated dependency tracking.

Model the following as typed graph edges where applicable:
- parent/child hierarchy
- Markdown includes and transclusion
- layouts and templates
- internal references
- static assets
- data files
- generated artifacts
- registered components

Store both forward and reverse dependency indexes. The reverse index is the
basis for correct incremental rebuilds.

Boris should support ordinary documentation-site features: semantic asides and
admonitions, includes, figures, tabs, details, code groups, navigation,
collections, taxonomies, layouts, assets, and explicitly registered custom
components. Avoid arbitrary executable content and unrestricted MDX semantics.

For large sites, build in stages:
1. discover and parse deterministically;
2. resolve and validate the full dependency graph;
3. freeze graph data;
4. determine cache hits and the affected build set;
5. render independent jobs in parallel with bounded resources;
6. atomically commit outputs and manifests.

Workers must not mutate the resolved graph or shared output state. Favor a
single coordinating commit phase, per-worker scratch allocation, deterministic
scheduling/output, content-addressed cache keys, and clear resource limits.

Multiple build targets may share a worker pool but must have isolated output
directories, configuration hashes, cache namespaces, and explicit cross-target
dependency rules.

Bounded HTML page workers (`--jobs`) are the only product concurrency path;
coordinator phases (discover, parse, graph freeze, fingerprint, dirty-set) stay
sequential. Do not add uncoordinated shared-mutable concurrency or low-level
I/O optimization without contracts, tests, and measured need.

## One-line north star

**Boris is a Zig static-site compiler for Markdown documentation — load, roll, ignite, reset — with validated content metadata, graph-aware navigation, semantic admonitions, and an explicit extension path for custom components — not a polyglot web framework.**

## Zig Documentation Agent Policy

### Purpose

Maintain unusually thorough, accurate, and useful documentation for the repository's first-party Zig source files.

Documentation work must improve understanding without changing program behavior.

### Scope

Documentation tasks may modify only:

* First-party `*.zig` files
* `docs/zig-docs-manifest.json`
* Documentation indexes or generated documentation configuration explicitly named in the task

Do not modify:

* Vendored dependencies
* Generated source files
* Zig cache directories
* Dependency caches
* Git submodules
* Files under directories named `vendor`, `third_party`, `deps`, `.zig-cache`, or `zig-out`, unless the task explicitly includes them

Before editing, identify which Zig files are first-party, generated, vendored, examples, tests, benchmarks, tools, or production source.

### Absolute Restrictions

Documentation-only tasks must not change:

* Runtime behavior
* Algorithms
* Control flow
* Function signatures
* Types
* Visibility such as `pub`
* Error sets
* Memory ownership
* Allocation behavior
* Build configuration
* Imports
* Tests, except for adding a documentation example specifically authorized by the task

Do not refactor code while documenting it.

Do not rename declarations, parameters, fields, files, or modules.

Do not “clean up” nearby code.

Do not fix discovered bugs during a documentation task. Report them separately.

If a documentation change appears to require a code change, stop and report the conflict instead.

### Documentation Standards

Every included Zig source file should have an accurate `//!` module-level description when the file represents a coherent module.

Module documentation should explain, where applicable:

* The module's responsibility
* Its place in the surrounding architecture
* Important entry points
* Major data flows
* Ownership and lifetime expectations
* Allocation behavior
* Error-handling strategy
* Thread-safety or concurrency expectations
* Compile-time behavior
* Platform or target assumptions
* Important invariants
* Major side effects
* Relevant security or correctness constraints
* A small usage example when a stable public entry point exists

Every public declaration should have useful `///` documentation unless it is genuinely self-explanatory and additional text would add no information.

Public function documentation should cover, where applicable:

* What the function accomplishes
* Preconditions
* Parameter semantics
* Return-value semantics
* Possible errors and their meaning
* Ownership of inputs and outputs
* Borrowing and lifetime requirements
* Whether memory is allocated
* Whether the caller must free anything
* Mutation and side effects
* Thread-safety
* Reentrancy
* Compile-time versus runtime behavior
* Complexity or performance characteristics, but only when supported by the implementation
* Edge cases
* Failure behavior
* A concise example for non-obvious APIs

Type documentation should cover, where applicable:

* What the type represents
* Valid and invalid states
* Field relationships
* Invariants
* Ownership responsibilities
* Initialization and deinitialization
* Whether values may be copied safely
* Thread-safety
* Serialization or ABI considerations
* Important lifecycle transitions

Field documentation should explain semantics, units, ranges, sentinel values, ownership, and invariants when these are not obvious.

Private declarations should be documented when they implement a non-obvious algorithm, maintain an important invariant, encode a protocol rule, or have surprising ownership or performance behavior.

### Accuracy Rules

Documentation must be derived from:

1. The implementation
2. Existing tests
3. Call sites
4. Build configuration
5. Existing repository documentation

Never invent behavior from a declaration name alone.

Never claim:

* Thread-safety without evidence
* Constant-time behavior without evidence
* Allocation-free behavior without evidence
* Stable ABI or API guarantees without evidence
* Particular complexity without inspecting the implementation
* Ownership transfer without inspecting call sites and cleanup behavior
* Platform support not demonstrated by the build configuration
* Error behavior not represented by the implementation

When behavior cannot be established confidently:

* Do not guess
* Do not insert vague assurances
* Add the uncertainty to the task report
* Leave the existing documentation unchanged if a replacement would be speculative

Use the words `assume` and `assert` consistently with Zig's documented convention for unchecked and safety-checked invariants.

Avoid documentation that merely repeats the declaration's name or type signature.

Duplicating essential behavioral information across related public declarations is acceptable when it improves editor and generated-documentation usability.

### Examples

Prefer examples that compile against the current repository.

Do not add examples that rely on imaginary APIs.

When an example can reasonably be expressed as a Zig test, prefer a small testable example, but only when the task explicitly permits adding tests.

Examples must show required cleanup such as `defer`, allocator ownership, or deinitialization.

Examples must not hide important error handling.

### Change Tracking

Maintain `docs/zig-docs-manifest.json`.

For each included Zig file, record:

* Repository-relative path
* Content hash
* Last documented commit
* Documentation status
* Last documentation review date
* Any unresolved documentation questions

The content hash must represent the source file's meaningful contents. Do not rely only on filesystem timestamps.

A recurring documentation task should process only:

* New Zig files
* Modified Zig files
* Renamed Zig files
* Files whose manifest entry is missing or invalid

Deleted files should be removed from the manifest.

A file is considered changed when its current content hash differs from the manifest.

Do not update a manifest hash unless that file was actually reviewed during the task.

### Batch Size

Initial documentation work must be divided into small, coherent batches.

A batch should normally contain no more than:

* 5 substantial Zig files, or
* 10 small Zig files

Group files by module or subsystem rather than arbitrary alphabetical slices.

Each batch must result in an independently reviewable pull request.

Do not attempt a repository-wide rewrite in one pull request.

### Validation

Use the Zig version pinned or documented by the repository.

After documentation edits:

1. Run the repository's canonical formatting check.
2. Run the repository's canonical build command.
3. Run the repository's canonical test command.
4. Generate Zig documentation when the repository provides a supported command for doing so.
5. Inspect the diff for accidental non-comment changes.

If no canonical commands are documented, determine them from `build.zig`, `build.zig.zon`, CI configuration, and existing scripts.

Do not silently substitute commands intended for a different Zig version.

A documentation task is incomplete when formatting, compilation, or tests fail because of its changes.

Pre-existing failures must be clearly distinguished from failures introduced by the documentation changes.

### Required Task Report

Every documentation task must report:

* Zig files examined
* Zig files changed
* Zig files intentionally skipped
* Why each skipped file was excluded
* Public declarations documented
* Important private declarations documented
* Unresolved ambiguities
* Potential bugs discovered but not changed
* Validation commands executed
* Validation results
* Manifest entries added, updated, renamed, or removed
* Confirmation that no behavioral code was changed
