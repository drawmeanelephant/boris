# Agent rules — Boris

This file is binding project policy for AI coding agents and humans pairing with
them. It is the standing field manual; detailed operating procedures live in
[`docs/AGENT-PLAYBOOK.md`](docs/AGENT-PLAYBOOK.md), and long-term build-system
direction lives in [`docs/ARCHITECTURE-DIRECTION.md`](docs/ARCHITECTURE-DIRECTION.md).

## Start safely

Before every substantive task:

1. Skim [`docs/STATUS.md`](docs/STATUS.md), then the top of
   [`CHANGELOG.md`](CHANGELOG.md) (`[Unreleased]` and latest release).
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

**Boris is a Zig documentation compiler:** Markdown in → validated graph → HTML
site by default, with optional JSON IR and RAG. It is not a Node SSG stack.

- Zig **0.16+** is the product core. Markdown is **Apex**, linked in-process by a
  C ABI host adapter—not a subprocess or JavaScript pipeline.
- The content model is **Trunk** / **Satellite** pages with in-page **Aside**
  tokens, not graph nodes. The author frontmatter parent key is **`parent` only**;
  legacy `parentEntry` and `parent_entry` are unknown keys (`EFRONTMATTER`).
- Favor a shippable `dist/` site, fail-loud validated graph, and measured claims.
  The normal pipeline is discover/scan → parse → Apex → compile → assemble →
  optional RAG export. Consult [`docs/STATUS.md`](docs/STATUS.md) for the current
  surface and [`docs/ARCHITECTURE-DIRECTION.md`](docs/ARCHITECTURE-DIRECTION.md)
  for future direction.

## Non-negotiable architecture

Do not, without an explicit user request:

- introduce another Boris application language or toolchain (TypeScript,
  JavaScript, Python build stages, Go, Rust, Ruby, JVM services); C is allowed
  only for Apex or an explicitly approved native C-ABI engine under `vendor/`;
- add a framework, SSG, Node modules, bundler, or hydration runtime (including
  Next, Astro, Hugo, Eleventy, Gatsby, Vite/Webpack, React, Vue, Svelte, Deno,
  or Bun) to compile Boris sites;
- spawn a process to render Markdown, replace Zig's `build.zig` / `build.zig.zon`
  build system, turn the core into a web app, or use shell beyond unavoidable
  local debugging as product architecture;
- redesign concurrency/multiprocessing, replace Apex with a non-native/non-C-ABI
  path, change Trunk–Satellite semantics, or permit arbitrary MDX, executable
  components, or JS expressions; do not invent a parallel pipeline for convenience.

Allowed normal work includes pure Zig under `src/`, allowed C ABI work under
`vendor/`, author content and registered components, layouts, contracts, tests,
and small static assets emitted or copied by Boris. If a user authorizes a
deviation, scope it narrowly, retain Zig+Apex unless removal is explicit, and
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
  edit. Update `docs/STATUS.md` only when phase, primary CLI, or known gaps move.
  Extend focused fixtures/unit tests; `zig build test` is the baseline gate.
- Prefer `std`, in-memory single-pass arena-friendly work, explicit structures
  (`Page`, frontmatter, parse-time Aside/component tokens), and established module
  boundaries. Target this repository's current Zig APIs. Use plain feature names
  such as Aside, admonition, component, and directive—not mascot branding.

## Reference map

Use [`README.md`](README.md) for outcomes and CLI, [`docs/contracts/`](docs/contracts/)
for normative behavior, [`docs/RELEASE-GATE.md`](docs/RELEASE-GATE.md) for ship
checks, and [`docs/STATUS.md`](docs/STATUS.md) for current scope. Do not copy
contracts into policy; open the source of truth.
