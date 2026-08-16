# Publication platform model: verified targets and the adapter seam

**Status:** normative conceptual contract
**Version:** 1 (platform model and target registry boundary; no artifact
schema change)

This contract defines how a publication destination platform becomes a
Boris **verified target**. It does not define a deployment command, a new
profile key, a new evidence schema, or a runtime. The publication core is
already platform-neutral; a platform is three small adapters. This document
states that seam, records the platform deployment matrix, and fixes the rule
that platform quirks never leak into the evidence contracts.

## The verified-target model

A platform is not a recipe bolted onto the side of the compiler. A verified
target is the full chain, all the way through evidence:

1. **Profile** — the selected publication carries a platform identity and a
   resolved public location (`base_url`, `origin`, `base_path`), normalized
   by [`publication-profile.md`](publication-profile.md).
2. **Normalized plan** — the static planner emits the deterministic
   declaration consumed by builders and deployers, per
   [`publication-plan.md`](publication-plan.md).
3. **Location validation** — every URL-bearing projection agrees with the
   normalized location; disagreement is a publication failure
   (`EPUBLICATIONLOCATION`), per the conductor rule in
   [`publication-model.md`](publication-model.md).
4. **Evidence** — the target-local chain commits byte-identical evidence:
   artifact inventory, checks, claims, Touch Atlas, and Proof Pack
   ([`publication-artifacts.md`](publication-artifacts.md) through
   [`publication-proof-pack.md`](publication-proof-pack.md)).
5. **Deployment** — a platform deployer consumes only the `committed`
   records of that inventory, and any post-deploy observation is a separate,
   explicitly bounded contract.

GitHub Pages is the first verified target and is the **depth model**: it
implements the whole chain, including packaging rules, a retained evidence
artifact, and an optional bounded post-deploy observer. See
[`../github-pages.md`](../github-pages.md) and
[`github-pages-deployment-evidence.md`](github-pages-deployment-evidence.md).

## The adapter seam

Adding a platform is three small adapters, nothing more:

| Adapter | Responsibility | Example (GitHub Pages) |
|---|---|---|
| **Location provider** | Authoritative `base_url` / `origin` / `base_path` for the platform's hosting shape | `actions/configure-pages` values; project site, user site, or custom domain |
| **Deployer** | Uploads the platform artifact from the committed inventory | `actions/deploy-pages` consuming the uploaded Pages artifact |
| **Packaging rules** | What the platform artifact may and may not contain | The copier: exact `committed` records, byte counts and SHA-256 verified, `index.html` required, symlinks/hard links rejected, 1 GiB artifact limit, `_boris/proof` excluded |

Platform quirks live inside these adapters. They never change the profile,
plan, projection, or evidence contracts, and they never become fields in
`artifacts.json`, `checks.json`, `claims.json`, `touches.json`, or
`proof-pack.json`.

## The location invariant

For any hosted target, the normalized public location is one shared
publication fact. `base_url` must equal `origin` plus `base_path`; a
contradiction fails closed before the site build. All URL-bearing
projections (HTML public metadata, sitemap, RSS, location-aware `llms.txt`)
consume the same identity.

This invariant is why per-deployment **preview URLs** are the hard design
problem for request-driven platforms, not the deploy command: a preview
deployment has its own `base_url` that changes per run, and every projection
must agree with *that* location for the run to be a verified target. The
GitHub Pages workflow avoids this by fixing the location at plan time. A
platform whose hosting shape produces a fresh location per deployment must
resolve this invariant inside its adapter before it can be a verified
target.

## Platform deployment matrix

Status vocabulary: **shipped and verified**, **deliberate but waiting**,
**wait for demand**, **never proactive**, **off the seam**.

| Platform | Status | Position |
|---|---|---|
| GitHub Pages | **Shipped and verified** (#302) | The depth model, not a recipe. Full chain implemented: workflow, artifact copier, retained evidence, optional bounded post-deploy audit. |
| Standard.site | **Shipped and verified** (#452 program) | The second verified target, proven by the target registry (below). Profile/plan adapters implemented; offline deterministic projection, compiler-owned `{{head}}` document links, and well-known publication record in [`standard-site.md`](standard-site.md). |
| Cloudflare Pages (static) | **Deliberate but waiting** | The only deliberate second *static* platform: same artifact-upload model, static-first. Adapter-shaped, but wait for a user before building it. |
| Cloudflare runtime/edge | **Tracked separately** (#300, #301) | Not a static rehost: Container-backed native builds behind a Worker (#300) and freestanding Wasm embedding (#301). These are compiler-shaped bets, not deployer adapters, and live outside this matrix's deployer row. |
| Vercel | **Wait for demand** | The real design problem is per-deployment preview URLs against the location invariant, not the deploy command. No proactive work. |
| Netlify | **Wait for demand** | Same position as Vercel: preview-location semantics against the invariant, adapter-shaped, no proactive work. |
| S3 + CloudFront, Surge, Firebase, and other commodity hosts | **Never proactive** | Adapter-shaped hosts with no distinct design problem. Build one only when a concrete user needs it. |
| Nostr NIP-23 | **Off the seam** | Shipped CLI (`boris nostr plan` / `sign` / `publish`). Relays are not a host: no `base_url`, no committed public artifact, no deployer. The per-relay report and the recorded first-tester fixture are the evidence. Do not add `nostr` to `publication.target` to make the CLI feel finished. See [`nostr-publication.md`](nostr-publication.md). |

## Rules

- Platform quirks live in the adapter; they never leak into the evidence
  contracts.
- A deployer consumes only `committed` inventory records and never invents
  an artifact the inventory did not declare.
- Local generation is not a deployment claim. A successful build or upload
  is not proof of post-deploy behavior; post-deploy observation, where it
  exists, is a separate bounded contract with its own limits.
- No proactive Vercel/Netlify work. Commodity hosts are never proactive
  work.
- Nostr stays off the verified-target registry. A relay list is not a
  location provider. Adding it requires a product reason that accepts a
  new location invariant, not completeness.
- When a second platform is adopted, this contract's registry boundary
  applies (below).

## Target registry boundary

`publication.target` is a small **target registry**: the closed vocabulary is
`"github-pages"` and `"standard-site"`, validated by
`isValidTargetName` in the profile parser, and each name maps to its adapters
(location provider, deployer, packaging rules). See
[`standard-site.md`](standard-site.md) for the second target's profile and
plan shape.

- unknown target names fail closed in the profile parser, exactly as the
  single-value vocabulary did;
- the registry is additive: existing `"github-pages"` plans keep working
  byte-identically (proven by the existing profile/plan fixtures);
- `github-pages-deployment-evidence.json` already separates the platform
  identity (`provider: "github-pages"`) from the artifact-target identity
  (e.g. `public`), so the registry never conflates the two;
- `standard-site` profile/plan fixtures and the
  `publication-plan-1.schema.json` `oneOf` guarantee the additive rule.

When a third platform is adopted, add its name and adapters here; the
registry is open for new members but closed for typos. `nostr` is not
that third name.
