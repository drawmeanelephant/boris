# Project status — Boris

**As of:** 2026-11-25

**Integration line:** `main`. The Build Week judging window is closed; Boris
did not place (README "AI and OpenAI Build Week"). The `afterparty` line landed
via PR **#790**. Topic branches target `main`, and
`afterparty` is retained as the staging line for larger in-flight work.

**Product metadata:** release **`v2026.11.0`** / `boris/2026.11.0`; base IR `schemaVersion` **`0.2.0`**. Product versions are calendar versions `YYYY.M.PATCH` from this release ([scheme](contracts/cli.md#product-version-scheme)); contract and schema versions stay semantic.
**Phase:** v2026.11.0 cut; post-release maintenance on `main`.
**Build baseline:** Zig **0.17** and the Oliver library pinned in `build.zig.zon` (pure Zig; no CMake or other host tools).

Boris is a **graph-native publication compiler** ([publisher platform](https://github.com/drawmeanelephant/boris/issues/538)): Markdown in → validated Trunk/Satellite graph → one or more contracted targets. HTML `dist/` is the default target, not the whole product. Normative behavior lives in [`docs/contracts/`](contracts/).

## What's next

- ~~v2026.11.0 release cut~~ — first calendar-versioned release: changelog assembled from `docs/changelog.d/` (2026-11-25); tag `v2026.11.0` on `main` per the release gate.
- **Migration-guide review findings** — evidence complete; human review remains for retained MDX/frontmatter/link/asset findings and four missing routes.
- **Source-RAG publication safety** — dependent on evidence; make only a tested, narrowly justified staging/cleanup improvement.

## Where to look

| Question | Pointer |
|---|---|
| Normative compiler behavior | [`docs/contracts/`](contracts/) — one file per topic; index in [`contracts/README.md`](contracts/README.md) |
| Content model and publication boundary | [`publication-model.md`](contracts/publication-model.md) |
| Target registry (verified targets) | [`publication-platforms.md`](contracts/publication-platforms.md) — `github-pages` and `standard-site` are verified |
| Release history | [`CHANGELOG.md`](../CHANGELOG.md) (`[Unreleased]` + recent dated sections; pre-0.8 at [`CHANGELOG-pre-0.8.md`](archived/CHANGELOG-pre-0.8.md)) |
| Pending release fragments | [`docs/changelog.d/`](changelog.d/) (release-owner work; assembled at each cut) |
| Capability snapshot (v0.8) | [`docs/archived/capability-matrix-v0.8.md`](archived/capability-matrix-v0.8.md) |
| Capability details (what works) | Contracts above + [`docs/SOURCE-MAP.md`](SOURCE-MAP.md) |
| Source locations | [`docs/SOURCE-MAP.md`](SOURCE-MAP.md) |
| How to run and common commands | [`README.md`](../README.md) — `zig build && ./zig-out/bin/boris --quiet` → `dist/` |
| Open roadmap and parked cards | GitHub issues (e.g., #454, #840, #907) |
| Risk and environment notes | [`html-output.md`](contracts/html-output.md), [`validation.md`](contracts/validation.md), [`atproto-app-password.md`](contracts/atproto-app-password.md) |
| Documentation map | [`docs/SOURCE-MAP.md`](SOURCE-MAP.md) and [`contracts/README.md`](contracts/README.md) |
