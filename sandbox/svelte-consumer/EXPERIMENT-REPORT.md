# Experiment report — interactive overlay (round 2)

**Status:** disposable spike evidence — **not** normative, **not** a contract.
Boris core was not modified. Companion to `README.md` (round-1 friction log and
assessment) and `docs/spikes/svelte-consumer.md` (agent handoff).

**Question under test:** can genuinely interactive Svelte application behavior
coexist cleanly with Boris-managed, Boris-verified content without either
system gaining responsibility for the other's semantics?

**Answer:** yes — **Clean with minor consumer friction** (verdict 2). Four
experiments ran in a real browser with zero Boris changes and no architectural
leakage; the only new integration surface is a ~7-line asset-copy convention.

---

## 1. What was built

`src/lib/components/IncrementalToy.svelte` — a microscopic incremental-game-
shaped widget (~130 lines):

```text
resource: 0            [Gather (+1)]
[Upgrade: 10 resource → +2 per click]   [reset]
```

- Browser-owned `$state` only: resource, per-click, upgrade cost.
- One upgrade: `cost → per-click +2`, cost scales (1.6×, changed to 2.0× in
  Experiment 4b).
- **Persistence:** `localStorage`, keyed opaquely by the canonical Boris
  entity id (`boris-spike:incremental:{entityId}`) — no new identity system.
  SSR-safe: localStorage is only touched inside `onMount` / a guarded `$effect`.
- Mounted on every detail page below the Boris body, above the relation panel:
  `{#key node.id}<IncrementalToy entityId={node.id} />{/key}` — the `{#key}`
  remounts per entity so each page restores its own slot.

Conceptual page shape achieved (verified in browser at `/guides/overview`):

```text
Boris entity
├── Boris metadata            (title, chips, provenance — from IR)
├── Boris-rendered body       (from the content-only layout feed)
├── Boris relations/navigation (from graph.json nav + edges + reverseIndex)
└── Svelte interactive component  (browser-owned state, localStorage)
```

## 2. Boundary result

**No architectural leakage in either direction.**

- The widget never reads Boris sources, schemas, relations, or bodies; it
  receives exactly one Boris-derived input (`entityId`) used as an opaque
  storage key.
- Boris never learned the widget exists: no `.svelte` parsing, no new
  frontmatter, no metadata, no graph concepts, no schema change, no compiler
  change. `git status` for `content/` and `src/` (Boris) stayed clean across
  every experiment except the deliberately temporary, reverted content edit.
- Hydration and SPA navigation coexist with `{@html}` Boris bodies and the
  relations panel on the same page without interference.

## 3. State behavior (Experiment 2)

Verified in a real browser (vite preview of the prerendered build):

| Test | Result |
|---|---|
| Gather × N | resource updates live, `localStorage` writes on every change |
| Upgrade when resource < cost | correctly disabled |
| Upgrade when resource ≥ cost | cost deducted, per-click +2, next cost scaled, persisted |
| Navigate to another entity (`/guides/overview` → `/agents/grok`) | new page's widget loads its **own** fresh state (`0/1/10`); no bleed between entity slots |
| Navigate back | state **restored** from localStorage (`resource: 15`, `+3/click`) |
| Full page reload | state **restored** (`resource: 15`, `+3/click`) |
| Storage cleared / new browser | widget starts at defaults (graceful) |

**Smallest reasonable persistence mechanism:** `localStorage` keyed by the
canonical entity id is sufficient and is the smallest mechanism. It is
consumer-side; Boris was not involved and must not be. (Notes: a
`sessionStorage` variant would trade reload-survival for per-tab isolation; a
service-worker/IndexedDB layer is unnecessary at this scale — documented, not
built.)

## 4. Content rebuild behavior (Experiment 3)

Changed one real Boris source file (`content/guides/overview.md`): frontmatter
`title` → "Content Model Overview (spike edit)" plus one added body sentence.
Ran the normal flow (`boris-data.sh` + `npm run build`) and verified in
browser:

- New title appears in `<h1>`, browser tab, and the site nav.
- New sentence appears in the rendered body.
- Relations panel unchanged (4 sections), entity identity unchanged
  (`guides/overview`, same `sourcePath`, same `index`).
- Routes unchanged; SPA navigation unaffected.
- **Widget still hydrated and restored `resource: 15`** — its implementation
  was not touched and did not need to be.
- Consumer glue did not grow (link rewrite unchanged).

**Notable finding — the change surface is the reference-edge set, not the
edited file.** The title change also re-rendered the bodies of
`guides/apex-markdown` and `guides/trunk-satellite`, because both use
**unlabeled** `[[guides/overview]]` wiki-links whose link text is the target's
title. This is correct, deterministic Boris dependency tracking (the same
edges the IR already exposes), not drift. A consumer can predict the blast
radius of a title edit from `graph.json`'s reference edges.

**What each system repeated during the rebuild:** Boris recompiled the whole
tree (re-discover, re-validate the graph, re-render all 45 bodies — ~0.4s);
SvelteKit re-prerendered all 45 pages (~2s; adapter-static has no per-page
granularity). Both are full, deterministic rebuilds — acceptable at this
scale; the "unchanged" material stayed byte-identical (see §8).

## 5. State/content independence (Experiment 4)

- **4a — Boris changes, state model does not:** the Experiment-3 content edit
  (frontmatter + body) shipped through with the widget untouched and its state
  intact. ✔
- **4b — interaction changes, Boris does not:** changed the widget's heading
  and upgrade cost curve (1.6× → 2.0×), rebuilt Svelte **only** (no
  `boris-data.sh`, no Boris recompile). The change rendered; persisted state
  survived; `git status` showed no Boris/content/schema/graph/compiler
  changes. ✔

This is the core proof: each system changed without understanding the other.

## 6. Friction log (new, this round)

| # | Awkwardness | Needed / where / glue | Classification |
|---|---|---|---|
| F-A | None for mounting or state | Widget is ordinary Svelte application code; `{#key}` + `onMount`/`$effect` guard are stock Svelte 5 patterns | ordinary frontend concern — **not** glue |
| F-B | None for persistence | `localStorage` keyed by existing id | ordinary frontend concern |
| F-C | Title edit re-renders dependents | Not friction — correct behavior; blast radius is predictable from IR reference edges | **Boris concern (correct)**, zero glue |
| F-D | Page-local assets reach the app only via a copy step | Boris publishes `{id}.assets/` into the body feed and rewrites image srcs page-relatively; the consumer must serve that tree next to its routes. ~7 lines added to `boris-data.sh` | **3 — reusable consumer concern**; not a Boris gap (publish + rewrite are already correct per `content-local-assets.md`) |
| F-E | Removed assets aren't scrubbed from `static/` by the copy loop | Stale-copy cleanup would need ~2 more lines; acceptable for a sandbox | ordinary frontend concern |
| F-F | Handoff path drift | The incoming brief referenced `sandbox/…/AGENT-REPORT.md`, which had been moved to `docs/spikes/` | documentation concern, not code |
| F-G | Full rebuilds only | Boris recompiles everything; adapter-static re-prerenders everything (~2.4s total here) | SvelteKit concern (prerender granularity) + Boris (incremental is HTML-path only); not a blocker at this scale |

No new routes, generated paths, hydration, or identity glue appeared.

## 7. Glue delta

- **Before (round 1):** ~15 lines consumer-side link rewrite (`body.ts`) +
  `boris-data.sh` (two Boris invocations) + hand-typed IR mirror (~90 lines).
- **After (round 2):** the same ~15-line rewrite, plus **~7 lines** of
  asset-copy convention in `boris-data.sh`. The widget itself (~130 lines) is
  application code, not glue.
- Glue grew by exactly the asset feed, and the growth is category 3 (reusable
  consumer concern). The link-rewrite glue did not grow under content edits,
  navigation, or state churn.

## 8. Boris changes

**None.** Boris core (`src/`, schemas, contracts, `content/`) was not
modified at any point. The single tracked-file change (`content/guides/overview.md`)
was a temporary Experiment-3 edit, verified, then reverted byte-for-byte;
after the revert, all 45 body fragments + IR matched the pre-experiment SHA-256
hashes (47/47), confirming the unchanged material is deterministic.

## 9. Things Boris should NOT absorb (updated)

All round-1 non-recommendations stand (no bodies-in-IR, no TS types, no
extensionless-href mode, no slug maps, no frontend SDK, no second identity
model). New from this round:

1. **No game/application state in Boris** — no widget state, no
   persistence concepts, no "interactivity" metadata. `localStorage` is the
   consumer's domain; Boris must never store browser state.
2. **No asset-serving capability in Boris** — asset *publishing* and
   *rewriting* are already correct; serving them is the consumer's job (a
   ~7-line copy step).
3. **No incremental/export changes for consumers** — full deterministic
   rebuilds are ~2.4s at this scale; a watch bridge or `boris export` remains
   unjustified by evidence.
4. **No "interactive component registry" or framework bridge** — nothing in
   this experiment needed Boris to know Svelte exists.

## 10. Architectural verdict

**2 — Clean with minor consumer friction.** The architecture is sound:
verified Boris content, relations, and a stateful Svelte application component
shared one page across hydration, SPA navigation, reload, content edits, and
widget edits with zero leakage in either direction. The two consumer
conventions (relative-href re-targeting from round 1; asset-copy from round 2)
are small, stable, and now documented — they are conventions a *documentation
pass* could canonicalize, not evidence of a missing Boris capability.

The success condition was met:

> Boris can change without understanding the application, and the application
> can change without understanding Boris internals.

## 11. Recommended next step

**Stop the interactive experiments.** The coexistence question is proven, and
the brief's guardrail ("stop before the spike grows legs") applies.

The single cheapest probe that still adds evidence is the **non-Svelte
consumer cross-check** (~50 lines of Zig or vanilla JS consuming the same IR +
body-fragment feed). It would lock the framework-neutrality claim that this
report's verdict leans on, and it remains disposable. Do **not** prototype a
more realistic game, add persistence machinery, or touch Boris until a real
consumer exists.

If the user's actual goal (games beside docs) needs a larger interactive
surface, the next step is building application *on top of* this seam — not
extending the seam.

---

## Verification log (browser, not inspection)

- `npm run check`: 0 errors / 0 warnings · `npm run build`: 45 pages prerendered
- Widget: gather/upgrade/reset live; disabled-state correct; localStorage
  writes verified byte-for-byte
- Nav away/back and reload: state restored (`resource: 15`, `+3/click`)
- Content edit: title/sentence/nav/tab updated; relations intact; widget
  restored to 15; dependents (`trunk-satellite`, `apex-markdown`) re-rendered
  with propagated link text
- Widget edit (v2): rendered; state survived; zero Boris/content changes
- Asset: Boris published `overview.assets/spike.svg` + rewrote src; with the
  copy step the image rendered in the page (`img.complete && naturalWidth > 0`)
- Determinism: 47/47 SHA-256 hashes identical after reverting the content edit
