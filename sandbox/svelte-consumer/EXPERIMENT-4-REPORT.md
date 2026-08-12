# Experiment report — framework-neutral cross-check (round 4)

**Status:** disposable spike evidence — **not** normative, **not** a contract.
Boris core was not modified. Companion to `EXPERIMENT-REPORT.md` (round 2),
`EXPERIMENT-3-REPORT.md` (round 3), `README.md` (round-1 friction log and
assessment), and `docs/spikes/svelte-consumer.md` (agent handoff).

**Question under test:** is the Boris consumer boundary actually
framework-neutral? Rounds 1–3 were all Svelte; this round renders a site from
the **same feed** with a zero-dependency vanilla Node script. Would a tiny
Zig/Go/Rust/vanilla renderer plausibly want the same artifacts — and does it
hit the same friction?

**Answer:** yes, and it needs **less** glue than Svelte did. A ~100-line
zero-dependency script rendered all 45 pages from `manifest.json` +
`graph.json` + the body feed with **zero link rewriting** — because its routes
*are* Boris's output paths. This proves the round-1 link-rewrite glue was a
SvelteKit-routing concern (extensionless routes), **not** a Boris problem.

---

## 1. What was built

`cross-check/render.mjs` — a single-file, zero-dependency vanilla Node
script (no package imports, no build step, runnable with plain `node`):

```bash
node cross-check/render.mjs          # reads ../data, writes ./out
# or: npm run cross-check            # from sandbox/svelte-consumer
```

It consumes the **exact same three artifacts** the Svelte app consumes:

- `data/manifest.json` — `pages[]` for the index page (45 entities);
- `data/graph.json` — `nodes`, `edges` (191), `reverseIndex`, `nav` for
  metadata chips (role/status/tags), provenance, and the relations panel;
- `data/bodies/{id}.html` — Boris-rendered body fragments, inserted as-is.

Output: `cross-check/out/{id}.html` per entity (45 pages) plus
`cross-check/out/index.html`. The relations sections perform the same lookups
as `src/lib/boris/graph.ts` (outgoing references from `edges`, incoming from
`reverseIndex` → edges of kind `reference`, children/parent from `nav`) — in
~10 lines of plain JS, proving `graph.json` alone is sufficient.

The script ends with a self-verification pass that fails loudly on any feed
invariant violation: `pageCount === pages.length === nodes.length`, every
entity has a body fragment, and a spot-check that the overview page contains
its rendered body and a relation link.

## 2. The headline finding — zero rewrite glue

**The vanilla renderer needed no link-rewrite at all.**

Its routes are Boris's own output paths (`{id}.html`), so the
output-relative hrefs inside body fragments (`trunk-satellite.html`,
`../agents.html`, `trunk-satellite.html#satellites`) resolve naturally — the
same convention Boris's own full-site HTML output uses. A full link-integrity
sweep of the rendered site found **626 links, 0 broken** (body hrefs plus the
renderer's own relations links, which it emits output-relative via
`posix.relative` — the same convention, ~4 lines).

This settles a question left open since round 1. The friction log's F-2
("body links are output-relative `.html` hrefs") was classified as consumer
glue; round 4 shows the glue was **SvelteKit-specific**: SvelteKit routes are
extensionless and root-relative (`/guides/trunk-satellite`), so the ~15-line
rewrite in `body.ts` exists only because of that routing choice. A consumer
that adopts Boris output paths — which is the natural choice for any static
renderer — gets links for free.

The framework-neutrality test from round 1's assessment ("would a tiny Zig,
Go, Rust, or vanilla renderer plausibly want this too?") is now answered with
evidence: **yes, and it wants strictly less than Svelte did.**

## 3. Boundary result

**Boris content and a second, framework-free consumer coexisted with zero
leakage and zero Boris changes.** The feed is self-sufficient: the script
needed no Svelte knowledge, no TypeScript, no Markdown re-parsing, and no
relation re-derivation — every semantic came from the frozen artifacts. The
renderer adds nothing Boris must know about.

## 4. Verification

| Check | Result |
|---|---|
| Pages rendered | 45 (matches `manifest.pageCount`, `graph.nodes`, and body-fragment count — enforced by the script) |
| Feed invariants | All pass (pageCount/pages/nodes/body counts agree) |
| Link integrity | **626 internal links, 0 broken** (body hrefs + generated relations links) |
| Relations | Parent/children/references/referenced-from render for a sample entity (`guides/trunk-satellite`) with correct relative hrefs |
| Determinism | Output byte-identical across runs (45 files, `sha256sum` diff clean) |
| Dependencies | None — runs on stock Node, no `node_modules` |

## 5. Friction log

New friction this round: **one self-inflicted bug, zero boundary friction.**

| Observation | Classification |
|---|---|
| First render emitted relations links flat (`agents.html`) instead of output-relative (`../agents.html`), breaking 319/626 links | Ordinary static-site concern — my bug, not the feed's; fixed by emitting `posix.relative` hrefs like Boris does. Worth recording as evidence that the *convention* (output-relative hrefs) is the contract, and consumers must follow it — but it is a 4-line, framework-neutral pattern |
| Body fragments contain no `<html>`/`<head>` wrapper (they are fragments by design) | Ordinary consumer concern — a renderer supplies the document shell; the Svelte app and this script both do this identically |

No new routes, ids, metadata, assets, hydration, or generated-path friction
appeared. The round-2 asset-copy step was not re-tested here (the corpus has
no page-local assets since the round-2 temporary one was reverted); a vanilla
consumer would face the same trivial copy step.

## 6. Glue delta

**Before round 4:** ~22 lines total consumer glue (Svelte link rewrite + asset
copy).

**After round 4:** the vanilla consumer adds **zero** integration glue — its
entire "glue" is the same ~4 lines of output-relative href generation that any
static renderer needs. Total across both consumers: still ~22 lines for
Svelte, 0 for vanilla. The boundary itself has never needed glue; what Svelte
pays for is its own routing model.

## 7. Boris changes

> **None.**

Still nothing. The script consumed existing public output untouched — the
clearest possible confirmation that Boris already exposes what consumers need.

## 8. Things Boris should NOT absorb

The non-recommendation list stands, now with direct evidence on the two
biggest items:

- **No extensionless-href mode in Boris** — round 4 shows the `.html` href
  convention is *correct* for the natural consumer (vanilla routes = output
  paths). The SvelteKit rewrite exists because of SvelteKit's routing, and
  that rewrite stays consumer-side. Adding extensionless hrefs to Boris would
  be adding Svelte-specific behavior to the compiler.
- **No bodies-in-IR** (unchanged) — the body feed served both consumers
  identically.
- **No TS types in Boris** (unchanged) — the vanilla consumer reads JSON
  directly; a TS mirror is only relevant to TS consumers.
- **No asset-serving, no game-state, no server persistence, no SDK** — all
  unchanged from rounds 2–3.

## 9. Architectural verdict

**2 — Clean with minor consumer friction** (unchanged, now precisely scoped).

The umbrella verdict stays 2 because the Svelte consumer still carries its
~22 lines. But round 4 sharpens *where* the friction lives: **zero of it is on
the Boris side.** The minor consumer friction is (a) SvelteKit's extensionless
routing (its own model, its own glue) and (b) the asset-copy step. A
framework-neutral consumer — the thing the boundary is actually for — is
friction-free. This is the strongest possible form of the round-1 claim: the
boundary is not merely consumable by Svelte; it is consumable by anything,
with less work.

## 10. Recommended next step

**Stop the spike work. The seam is proven.**

The interactive thread (rounds 2–3) proved Svelte interaction coexists with
Boris content under two levels of state complexity; this round proved the feed
is consumable by a framework-free renderer with zero Boris-side friction.
Every remaining item on the original menu has now been answered by evidence:

- framework-neutrality → proven (this round);
- assets → proven small (round 2, ~7-line copy step);
- convention documentation → the one concrete, evidence-backed action left.

The only remaining *documentation* step — which is not a spike — is to record
the consumer convention (IR `--out` + `--html-layout` with a `{{content}}`-only
layout, output-relative hrefs) in `docs/`, since two independent consumers now
depend on it. That is the natural landing spot: **build real applications on
top of the seam; do not extend the seam.**
