# Proposal — graduate `boris-migration-lab` into its own repository

> **Status:** draft proposal — no code, contract, or CI change yet. Owner decision required before any step.
>
> **Date:** 2026-08-30 · **Author:** Freebuff session · **Integration line:** n/a (planning doc)
> **Contract change:** none proposed in this document · **Toolchain change:** n/a
>
> This document plans a possible **repository split**: the standalone migration
> laboratory currently at `tools/migration-lab/` would move to its own
> repository under the same org, leaving Boris as the publication compiler
> only. It lists, concretely, what must move and what must pin to Boris.

## 0. Why this exists

`boris-migration-lab` is already a standalone tool in every meaningful sense:
its own binary (`zig-out/bin/boris-migration-lab`), its own `build.zig`, its
own test gate excluded from root `zig build test`, no product-module imports
at runtime, and a strict ownership boundary (migration provenance never
becomes product grammar, per the
[publication-model contract](../contracts/publication-model.md)). It lives in
this repository only for convenience of history, contracts, and CI.

The remaining coupling to the Boris repository is small and enumerable
(Section 3). The proposal is therefore mechanical in shape: **move the tree,
move its contracts, pin the four real couplings, cut over CI, update
pointers.** The "no second product in one repo" identity rule is *served*,
not violated, by this split: it makes the publisher-platform boundary
physical instead of conventional.

Scope: this proposal covers only `tools/migration-lab/`. The other standalone
tools (`tools/content-audit/`, `tools/docs-maintenance/`,
`tools/search-index/`, `tools/testdata-generator/`) are out of scope and stay
in-repo unless separately proposed.

## 1. Current state (measured)

| Dimension | Value |
|---|---|
| Tree | `tools/migration-lab/` — 409 files, ~3.2 MB |
| Source modules | 19 top-level `.zig` files (`main.zig`, `wordpress.zig`, `starlight.zig`, `astro_import_plan.zig`, `astro_import_apply.zig`, `instagram.zig`, `obsidian.zig`, `notion.zig`, `filed.zig`, `filed_scan.zig`, `asset_filename.zig`, `theme_archaeology.zig`, `theme_materialize.zig`, `wordpress_theme.zig`, `link_audit.zig`, `frontmatter_review.zig`, `migration_semantics.zig`, `publication.zig`, `archaeology.zig`) |
| Fixtures | 380 files under `fixtures/` (WXR sets, dogfood/hostile Starlight, mini-Astro/Instagram/Notion/Obsidian/Filed, theme fixtures) |
| Modes | astro, astro-import-plan, astro-import-apply, wordpress, wordpress-theme, instagram, obsidian, notion, filed, starlight, asset-filename, theme-archaeology, theme-materialize, link-audit |
| Schema validation | `schema-validation/` — test-only npm-locked Ajv (Draft 2020-12 matrix) |
| CI | `.github/workflows/ci.yml` — `migration-lab-test` (Linux), path-filtered on `tools/migration-lab/**`, aggregated into the `ci` result |
| Product build.zig | **no reference** (fully standalone) |
| `scripts/release-gate.sh` | **no reference** (fully standalone) |
| Agent packs | `scripts/agent-pack.sh` builds `tools/*/build.zig` binaries generically — no migration-specific logic |

## 2. What moves

1. **The tool tree** — `tools/migration-lab/` becomes the new repository
   root: source, `build.zig`, `README.md`, `fixtures/`, `schema-validation/`.
   History should move with it (`git filter-repo` / subtree) so fixture
   provenance and prior fixes keep their blame trail.
2. **Migration-owned contracts** (currently in the product contract
   warehouse, `docs/contracts/`):
   - `astro-import-plan.md`
   - `astro-import-apply.md`
   - `astro-import-plan-policy-v1.json`
   - `takeout-lab-intake.md`
   These describe lab behavior, not compiler behavior; they belong with the
   tool.
3. **The adoption guide** — `docs/MIGRATION.md` and its Contoso fixture
   (`fixtures/migration-site/`, ~32 pages + theme). The guide is
   author-facing, not compiler-normative; it moves or forks with the tool.
4. **The CI lane** — the `migration-lab-test` job (and its path filter and
   aggregate wiring) moves to the new repository's workflow; Boris drops it.
5. **Pointers in Boris** that must be rewritten after the move (see
   Section 4 for the cut-over order):
   - `docs/STATUS.md` "Where to look" / "What's next" if it mentions the lab
   - `docs/AGENT-BINARY-KITS.md` (names the lab binary in the kit story)
   - `CHANGELOG.md` and `docs/archived/capability-matrix-v0.8.md` — **leave as
     historical record**; do not rewrite archive text, only any live pointer
     that routes a reader to the old path.

## 3. What pins to Boris (the four real couplings)

These are the only places the lab currently depends on the product. Each must
be converted to an explicit, versioned pin before or during the move.

### 3.1 The parser import (only product-code import)

`tools/migration-lab/build.zig` creates a build-time module from
`../../src/parser.zig` (`boris_parser`), used by `astro-import-apply` as the
final gate that every generated candidate Markdown parses before it is
written. This is a deliberate design choice ("keeps the migration lab's
no-runtime-dependency boundary"): the parser is linked in-process, not
spawned.

Options, in recommended order:

- **(a) Boris publishes a parse-only package.** Expose `parser` (and its
  transitive deps — `identity`, `diag`, etc.) as an importable Zig package
  with a stable API, and the new repo depends on it via `build.zig.zon`
  pinned to a released Boris tag. Cleanest; costs a small packaging slice in
  Boris (`build.zig` package wiring + a pinned-API test).
- **(b) Vendor a frozen snapshot.** Copy the parser closure into the new
  repo with a recorded source hash, and add a conformance lane that re-runs
  the lab's apply fixtures against each new Boris release, failing when the
  snapshot lags. Zero Boris changes; risks silent drift until the lane runs.
- **(c) Drop the in-process gate; shell out.** `astro-import-apply` invokes
  a pinned `boris` binary instead. Simplest conceptually, but it reverses the
  current no-runtime-dependency design and adds a subprocess contract — not
  recommended unless (a) is refused.

### 3.2 The product binary black-box

Two places launch the product binary:

- the WordPress integration test runs `zig build` in `../..` before testing
  (a missing binary must be a failure, never a skip);
- Starlight mode accepts `--boris=PATH` and attempts a compile of the
  candidate tree when a `boris` binary and `layouts/main.html` are findable.

Pin these to a **minimum Boris release** declared in the new repo's README
and checked by CI (e.g. "requires `boris >= 0.9`"); the product binary
becomes an external prerequisite, like `zig` itself.

### 3.3 The closed grammar contracts (normative references)

The lab's outputs must conform to Boris's closed grammar. The lab currently
links, as normative references: `frontmatter.md`, `identity-and-paths.md`,
`content-local-assets.md`, and the `publication-model.md` ownership matrix.

**Rule for the split: reference, never copy.** The new repo must link these
contracts pinned to a Boris release tag (e.g.
`https://github.com/drawmeanelephant/boris/blob/vX.Y.Z/docs/contracts/frontmatter.md`),
never vendored copies — a copy would drift and the whole point of the closed
grammar is that it has one owner. The publication-model contract stays in
Boris (it owns the migration-provenance vocabulary for the whole product
line) and the new repo links it the same way.

### 3.4 The schema-validation lock

`schema-validation/` (npm-locked Ajv, test-only) validates the lab's own
report schemas against Draft 2020-12. It has no Boris dependency; it moves
as-is. The only action is to confirm the lockfile and CI step move with the
tree (Section 2.4).

## 4. Cut-over order (smallest steps, green at every step)

1. **Freeze the boundary (in-repo).** Replace the `../../src/parser.zig`
   import with 3.1(a) or 3.1(b). Land this as a normal PR in Boris; the lab
   gate must stay green. After this step, `tools/migration-lab/` has no
   relative reference outside its own tree (the `../..` test-build step
   becomes a pinned-binary prerequisite, not a build step).
2. **Fork mechanically.** `git filter-repo` (or subtree) the tree plus the
   four contracts plus `MIGRATION.md`/Contoso fixture into the new repo with
   history. No behavior change in the fork.
3. **Move contracts and guide.** In Boris, replace the moved files with
   pointers (or remove and update the few inbound links); update the
   migration-lab README's contract links to the new repo.
4. **Cut over CI.** New repo gets `migration-lab-test` (+ macOS lane if the
   lab warrants it); Boris removes the path-filter job and its aggregate
   wiring. Both repos' gates green.
5. **Update Boris pointers.** STATUS.md, AGENT-BINARY-KITS.md, README (if it
   links the lab), and any contract cross-references. Archive text is left
   as history.
6. **One-release overlap.** For one Boris release, `tools/migration-lab/`
   may remain as a pointer stub (README → new repo) or be deleted outright;
   recommend delete-at-cut with a pointer, so the repo stops carrying 3.2 MB
   of converter surface.

## 5. Risks and mitigations

| Risk | Mitigation |
|---|---|
| **Contract drift** — closed grammar changes in Boris while the lab's outputs must conform | Reference-by-tag (3.3), never copies; a conformance lane in the new repo runs candidate trees through the pinned Boris release |
| **Parser gate drift** — apply gate uses an older parser snapshot | 3.1(a) preferred; 3.1(b) with a hash-pinned snapshot + release-check lane |
| **Fixture/evidence provenance lost in the move** | Move history with the tree (Section 2.1); keep the hostile/dogfood fixtures as the conformance evidence base |
| **Issue/PR split** — migration issues and compiler issues mixed today | Transfer open migration-lab issues to the new repo at cut-over; label future work by repo |
| **Dual maintenance** — a grammar change now touches two repos | The pin matrix (3.3) makes the dependency one-directional and visible; release notes in the lab name the Boris release they were validated against |
| **Agent kits** — `agent-pack.sh` builds `tools/*/build.zig` generically | No migration-specific code to change; the new repo gains its own kit story or Boris's kit doc drops the lab line |

## 6. Decision criteria (owner questions)

1. **Split now or wait for a real user?** The lab has no confirmed external
   user yet. A split is cheap to reverse at the planning stage but expensive
   after CI and issue history migrate. Criterion: split when the lab ships a
   mode a real site depends on, or when its issue/PR volume makes the
   monorepo confusing — whichever comes first.
2. **Parser gate choice** — (a) publish a parse package, (b) vendor a
   snapshot, or (c) shell out. This is the only decision with a real
   engineering cost in Boris.
3. **New repo identity** — name (`boris-migration-lab` vs
   `boris-migrations` vs a product name), public under the same org,
   versioning (keep `boris-*` format ids? yes — they are existing artifact
   contracts).
4. **Release cadence** — independent (recommended), or locked to Boris
   releases for the first two cycles until the pin matrix proves itself.

## 7. Non-goals

- No change to any lab mode, report schema, format id, safety rule, or
  fixture byte.
- No change to the publication-model ownership boundary (migration
  provenance still never becomes product grammar).
- No folding of migration into the `boris` CLI — this proposal is the
  opposite direction and stays consistent with the "labs are standalone"
  policy.
- No change to the other standalone tools.
