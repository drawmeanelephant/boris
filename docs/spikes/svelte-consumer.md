# Spike handoff — Svelte × Boris consumer spike

**Status:** spike / experiment handoff — **not** normative, **not** a
contract. Boris core was not modified; this is evidence and a recommendation
for future work.

**Authorization:** this sandbox adds a JS/TS frontend stack to the repo tree
under the owner's explicit request (AGENTS.md exception), scoped strictly to
`sandbox/svelte-consumer/`, with the Zig + Apex product path untouched. It is
disposable experimental evidence, not a product path.

**For:** the next coding agent (Codex/other session) working in the
`drawmeanelephant/boris` repo.

**Source of truth:** this file (`docs/spikes/svelte-consumer.md`) +
`sandbox/svelte-consumer/README.md` (full friction log, assessment,
reproduction) + `sandbox/svelte-consumer/EXPERIMENT-REPORT.md` (round 2:
interactive overlay, persistence, content-edit rebuild, state/content
independence, page-local assets) + `sandbox/svelte-consumer/EXPERIMENT-3-REPORT.md`
(round 3: two-resource economy overlay — a time-driven, stateful widget under
the same seam; verdict unchanged). This file is the compressed handoff; the
sandbox is the working artifact and may be deleted after the evidence is
absorbed.

---

## 1. TL;DR

A deliberately small, throwaway spike answered: *can Svelte/SvelteKit consume
Boris output cleanly without Boris becoming Svelte-specific?* **Yes.** A
fully-static SvelteKit app consumes the real Boris `content/` tree (45
entities) from the **existing** JSON IR (`manifest.json` + `graph.json`) plus
a **body-fragment feed produced by an existing Boris mechanism** (HTML mode +
a `{{content}}`-only layout). **No Boris code was modified** (`git status`
shows only `?? sandbox/`). One small consumer-side link-rewrite remains, and
it is deliberately labeled glue.

## 2. Where everything is

| Path | Role |
|---|---|
| `sandbox/svelte-consumer/` | The spike: SvelteKit 5 app + `boris-data.sh` + one layout |
| `sandbox/svelte-consumer/README.md` | Full deliverable: friction log, proposed contract, non-recommendations, next steps |
| `sandbox/svelte-consumer/boris-data.sh` | Glue script: runs Boris twice → `data/` (IR + body fragments) |
| `sandbox/svelte-consumer/layouts/content-only.html` | The 1-line layout (`{{content}}`) that makes bodies consumer-ready |
| `sandbox/svelte-consumer/src/lib/boris/` | The entire consumer seam (types, loaders, graph lookups, body rewrite) |
| `sandbox/svelte-consumer/data/` | **Generated** (gitignored): `manifest.json`, `graph.json`, `build-report.json`, `bodies/{id}.html` |

## 3. Versions

- Boris `v0.8.0` / compiler `boris/0.8.0` / IR `schemaVersion` `0.2.0`; commit **`853443c7`** (`fix: close benchmark review blockers`)
- Zig `0.16.0` · Svelte `5.56.1` · SvelteKit `2.63.0` · Vite `8.0.16` · `@sveltejs/adapter-static` `3.0.10` · Node `22.22.3`

## 4. Reproduce

```bash
# from repo root
zig build
bash sandbox/svelte-consumer/boris-data.sh     # or: (cd sandbox/svelte-consumer && npm run data)

cd sandbox/svelte-consumer
npm install          # first time
npm run dev          # dev server
npm run build        # prerender → build/ (reads data/ at build time)
npm run preview      # serve static build
npm run check        # svelte-check: 0 errors / 0 warnings
```

`boris-data.sh` runs, from the repo root:

```bash
./zig-out/bin/boris --out sandbox/svelte-consumer/data --quiet
./zig-out/bin/boris --html-dir sandbox/svelte-consumer/data/bodies \
  --html-layout sandbox/svelte-consumer/layouts/content-only.html --quiet
```

Two invocations are needed because the Boris CLI keeps HTML and IR modes
exclusive (that is friction F-3 in the README — ergonomics only).

## 5. Evidence (what was actually verified)

- `npm run check`: **0 errors / 0 warnings**; `npm run build`: **45 pages
  prerendered**, clean adapter-static pass.
- **Determinism:** `sha256sum` of all 45 body fragments + 3 IR files was
  **byte-identical across two full rebuilds** on unchanged input.
- Live preview (vite preview of the static build): hydration clean; search
  filter works (query "zig" → 1 result; tag "lore" → 28/45); tag chips toggle
  with `aria-pressed`; SPA navigation between detail pages works (e.g.
  relation link → `/index`); 404 page renders; `/boris/manifest.json` and
  `/boris/graph.json` serve with 200.
- Body fragment check: Apex-rendered asides (`<Aside kind="tip">` → rendered
  `.admonition--tip`), tables, code, heading ids all present in
  `data/bodies/*.html`; internal wiki-links are rewritten to `/route` form
  (no `//` or stale `.html` hrefs; verified by grep over the built site).

## 6. The seam — what the consumer actually needs (and got)

| Concept | Source | Friction |
|---|---|---|
| entity id (== route path) | `manifest.json` / `graph.json` | none |
| metadata (title/status/tags/role) | manifest / graph | none |
| relations (parent/children/peers/in/out refs, includes) | `graph.json` `nav` + typed `edges` + `reverseIndex` | none |
| navigation (breadcrumb/children/siblings) | `graph.json` `nav` | none |
| **rendered body** | **not in IR** — via content-only layout feed | the only real gap (F-1) |
| body internal links | output-relative `*.html` hrefs | consumer rewrites (F-2, ~15 lines, labeled glue) |

## 7. Assessment / recommendation (agreed direction, NOT implemented)

- **Boundary:** recommend a **small existing-output convention** (document the
  IR + `{{content}}`-only-layout feed), not a new API. No contract/schema
  change needed. The spike proves the seam works with zero Boris changes.
- **If a second consumer appears:** then, and only then, consider a narrow
  `boris export`-style command emitting IR + `{id}.html` body fragments in
  one deterministic tree (absorbs F-1 + F-3, no new semantics). Do not build
  it preemptively.
- **Minimum neutral contract (evidence-supported):** *IR for structure plus a
  per-entity rendered-body feed keyed by entity id.* That is it.

## 8. Non-recommendations (do NOT let Boris absorb these)

1. No rendered bodies inside `graph.json`/`manifest.json` (IR stays lean).
2. No TS types / `.d.ts` in Boris (language-specific; a neutral JSON Schema
   would be the only acceptable future addition).
3. No "extensionless"/root-absolute href mode in the HTML contract (the
   relative-href contract is correct; the consumer rewrite is 15 lines).
4. No slug maps, aliases, or `index.html` URL rewriting for frameworks.
5. No frontend SDK / npm package (the seam is three small files).
6. No second identity model; no re-implementation of Boris parsing/relation
   resolution in any consumer (that would fork authority).

## 9. Suggested next work for you (pick one, keep it small)

1. **Interactive-overlay experiment** (matches the user's games-in-websites
   goal): mount a small canvas/quiz Svelte component beside one Boris entity
   through this seam, then run edit-Markdown → `npm run data` → rebuild and
   confirm the UI survives content updates untouched.
2. **Non-Svelte cross-check:** ~50-line Zig or vanilla-JS script consuming the
   same IR + body feed, to prove the boundary is genuinely framework-neutral.
3. **Design note only** (no implementation): sketch the `boris export`
   capability against the neutrality rule.

## 10. Caveats / not tested

- Content-local assets (`{stem}.assets/`) were not exercised by this corpus;
  predicted to need the same F-2-style href re-targeting.
- Boris `--incremental` is HTML-path-only; a consumer regenerates IR+bodies
  with two full runs (instant at 45 pages; a watch bridge is consumer-side).
- The spike reads `data/` at **build time** (prerender); it does not consume
  the Context Bundle, RAG, or `llms.txt` outputs (out of scope).

---

*Report generated after the spike at repo commit `853443c7`. The preview
server may or may not still be running; restart with
`cd sandbox/svelte-consumer && npm run preview`. The sandbox itself is
gitignored-generated except for `src/`, `layouts/`, `boris-data.sh`, and the
README — delete the whole directory if the evidence is absorbed.*
