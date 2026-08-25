# Architecture direction — Boris

This document records the long-term direction referenced by [`AGENTS.md`](../AGENTS.md).
It is guidance for deliberate designs, not a replacement for current normative
contracts or a mandate to redesign stable code.

## Graph-native static-site direction

Boris should grow as a graph-native static-site build system for large Markdown
sites. Its value is explicit, validated dependency tracking rather than a
proprietary content caste system. Model typed edges where relevant for:

- parent/child hierarchy;
- Markdown includes and transclusion;
- layouts and templates;
- internal references;
- static assets and data files;
- generated artifacts; and
- registered components.

Maintain forward and reverse dependency indexes; the reverse index enables correct
incremental rebuilds. Support ordinary documentation-site features—semantic
asides/admonitions, includes, figures, tabs, details, code groups, navigation,
collections, taxonomies, layouts, assets, and registered custom components—without
unrestricted MDX or executable content.

## Deterministic incremental work

For large sites, stage work as follows:

1. Discover and parse deterministically.
2. Resolve and validate the complete dependency graph.
3. Freeze graph data.
4. Determine cache hits and the affected build set.
5. Render independent jobs with bounded resources.
6. Atomically commit outputs and manifests.

Workers must not mutate the resolved graph or shared output state. Prefer one
coordinating commit phase, per-worker scratch allocation, deterministic scheduling
and output, content-addressed cache keys, and explicit resource limits. Multiple
targets may share a worker pool only with isolated output directories,
configuration hashes, cache namespaces, and explicit cross-target dependencies.

## Publication-model boundary

The canonical ownership and claims vocabulary is
[`docs/contracts/publication-model.md`](contracts/publication-model.md). Keep
document facts in the closed document/graph model; keep site URL, target,
theme/layout, feed, sitemap, machine-output, and output-root choices in the
publication profile/plan or target configuration; and keep source-system values,
mapping confidence, unsupported constructs, and reviewer decisions in
migration-lab provenance. A future coordinator may conduct independently
contracted projections from a validated corpus, but it must not blend their
schemas or turn successful generation into a claim of accessibility, deployment
correctness, or prose excellence.

Bounded HTML page workers (`--jobs`) are the only current product concurrency
path. Coordinator phases—discovery, parsing, graph freeze, fingerprinting, and
dirty-set selection—remain sequential. Do not add shared-mutable concurrency or
low-level I/O optimization without contracts, focused tests, and measured need.
