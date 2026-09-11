# Proposal — graduate `boris-content-audit` into its own repository

> **Status:** executed. The tool is its own public repository
> ([`drawmeanelephant/boris-content-audit`](https://github.com/drawmeanelephant/boris-content-audit))
> at tag `v0.8.2`. The cut-over removed `tools/content-audit/`, its one-shot
> gate `scripts/gate-content-audit.sh`, the `content-audit` /
> `test-content-audit` aggregate steps in the root `build.zig`, and the
> `content-audit-test` CI lane together with its strict aggregate requirement.
>
> **Date:** 2026-09-11 · **Author:** Freebuff session · **Integration line:** n/a (planning doc)
> **Contract change:** none in this document · **Toolchain change:** n/a
>
> Issue: [#834](https://github.com/drawmeanelephant/boris/issues/834). Follows the
> same pattern as the executed
> [`migration-lab-standalone-repo.md`](migration-lab-standalone-repo.md).

## 0. Why

`boris-content-audit` was already standalone in every meaningful sense: its own
binary, its own `build.zig`, a gate excluded from the root `zig build test`
aggregate, no product-module import, and no `boris` subprocess. It lived in this
repository only for history and CI convenience. Moving it makes the
publisher-platform boundary physical: Boris keeps the publication compiler, and
a consumer-side content-quality tool owns its own release line.

## 1. Current state (measured, pre-split)

| Dimension | Value |
|---|---|
| Tree | `tools/content-audit/` — 16 files, ~7.3k lines of Zig |
| Product coupling | **none** — no product-module import, no `boris` child process (`fully standalone` in the [tools registry](../tools-registry.md)) |
| Build wiring | own `build.zig`; the root exposed `zig build content-audit` and `zig build test-content-audit` shims into it |
| CI | `content-audit-test` — macOS **and** Linux, **unconditional** (never path-gated), and required to **succeed** by the strict `ci` aggregate |
| Gate | `scripts/gate-content-audit.sh` (gate-lib + gate-summary) |
| Pointers | `README.md`, `docs/tools-registry.md`, `docs/AGENT-BINARY-KITS.md`, gate-script comments |

## 2. What moved

1. **The tree**, with history: `git filter-repo --subdirectory-filter` carried
   21 commits — from the tool's first commit through the `v0.8.2` release cut —
   remapped so the tool sits at the new repository root.
2. **The gate**, reborn as the new repository's own `.github/workflows/ci.yml`
   (format check + build + `--version` probe + tests, both OSes, unconditional).
3. **The CI lane** and its strict aggregate requirement in this repository.
4. **The aggregate `build.zig` steps** (`content-audit`, `test-content-audit`).
5. **Pointers**, rewritten to name the new home.

## 3. What pins to Boris

Unlike the migration laboratory, there was **no in-process product import to
convert**: the audit parses a bounded frontmatter grammar of its own and never
compiles against product `src/`. The pin is therefore documentation-only, and it
follows the lab rule — **reference, never copy**:

- the new repository's README has a `Boris pins` section linking the closed
  [frontmatter](../contracts/frontmatter.md) and
  [identity-and-paths](../contracts/identity-and-paths.md) contracts at
  `blob/v0.8.2/…`, never as vendored copies;
- the tool id (`boris-content-audit/0.8.2`) stays in lockstep with the pinned
  Boris release, enforced by its own pinned-id test;
- the first standalone tag is `v0.8.2`, matching that id, so a consumer
  workflow can pin a real revision.

## 4. Cut-over order (as executed)

1. **Fork mechanically with history** — `git filter-repo --subdirectory-filter
   tools/content-audit` in a scratch clone; the tool lands at the repository
   root with its own commits.
2. **Standalone conversion in the fork** — `LICENSE`, `.gitignore`, own CI
   workflow, README build instructions and `Boris pins`, source-comment pins,
   and a `--help` example that no longer names a Boris-relative build file.
3. **Verify the fork green**, then create the public repository, push `main`,
   push tag `v0.8.2`, and confirm both OS jobs pass there.
4. **Cut over this repository** — delete the tree and the gate, remove the CI
   lane and its strict aggregate requirement, remove the aggregate `build.zig`
   steps.
5. **Update pointers** — README, tools registry, AGENT-BINARY-KITS, and the
   gate-script comments that named `content-audit-gate`.
6. **Record** — this plan document and a changelog fragment.

## 5. Risks and mitigations

| Risk | Mitigation |
|---|---|
| **Contract drift** — the audit validates a grammar Boris owns and changes | Reference-by-tag in the README pins, never copies; a grammar change bumps the pins and the tool id together |
| **Tool-id drift** — the id claims a Boris release the rules no longer mirror | Pinned-id test in the new repository; the pins table names the release |
| **Provenance lost** | History moved with the tree (21 commits), so prior fixes and fixture provenance keep their trail |
| **Kit story** — `agent-pack.sh` built `tools/*/build.zig` generically | The new repository owns its kit story; the Boris kit doc no longer names the binary |
| **Unobserved CI skip** | The lane moved intact and still runs unconditionally on both OSes, now in its own repository |

## 6. Non-goals

- No change to any audit mode, report schema, format id, safety rule, or fixture byte.
- No folding of the audit into the `boris` CLI — this is the opposite direction.
- No change to the other standalone tools still in `tools/`.
