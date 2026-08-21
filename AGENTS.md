# Agent rules — Boris

This file is binding project policy for AI coding agents and humans pairing with
them. It is the standing field manual; detailed operating procedures live in
[`docs/AGENT-PLAYBOOK.md`](docs/AGENT-PLAYBOOK.md), and long-term build-system
direction lives in [`docs/ARCHITECTURE-DIRECTION.md`](docs/ARCHITECTURE-DIRECTION.md).

## Start safely

Before every substantive task:

1. Skim [`docs/STATUS.md`](docs/STATUS.md) (phase banner + pointer table), then
   [`CHANGELOG.md`](CHANGELOG.md) (`[Unreleased]` and `[0.8.0]`; pre-0.8 history
   at [`docs/archived/CHANGELOG-pre-0.8.md`](docs/archived/CHANGELOG-pre-0.8.md) is not standing context).
2. Read the relevant [`docs/contracts/`](docs/contracts/) file for compiler
   semantics; contracts are **normative**.
3. Capture `git status --short`, current branch, and relevant worktree ownership;
   preserve unrelated work.
4. Run `zig build test` before and after substantive changes. For IR-facing work,
   also run `./scripts/release-gate.sh` when scope permits.

## Evidence and review discipline

Resolve authority first: **review only**, **review plus agent/docs guidance**, or
**implement fixes**. Review-only does not authorize product-code changes; explicit
agent/docs guidance may be edited without widening that authority.

- Treat external review packets as leads, not truth. Compare their stated release
  and claims with executable behavior/current code, contracts, this file,
  `docs/STATUS.md`, `CHANGELOG.md`, release-gate material, then narrative or
  historical notes—in that order.
- Verify a relevant code path, test, fixture, or black-box behavior. A contract or
  happy-path smoke alone is not proof of implementation.
- Classify each material observation as exactly one: **Confirmed defect**,
  **Likely defect**, **Insufficient evidence**, **Documented limitation**, or
  **Non-issue / packet drift**. Actionable findings need severity, locus,
  evidence/reproduction, impact, smallest remediation card, and verification.
- Keep speculative hardening separate from defects. Follow the detailed gate,
  environment, recovery, and review procedures in
  [`docs/AGENT-PLAYBOOK.md`](docs/AGENT-PLAYBOOK.md).

## Branch and worktree safety

`main` is frozen during the current Build Week judging window. **`afterparty` is
the active integration line** until the user explicitly reopens the release line.
This routing exception does not relax product policy.

- **Never commit or push directly to `main`** unless the user explicitly orders a
  named direct land. During judging, do not push directly to `afterparty` either.
- Start substantive work on a fresh, owned topic branch from the up-to-date active
  integration line. During judging: fetch, fast-forward `afterparty`, branch from
  it, and target its PR at `afterparty`. Resume branching from `main` only after
  the integration line changes or the user names another base.
- One agent owns a branch and its hot files until handoff, merge, or abandonment.
  Do not rewrite shared/published history or force-push without explicit user
  direction. Land collaborative work by PR; use a concise prefixed branch name.
- Do not commit generated or ignored outputs (`dist/`, `rag/`, `source-rag/`, Zig
  caches) as merge currency. Keep unrelated dirty files and worktrees intact.
- All substantive work, including blocked work, ends with the full evidence block
  in [`docs/COMPLETION-REPORT-TEMPLATE.md`](docs/COMPLETION-REPORT-TEMPLATE.md).
- **Binary handoffs:** Before creating a build or packaging workflow, use
  [`scripts/agent-pack.sh`](scripts/agent-pack.sh) from the target PR worktree.
  Keep generated handoff kits outside tracked product files. See
  [`docs/AGENT-BINARY-KITS.md`](docs/AGENT-BINARY-KITS.md).

## Boris boundaries

**Boris is a graph-native publication compiler:** Markdown in → validated
Trunk/Satellite graph → one or more contracted targets. HTML `dist/` is the
**default target**, not the whole product. It is not a Node SSG stack.

- Zig **0.16+** is the product core. Markdown is **Oliver**, a pinned Zig
  library consumed natively in-process—not a subprocess or JavaScript pipeline.
- The content model is **Trunk** / **Satellite** pages with in-page **Aside**
  tokens, not graph nodes. The author frontmatter parent key is **`parent` only**;
  legacy `parentEntry` and `parent_entry` are unknown keys (`EFRONTMATTER`).
- Favor a shippable `dist/` site, fail-loud validated graph, and measured claims.
  The normal pipeline is discover/scan → parse → Oliver render → compile → assemble →
  optional projection or target publish. Consult [`docs/contracts/`](docs/contracts/)
  and [`docs/SOURCE-MAP.md`](docs/SOURCE-MAP.md) for the current surface and
  [`docs/STATUS.md`](docs/STATUS.md) (phase banner + pointer table) and
  [`docs/ARCHITECTURE-DIRECTION.md`](docs/ARCHITECTURE-DIRECTION.md) for
  direction.
- **Publication targets are a registry**, not a surprise. GitHub Pages and
  Standard.site are verified targets (`boris plan`, `boris standard-site`).
  Nostr plan/sign/publish is a shipped CLI family and is not a verified
  target. Do not treat Pages or Standard.site as “not real because the
  README used to mention only `dist/`.”
- **The editor is a product surface.** `editor/` is a local, compiler-backed
  authoring host. It does not own parsing, the graph, validation, rendering, or
  publication. Do not invent a parallel editor pipeline.
- **Migration labs and source-RAG tools are standalone.** They live in the repo
  story and are not compiled into the `boris` runtime. Do not widen author
  grammar from a lab finding.
- Product identity is recorded in
  [`docs/contracts/publication-model.md`](docs/contracts/publication-model.md)
  and summarized in [`docs/STATUS.md`](docs/STATUS.md) (issue
  [#538](https://github.com/drawmeanelephant/boris/issues/538)): **publisher
  platform**, not “bookseller with annexes” and not “two products, one repo.”

## Non-negotiable architecture

Do not, without an explicit user request:

- introduce another Boris application language or toolchain (TypeScript,
  JavaScript, Python build stages, Go, Rust, Ruby, JVM services); C is allowed
  only for the pinned Oliver dependency or an explicitly approved native library;
- add a framework, SSG, Node modules, bundler, or hydration runtime (including
  Next, Astro, Hugo, Eleventy, Gatsby, Vite/Webpack, React, Vue, Svelte, Deno,
  or Bun) to compile Boris sites;
- spawn a process to render Markdown, replace Zig's `build.zig` / `build.zig.zon`
  build system, turn the core into a web app, or use shell beyond unavoidable
  local debugging as product architecture;
- redesign concurrency/multiprocessing, replace Oliver with a non-native
  path, change Trunk–Satellite semantics, or permit arbitrary MDX, executable
  components, or JS expressions; do not invent a parallel pipeline for convenience.

Allowed normal work includes pure Zig under `src/`, allowed C ABI work under
`vendor/`, author content and registered components, layouts, contracts, tests,
and small static assets emitted or copied by Boris. If a user authorizes a
deviation, scope it narrowly, retain Zig+Oliver unless removal is explicit, and
record a durable exception in the PR/commit and, when appropriate, narrative docs
and a changelog fragment.

## Change obligations and Zig taste

- Contracts first: changes to IR shape, frontmatter, graph rules, or diagnostics
  update the relevant contract and fixtures in the same change, or explicitly
  record temporary drift in `docs/STATUS.md`. Breaking IR changes bump
  `schemaVersion` and relevant compiler identifiers; never silently reshape a
  published schema.
- Feature/fix PRs add a uniquely named fragment under
  [`docs/changelog.d/`](docs/changelog.d/README.md), not a shared `CHANGELOG.md`
  edit. Update `docs/STATUS.md` only when phase, integration line, or the
  "What's next" list moves — it is a phase banner + pointer table (<80 lines);
  capability details live in [`docs/contracts/`](docs/contracts/) and the
  archived snapshot [`docs/archived/capability-matrix-v0.8.md`](docs/archived/capability-matrix-v0.8.md).
  Extend focused fixtures/unit tests; `zig build test` is the baseline gate.
- Prefer `std`, in-memory single-pass arena-friendly work, explicit structures
  (`Page`, frontmatter, parse-time Aside/component tokens), and established module
  boundaries. Target this repository's current Zig APIs. Use plain feature names
  such as Aside, admonition, component, and directive—not mascot branding.

## Reference map

Use [`README.md`](README.md) for outcomes and CLI, [`docs/contracts/`](docs/contracts/)
for normative behavior, [`docs/RELEASE-GATE.md`](docs/RELEASE-GATE.md) for ship
checks, and [`docs/STATUS.md`](docs/STATUS.md) (phase banner + pointer table) for
phase and pointers. Capability details live in contracts and
[`docs/archived/capability-matrix-v0.8.md`](docs/archived/capability-matrix-v0.8.md);
pre-0.8 history is in [`docs/archived/CHANGELOG-pre-0.8.md`](docs/archived/CHANGELOG-pre-0.8.md).
Do not copy contracts into policy; open the source of truth.

Need to find a module? [`docs/SOURCE-MAP.md`](docs/SOURCE-MAP.md) is the
hallway. Contracts and `src/` remain authority. Do not recreate a
per-function prose twin of the compiler.
