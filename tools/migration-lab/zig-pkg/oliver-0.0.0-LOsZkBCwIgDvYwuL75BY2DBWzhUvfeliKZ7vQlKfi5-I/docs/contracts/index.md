# Publication contracts

The GitHub Pages workflow (`.github/workflows/github-pages.yml`) publishes
this documentation tree with a Boris binary built from a pinned Boris
revision. Boris treats publication as a set of normative contracts: the
workflow generates a [publication profile](publication-profile.html),
normalizes it into a [publication plan](publication-plan.html), compiles
only inventory-verified payloads, and retains separate evidence of what
was emitted, checked, and claimed.

These documents are the Boris publication contracts, ported into Oliver so
the publication pipeline is self-contained. The
[GitHub Pages user guide](../github-pages.html) explains how to operate
the workflow; the contracts below are the machine-readable shapes it
relies on.

## The declaration chain

- [Publication profile](publication-profile.html) — schema v1 declaration
  input: the GitHub Pages location slice (`base_url` / `origin` /
  `base_path`), bounds, and fail-closed validation.
- [Publication plan](publication-plan.html) — the normalized declaration
  emitted by `boris plan --profile`: canonical JSON, fixed key order, no
  publication side effects.

## The publication model

- [Publication model](publication-model.html) — the meta-contract that
  classifies document facts, publication facts, migration provenance,
  projections, and verification claims, and names the canonical owner of
  each.

## Target-local evidence

Boris emits these reports into `dist/_boris/proof/`; the workflow retains
them in the evidence artifact and never publishes them:

- [Artifacts](publication-artifacts.html) — `artifacts.json`: the
  committed inventory with byte counts and SHA-256 per emitted file.
- [Checks](publication-checks.html) — `checks.json`: which checks ran and
  their findings, bound to the committed inventory.
- [Claims](publication-claims.html) — `claims.json`: the fixed claims and
  limitations derived from the inventory and checks bytes.
- [Touch Atlas](publication-touches.html) — `touches.json`: the
  relationship index derived exclusively from the existing evidence
  reports.
- [Proof Pack](publication-proof-pack.html) — `proof-pack.json` +
  `index.html`: the two-file presentation over the committed evidence.

## Deployment evidence

- [GitHub Pages deployment evidence](github-pages-deployment-evidence.html)
  — the optional post-deploy audit report: a bounded HTTP observation bound
  to the retained plan and inventory, with the closed result vocabulary.

## Upstream contracts

Contracts that govern Boris-side behavior outside the publication slice
(for example `html-output.md`, `rss-2.0.md`, `xml-sitemap.md`, and
`ir-schema.md`) are owned by the
[Boris repository](https://github.com/drawmeanelephant/boris) and
referenced from the [publication model](publication-model.html) contract.
