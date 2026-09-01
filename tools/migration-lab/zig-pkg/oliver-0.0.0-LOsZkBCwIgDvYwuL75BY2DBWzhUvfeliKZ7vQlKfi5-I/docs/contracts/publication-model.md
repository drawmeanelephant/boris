# Publication model: facts, provenance, projections, and claims

**Status:** normative conceptual contract
**Version:** 1 (ownership model; no artifact schema change)

This is Boris’s canonical publication-model contract. It defines where a fact
belongs and what a publication claim may mean. It complements, and does not
replace, the artifact contracts listed in [`README.md`](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/contracts/README.md). Those
contracts remain authoritative for bytes, schemas, diagnostics, and producer
behavior.

This document does not define a publication-plan JSON shape, a CLI spelling, a
new frontmatter field, a proof-pack format, or a new runtime. The current
internal profile parser and static-plan boundary remain specified by
[`publication-profile.md`](publication-profile.html); this contract supplies the
semantic boundary that any profile or future coordinator must preserve.

## The five vocabularies

Boris keeps five kinds of statements separate:

1. **Document facts** describe a document and its validated graph meaning,
   independently of where the document is published.
2. **Publication facts** describe one selected publication and its targets,
   paths, settings, and output choices.
3. **Migration provenance** records what an importer observed, proposed,
   normalized, dropped, preserved, or sent to review.
4. **Projections** are independently contracted artifacts derived from a
   validated corpus and selected publication facts.
5. **Verification claims** describe evidence and its declared limits; they are
   not a substitute for any of the four fact owners above.

Every fact has one canonical owner. A derived copy may appear in an artifact,
report, or projection, but it must remain attributable to that owner. When two
surfaces disagree, the canonical owner wins; a copied value is not a second
source of truth.

## Document facts

Document facts are true about a document before a publication destination is
selected. In this contract they are limited to Boris’s supported document
grammar and graph model:

- canonical entity identity and any source identity already modeled by Boris;
- authored `title`, immediate structural `parent`, `status`, `tags`, and
  currently supported semantic `relations`;
- the Trunk/Satellite role derived from validated parentage;
- the document body and validated structural references such as includes,
  wiki-links, and other relations covered by their contracts.

The exact accepted author keys and value rules remain in
[`frontmatter.md`](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/contracts/frontmatter.md), with identity and graph details in
[`identity-and-paths.md`](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/contracts/identity-and-paths.md) and [`ir-schema.md`](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/contracts/ir-schema.md).
This contract does not amend that grammar. In particular, it does not add
`summary`, canonical URL, feed settings, theme selection, sitemap settings,
deployment environment, migration confidence, source-system IDs, or arbitrary
metadata to product frontmatter. `frontmatter.md` currently defines
`published_at` and `summary` for existing product behavior; those fields remain
owned by that contract and are neither added nor relocated by this change.

Document facts must not vary merely because the same validated corpus is
issued as HTML, IR, RAG, RSS, or another projection. A title may be rendered
differently by a projection, but the projection does not become the owner of
the title.

## Publication facts

Publication facts describe how a validated corpus is issued in one named
publication. They belong to a publication profile, publication plan, target
configuration, or equivalent coordinator-owned configuration—not to document
frontmatter.

Publication facts include:

- selected content root and input format;
- publication-profile identity and site URL, site title, and site description;
- selected publication adapter and its resolved public location, including the
  origin and base path used by a hosted target;
- named HTML targets, public/non-public target status, target output roots,
  themes, layouts, and layout rules;
- selection and target-relative path for sitemap, RSS, and `llms.txt`;
- selection, output root, and scope for JSON IR, RAG, and Context Bundle
  editions;
- target isolation, cache namespaces, staging roots, and other output-boundary
  choices.

A publication fact may change between a preview and a public issue without
changing the document’s entity identity, parentage, or body. A site URL is
therefore publication data even when it is later copied into a sitemap or feed.
The copy does not make it a document fact.

`PublicationPlan` is the owned semantic intent for a selected publication;
run-only controls such as worker count, incremental mode, and quiet output
belong to execution. The exact current parser and normalization rules are
owned by [`publication-profile.md`](publication-profile.html). A plan may carry
publication facts, but it must not absorb migration provenance or merge the
schemas of the projections it selects.

## Migration provenance

Migration provenance explains where a proposed or converted value came from
and how trustworthy or reviewable that conversion is. It belongs to
migration-lab reports, ledgers, manifests, review records, or importer-owned
sidecars.

Examples include:

- original source path and source-system field name;
- original source value, source-system ID, and raw frontmatter block;
- normalization or mapping decision and its confidence;
- unsupported construct, dropped/preserved metadata, and manual-review reason;
- reviewer decision and materialized-asset source/destination provenance.

Provenance must not silently become product frontmatter, publication metadata,
or graph semantics. A migration layer may propose Boris source, but it does
not redefine Boris source grammar. Candidate Markdown is still subject to the
closed [`frontmatter.md`](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/contracts/frontmatter.md) and graph contracts before it is
product input.

If a migration mode writes a human-readable provenance annotation into a
candidate body, that annotation is still lab-owned migration evidence. It is
not a frontmatter field, a graph edge, a publication setting, or proof that the
candidate is semantically correct. Reports and sidecars remain the authoritative
place for structured provenance.

## Projections

HTML, rendered search, sitemap, RSS, IR, RAG, Context Bundle, and `llms.txt`
are separate projections. Each consumes a validated corpus and its own
contracted inputs. A projection may be selected or omitted without silently
changing the contracts of the others.

| Projection | Canonical artifact owner | What it establishes | What it does not establish |
|---|---|---|---|
| HTML site | [`html-output.md`](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/contracts/html-output.md) | Static page/layout bytes for a target | Accessibility, deployment correctness, or quality of prose |
| Rendered search | [`rendered-search.md`](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/contracts/rendered-search.md) | A search artifact derived from rendered HTML | Complete site publication or semantic correctness of the HTML |
| XML sitemap | [`xml-sitemap.md`](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/contracts/xml-sitemap.md) | A bounded URL-discovery document for selected HTML pages | Crawling, indexing, ranking, or display by a search engine |
| RSS 2.0 | [`rss-2.0.md`](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/contracts/rss-2.0.md) | A feed projection for eligible dated documents | HTML availability, reader engagement, or feed submission |
| JSON IR | [`ir-schema.md`](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/contracts/ir-schema.md) | A versioned frozen graph and compiler report | HTML routes, theme behavior, or RAG content |
| RAG | [`rag-export.md`](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/contracts/rag-export.md) | A versioned retrieval-oriented corpus | Boris authoring syntax, embeddings, or answer quality |
| Context Bundle | [`context-bundle.md`](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/contracts/context-bundle.md) | A versioned provenance-rich context export | The HTML site, the product RAG corpus, or model judgments |
| `llms.txt` | [`llms-txt.md`](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/contracts/llms-txt.md) | A deterministic discovery map, with local location consistency when a hosted identity is supplied | Crawling, deployment acceptance, post-deploy HTTP behavior, or completeness |

Each projection remains independently:

- named and inspectable;
- versioned where its contract requires versioning;
- emitted only when its own selection and prerequisites permit it;
- validated by its own rules;
- attributable to a producing phase and input boundary; and
- capable of being selected or omitted without being inferred from an
  unrelated artifact.

### The conductor rule

The profile/plan is a conductor, not a blender. Normatively, it may select,
order, and coordinate independently contracted projections using shared
publication facts and a validated corpus. It must not merge their schemas,
make one projection’s fields authoritative for another, use one artifact as
proof that another artifact is correct, or turn an omitted projection into an
implicit success claim.

For a hosted issue, the normalized publication location is one shared
publication fact. Applicable URL-bearing projections consume the same
`base_url`, `origin`, and `base_path`; disagreement is a publication failure.
This local invariant covers generated HTML/public metadata, sitemap, RSS, and
location-aware `llms.txt` output. Rendered-search v1, IR, RAG, and Context
currently use target-relative/source/entity paths and therefore have no public
URL assertion to verify. None of these local checks is a post-deploy test.

Standalone output modes retain their separate contracts. If a future
coordinator composes them, composition is an orchestration boundary only; it
does not create a new blended artifact contract unless that contract is named,
versioned, and separately specified.

### Analysis is not another publication

Read-only analysis surfaces such as `check`, `impact`, generated-output link
audits, publication checks, and Doctor are checks or reports, not publication
projections. [`documentation-intelligence.md`](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/contracts/documentation-intelligence.md)
owns the shipped graph-health and impact analysis contract, while
[`publication-checks.md`](publication-checks.html) owns target-local publication
evidence and [`publication-claims.md`](publication-claims.html) owns the
mechanical claims-and-limitations derivation over that evidence. An analysis
result may be evidence for a named claim within its scope, but it does not
become HTML, IR, RAG, or deployment metadata and it cannot silently certify an
omitted projection.

The [Publication Touch Atlas](publication-touches.html) is downstream evidence
indexing, not another publication or verification layer. It may link only
records already declared by `artifacts.json`, `checks.json`, and
`claims.json`; it must not invent source, phase, runtime, deployment, or
transformation relationships. Its first slice is implemented and derives
`touches.json` exclusively from those committed evidence bytes.

The [Publication Proof Pack](publication-proof-pack.html) is downstream
evidence presentation, not another publication or verification layer. It may
present only records already declared by `artifacts.json`, `checks.json`,
`claims.json`, and `touches.json`; it must not rerun checks, reread payloads,
or upgrade evidence status. Its first slice is implemented and emits the
deterministic pair `proof-pack.json` and `index.html` after the Touch Atlas
commits.

## Verification vocabulary and claims

The following terms describe evidence. They are vocabulary, not a proof-pack
implementation and not a quality score.

| Term | Normative meaning |
|---|---|
| **configured** | Selected by the publication plan or invocation; execution has not necessarily begun. |
| **attempted** | Execution of the selected operation began. This does not mean an artifact was produced. |
| **emitted** | The producing phase wrote an artifact to its declared output boundary. Existence alone is not semantic validation. |
| **checked** | A named mechanical verification completed against a declared input and scope. |
| **passed** | The named check observed no failure within its declared scope and inputs. |
| **verified** | A specific claim is supported by named evidence from completed checks; the claim inherits their scope and limits. |
| **not verified** | The available evidence did not establish the claim. |
| **failed** | Evidence contradicts the claim or the named check reported a failure. |
| **limited** | The named check passed, but a declared boundary, exception, or untested dimension remains. |

Evidence for a verified claim must identify the claim, check, input/artifact
boundary, scope, and result. Boris must never invent evidence for a check that
did not run. A configured or attempted operation is not an emitted artifact;
an emitted artifact is not automatically checked; a passed check is not
automatically a universal claim.

The following distinctions are mandatory:

- artifact existence is not semantic correctness;
- link integrity is not accessibility;
- schema conformance is not prose quality;
- deterministic bytes on one recorded environment are not universal
  reproducibility;
- successful generation is not proof of deployment correctness; and
- absence of detected problems is not proof of excellence.

When a check passes but its boundary remains, report the result as **limited**
and name the boundary. Do not upgrade a limited result to verified excellence,
and do not use a projection’s successful generation as evidence for another
projection or for deployment.

## Ownership matrix

The matrix is a routing aid; the linked contract remains normative for each
artifact or grammar detail.

| Fact or decision | Canonical owner | Authored or derived | Publication-specific | Migration-only | Allowed in frontmatter | Evidence implications |
|---|---|---|---:|---:|---:|---|
| Entity `id` and source-path identity | [`identity-and-paths.md`](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/contracts/identity-and-paths.md) | Authored override or path-derived | No | No | `id` only | Identity and collision checks must name the source path. |
| `title` | [`frontmatter.md`](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/contracts/frontmatter.md) | Authored | No | No | Yes | Parser acceptance; projections may copy it. |
| `parent` and Trunk/Satellite role | [`frontmatter.md`](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/contracts/frontmatter.md), [`ir-schema.md`](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/contracts/ir-schema.md) | Parent authored; role derived | No | No | `parent` only | Graph validation and freeze establish topology. |
| `status`, `tags`, and semantic `relations` | [`frontmatter.md`](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/contracts/frontmatter.md), [`semantic-relations.md`](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/contracts/semantic-relations.md) | Authored | No | No | Yes, when contracted | Eligibility and relation checks are projection-specific. |
| Body and validated structural references | [`includes-and-wiki-links.md`](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/contracts/includes-and-wiki-links.md), [`components.md`](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/contracts/components.md), [`ir-schema.md`](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/contracts/ir-schema.md) | Authored then validated/derived | No | No | Body, not frontmatter | Link/include/render checks must state their scope. |
| Content root and input format | [`publication-profile.md`](publication-profile.html) | Configured | Yes | No | No | Configuration is not evidence of attempted publication. |
| Selected publication adapter and resolved public location | [`publication-profile.md`](publication-profile.html), [`publication-plan.md`](publication-plan.html) | Configured/derived | Yes | No | No | Location identity is not deployment verification. |
| Site URL, site title, and description | [`rss-2.0.md`](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/contracts/rss-2.0.md), [`xml-sitemap.md`](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/contracts/xml-sitemap.md), profile plan | Configured | Yes | No | No | URL/schema checks do not prove deployment. |
| Target, public status, theme, layout, and output root | [`multi-target-isolated-output.md`](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/contracts/multi-target-isolated-output.md), [`templating-and-themes.md`](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/contracts/templating-and-themes.md), profile plan | Configured/derived | Yes | No | No | Isolation and render checks are target-scoped. |
| Sitemap, RSS, `llms.txt`, IR, RAG, and Context selection | Each projection contract; profile plan for selection | Configured | Yes | No | No | Each emitted artifact needs its own check and claim. |
| Staging, cache namespace, and target isolation | [`html-output.md`](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/contracts/html-output.md), [`multi-target-isolated-output.md`](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/contracts/multi-target-isolated-output.md) | Derived from publication config | Yes | No | No | Atomicity and platform limits remain qualified. |
| Original source path, field, value, and source-system ID | Migration-lab mode/report | Observed | No | Yes | No | Preserve raw evidence and source boundary. |
| Normalization, mapping, confidence, and unsupported construct | Migration-lab ledger/report | Derived decision | No | Yes | No | Review status and confidence are not product semantics. |
| Dropped/preserved metadata, assets, and reviewer decision | Migration-lab report/manifest/sidecar | Reviewed decision | No | Yes | No | Record the disposition; do not infer success from omission. |
| Deployment environment and post-deploy behavior | External host/deployment owner | Observed externally | Yes | No | No | Local generation cannot verify it. |
| Check result and claim status | The check’s artifact contract plus this vocabulary | Derived evidence | No | No | No | Name the check, scope, result, and limitation. |
| Touch Atlas relationships | [`publication-touches.md`](publication-touches.html) | Derived index over existing evidence | No | No | No | Links existing evidence only; it does not create a new verification claim. |

## Placement examples

### Correct placements

1. A page title is a document fact. Author it as `title` under the closed
   [`frontmatter.md`](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/contracts/frontmatter.md) grammar; an HTML layout, IR node, or RAG
   row may derive a representation from it.
2. `https://docs.example.com` is a publication fact. Put it in the selected
   publication configuration used by the public target and its sitemap/feed
   contracts, not on every page.
3. “Derived from Astro `description` with medium confidence” is migration
   provenance. Keep the source field, original value, mapping decision, and
   confidence in the migration report/ledger or importer sidecar; review any
   proposed Boris field against the product grammar before emission.

### Anti-examples: frontmatter fondue

The following undifferentiated block is invalid product frontmatter. The
unknown keys must not be accepted merely because an importer found them:

```text
---
title: Intro
site_url: https://docs.example.com
theme: dark
rss_limit: 20
migration_confidence: medium
source_system_id: astro:docs:intro
---
```

Move `site_url`, `theme`, and `rss_limit` to publication configuration;
`migration_confidence` and `source_system_id` belong in migration provenance.
Only the document-owned `title` belongs in this example’s frontmatter.

This block is also wrong even if an importer calls every value “metadata”:

```text
---
title: Intro
canonical_url: https://docs.example.com/intro
deployment: production
source_field: description
source_value: A short source summary
reviewer_decision: accepted
---
```

The canonical URL and deployment choice are publication/deployment facts; the
source field/value and reviewer decision are migration provenance. None may be
silently promoted into the document grammar by a migration adapter.

## Change and compatibility rules

- Adding or changing a document fact requires the owning frontmatter, identity,
  graph, or semantic-relation contract and its focused fixtures.
- Adding or changing a publication fact belongs in the profile/target contract
  or the affected projection contract; it must not widen page frontmatter.
- Adding migration evidence belongs in the owning lab/report contract and must
  preserve the distinction between observed source data and proposed Boris
  source.
- Changing a projection’s bytes, schema, eligibility, or producer phase
  requires that projection’s contract and any applicable version bump. A
  coordinator change alone does not merge projection contracts.
- Adding a verification report or proof-pack surface is separate implementation
  work. Until it exists, documentation may describe evidence vocabulary but
  must not claim that a proof pack, artifact inventory, or new check ran.
