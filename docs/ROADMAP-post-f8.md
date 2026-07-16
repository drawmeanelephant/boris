# Roadmap — post Feature 8 (historical draft + current direction)

**As of:** 2026-07-15 · product **0.3.1** / IR **0.2.0** · plan only · not a
substitute for [`STATUS.md`](STATUS.md)
**Current state:** F8.1–F8.3 are **shipped** (IR 0.2 + reverse-index dirty-set
in **v0.3.1**). Heading-target wiki links (PR #40), F9.1 closed layout/theme
assets (PR #41), and F9.2 layout UTF-8 validation + orphan theme-asset scrub
(PR #42) are **shipped**. Product **v0.3.1** is released/tagged. Documentation
Intelligence (`check` / `impact`), bounded semantic relations, and AI Context
Bundles are merged on `main` via PRs #43 and #44 and remain under
`[Unreleased]` until the next product cut. This file preserves the post-F8
planning history and records what remains *after* F9.2 and the
knowledge-system track.

Normative behavior: [`docs/contracts/`](contracts/). Hard constraints:
[`AGENTS.md`](../AGENTS.md). Living phase: [`STATUS.md`](STATUS.md).

### Live direction after F9.2

1. Cut the next release with the merged knowledge-system contracts and
   acceptance gates documented in `[Unreleased]`.
2. Dogfood Boris against a real site and turn migration findings into focused
   authoring, layout, and conversion work.
3. Decide per-page layout selection and external stylesheet boundaries before
   attempting a broader theme/DaisyUI experiment.

Do not interpret historical “F8.3 pending” or “heading wiki later” statements
below as current status; they are retained to preserve planning context.

---

## 1. Executive summary

**Today (product 0.3.1):** Boris is an HTML-first Zig documentation compiler —
Apex Unified, Trunk/Satellite graph, Feature 7 includes + wiki on the HTML path
(including `[[entity-id#heading-id]]` section targets), P2/P3 incremental /
watch / jobs / multi-target, and F9.1/F9.2 closed layouts with target-owned
theme assets. Machine IR emits `schemaVersion` **0.2.0** with typed dependency
edges and a deterministic `reverseIndex`. Incremental HTML consumes the same
direct-edge resolver and reverse-walk semantics (F8.3).

**F8 complete (product 0.3.0 → 0.3.1):**

| Slice | Product | Outcome |
|-------|---------|---------|
| F8.1–F8.2 | **v0.3.0** | Public IR graph-native: typed `page` / `source` endpoints, direct `parent` / `include` / `reference` edges, deterministic `reverseIndex` |
| F8.3 | **v0.3.1** | Incremental dirty-set uses the same frozen reverse dependencies IR publishes; fingerprints remain the content-addressed change detector |

**F9 slices already landed (still under product 0.3.1 tree; see Unreleased /
tag notes in CHANGELOG as cuts land):**

| Slice | PR | Outcome |
|-------|-----|---------|
| Heading-target wiki | **#40** | `[[entity-id#heading-id]]` matches Apex-rendered heading ids; fail loud |
| F9.1 layout + theme assets | **#41** | Closed layout plan (`metadata` / `footer` / `asset-url`); target-owned theme asset copy |
| F9.2 theme hardening | **#42** | Layout UTF-8 validation at split; orphan theme-asset scrub after publish |

**Next (after F9.2):** residual build-system polish, page layout selection rules,
external stylesheet policy, optional DaisyUI/static-theme experiment, practical
real-site migration/content conversion. IR-visible layout/asset edges remain
**explicitly deferred** (optional F10 / schema 0.3). Not polyglot SSG work, not
unrestricted MDX, not marketing perf claims without measurement.

---

## 2. Assumptions after F8

| Assumption | Detail |
|------------|--------|
| Binary ↔ IR | Product **0.3.1** emits IR **0.2.0** with compiler id `boris/0.3.1`; F8.1–F8.3, goldens, and the release-gate check are shipped. |
| Include / wiki | Same fence-aware, fail-loud rules on HTML and IR paths; Apex FS includes stay off. Heading fragments validated on HTML path only (IR does not check heading membership). |
| layout / asset | May exist in internal planner/cache; **not** IR v0.2 edge kinds until a later schema decision (F10). |
| Determinism | Dual-run byte-identical IR **per host**; no bit-identical cross-OS claim without evidence. |
| Watch | Portable polling remains the baseline; native FS events are platform-qualified bonus. |
| RAG | Format `boris-rag` / schema `1` stays unless catalog deliberately embeds IR edges; only `boris_version` tracks product. |
| F8.3 packaging | **Resolved:** shipped as **v0.3.1** (tagged). |
| Non-goals | Subprocess markdown, Next/Astro/React as compiler, unrestricted MDX, full YAML frontmatter, embedded HTTP dev server. |

### Situation snapshot (2026-07-15, post PR #42)

- **Shipped tags:** v0.2.0 (HTML default, Apex, nav/TOC, P2/P3); v0.2.1 (Feature 7
  includes/wiki); v0.3.0 (F8.1–F8.2, IR 0.2); **v0.3.1** (F8.3 reverse-index
  dirty-set + P4 multi-target CLI / cache freshness slices).
- **Shipped after tag (tree at main):** PR #40 heading-target wiki; PR #41 F9.1
  closed layout/theme assets; PR #42 F9.2 UTF-8 layout gate + orphan asset scrub.
  See [`CHANGELOG.md`](../CHANGELOG.md) `[Unreleased]` / next cut notes.
- **Not pending:** F8.3, heading-target wiki links, F9.1, F9.2 — do not re-plan
  as greenfield.
- **Hardening:** adversarial issues #7–#28 closed; residual opportunistic only.
- **Docs follow-through:** this roadmap truth-reconciles post-F9.2; living phase
  banner remains [`STATUS.md`](STATUS.md).

### State after F8 lands (historical vs today)

After F8.2, consumers of `--out` got a frozen graph that matches include/wiki
reality, not only parent topology. **F8.3 shipped in v0.3.1:** incremental HTML
walks the same reverse dependencies IR publishes (fingerprints still seed the
dirty set; reverse walk expands dependents). Authors keep writing Markdown the
same way.

---

## 3. Phased roadmap table

| Phase | Product | Theme | User outcome |
|-------|---------|-------|--------------|
| Close F8 | **0.3.0** | F8.1 + F8.2 | **Shipped:** `--out` emits IR 0.2 with edges + reverseIndex; compiler `boris/0.3.0` |
| Dirty-set | **0.3.1** | F8.3 | **Shipped / tagged:** incremental dirty-set uses frozen reverse index |
| Truth | docs | Hygiene-G | STATUS / README / RELEASE-GATE match the binary (ongoing as cuts land) |
| Build productization | **0.3.1+ / residual** | P4 slices | **Partially shipped** (multi-target CLI order independence, output_digest cache freshness, watch path hygiene); residual measurement-driven work remains |
| Authoring / themes | **0.3.1 tree** | F9 | **Shipped:** heading wiki (#40); F9.1 layout/theme (#41); F9.2 hardening (#42) |
| Post-F9.2 future | later | §13 | Layout selection rules; external stylesheet policy; optional DaisyUI/static theme; real-site migration; IR layout/asset **deferred** |
| Edge expansion | **0.5.0?** | F10 *optional* | IR-visible layout/asset only if needed (schema **0.3.0**) |

### Sequencing (mental model)

```text
[today 0.3.1 tagged, IR 0.2, F9.1+F9.2 on main]
        │
   F8.1 freeze ──► F8.2 emit ──► v0.3.0 (IR 0.2)
        │                              │
        │                              ├─ Hygiene-G (docs)
        │                              ▼
        └──────── F8.3 dirty-set ──► v0.3.1 (tagged)
                                       │
                    ┌──────────────────┼──────────────────┐
                    ▼                  ▼                  ▼
              P4 residual        F9 shipped           later F10
           watch/cache         heading wiki #40      IR layout/asset
           ergonomics          F9.1 + F9.2 #41–42    schema 0.3 (deferred)
                                       │
                                       ▼
                              post-F9.2 future (§13)
```

---

## 4. Feature cards

### F8.1 + F8.2 → **v0.3.0 shipped** (do not redesign)

| Field | Content |
|-------|---------|
| **Name / id** | F8.1 resolve/freeze · F8.2 emit + goldens + version bump |
| **User outcome** | Tools and humans can read a frozen, typed dependency graph from `--out` that matches include/wiki reality. |
| **Why now** | Shipped so consumers no longer stay on IR 0.1.0. |
| **Contract work** | Shape is in [`ir-schema.md`](contracts/ir-schema.md) and [`includes-and-wiki-links.md`](contracts/includes-and-wiki-links.md); F8.2 promoted the fixture skeleton to full goldens and the RELEASE-GATE check is live. |
| **Code hotspots** | `src/pipeline.zig`, `src/graph.zig`, `src/json_out.zig`, include/wiki reuse, version constants (`build.zig.zon`, compiler id). |
| **Risks / honesty** | HTML path must stay green; IR validation must not diverge from F7 rules; no cross-OS bit-identical IR claim. |
| **Verification** | `zig build test`; graph-native fixture golden; dual-run IR; `./scripts/release-gate.sh`. |
| **PR / agent split** | **One agent owns** graph / pipeline / json_out freeze window. Parallel only: docs STATUS prep, content notes, CI checklist text. |

**Tag policy:** **v0.3.0 = F8.1 + F8.2**, as shipped. F8.3 shipped separately as
**v0.3.1** (see next card).

---

### F8.3 → **v0.3.1 shipped / tagged**

| Field | Content |
|-------|---------|
| **Name / id** | F8.3 |
| **User outcome** | `--incremental` / watch rebuilds use the same frozen reverse dependencies IR publishes. |
| **Status** | **Done** in product **v0.3.1** / compiler `boris/0.3.1`. IR `schemaVersion` stayed **0.2.0** (no edge-shape change). |
| **Contract work** | Dirty-set source of truth documented in [`ir-schema.md`](contracts/ir-schema.md) / HTML planning path. **No** `schemaVersion` bump. |
| **Code hotspots** | `src/cache.zig`, `src/dependency.zig`, `src/compile.zig`; shared freeze structure with IR path. |
| **Honesty** | Fingerprints remain the content-addressed change detector; reverse walk expands affected parent/reference dependents. Nested includes use forward walks of the same direct edges. |
| **Verification** | Include/wiki incremental e2e; full-vs-incremental site compare; release gate. |

---

### Hygiene-G — truth after tag

| Field | Content |
|-------|---------|
| **Name / id** | Hygiene-G |
| **User outcome** | Agents and humans read one story: product **0.3.1**, IR **0.2**, F8.1–F8.3 shipped, F9 heading/layout/theme slices shipped, future work is post-F9.2 only. |
| **Why now** | Independent of code; prevents re-planning shipped work as greenfield. |
| **Contract work** | None for this roadmap edit (STATUS, CHANGELOG tag sections, README versions, RELEASE-GATE header, contracts README capability rows stay aligned as cuts land). |
| **Code hotspots** | `docs/*`, optionally sample `content/` notes. |
| **Risks** | Overclaiming unshipped layout-selection / IR layout edges / DaisyUI productization. |
| **Verification** | Grep for stale product/IR / “F8.3 pending” claims; smoke `boris` on `content/`. |
| **PR / agent split** | Fully parallel; docs-only agent. |

### Knowledge-system extension — semantic relations + Context Bundles → shipped

This track is now merged on `main` via PRs #43 and #44. It makes the validated
graph useful as an explicit knowledge surface without turning Boris into a
JavaScript application stack. Follow-on retrieval and bundle-profile work is
deferred until real-site dogfooding establishes the need.

| Cut | User outcome | Contract / gate |
|-----|--------------|-----------------|
| Semantic relations | Authors can declare bounded directional relations; relation-bearing IR is explicitly 0.3 while relation-free IR 0.2 remains stable. | [`semantic-relations.md`](contracts/semantic-relations.md); all four kinds, invalid-target diagnostics, and deterministic relation golden. |
| AI Context Bundle | `--context` emits one uploadable Markdown bundle plus machine manifest, graph, per-page provenance, and source hashes. | [`context-bundle.md`](contracts/context-bundle.md); repeated export identity and failed-input preservation. |
| Follow-on | Add relation-aware retrieval/impact selection and bundle profiles only after the base bundle contract is proven. | Do not silently mutate RAG schema 1; add a deliberate contract first. |

---

### P4 — build-system productization (partially shipped; residual remains)

| Field | Content |
|-------|---------|
| **Name / id** | P4 |
| **User outcome** | Large-site rebuilds stay correct under watch and multi-target; residual cache bugs closed; ergonomics improved. |
| **Shipped slices (v0.3.1 era)** | Multi-target CLI order independence + usage exits; SHA-256 `output_digest` cache freshness; watch layout-path / stage-ignore hygiene; compile/assemble test workdir isolation. |
| **Still residual** | Measurement-driven watch fan-out, optional native FS events, bounded scale smoke only with a harness — see STATUS “Later.” |
| **Contract work** | Amend [`watch-mode.md`](contracts/watch-mode.md) only if fan-out behavior changes; honesty notes in STATUS. **No** IR kind expansion. |
| **Code hotspots** | `src/watch.zig`, `src/cache.zig`, `src/compile.zig`, `src/target.zig`. |
| **Risks** | Over-promising native FS events; marketing “instant” rebuilds without measurement. |
| **Verification** | Multi-target watch tests; incremental stress on synthetic trees (time-bounded / opt-in if needed). |
| **PR / agent split** | One agent: watch residual. One agent: cache residual. **Not** both editing `compile.zig` at once. |

**P4 sub-themes (status):**

1. Residual cache correctness (size vs content hash) — **largely closed** via `output_digest`; keep size as prefilter.
2. Reverse-index-aware watch fan-out **or** explicit “fingerprint remains SoT” — correctness path uses shared reverse semantics; fan-out optimization still optional.
3. Multi-target + incremental CLI/help ergonomics — **shipped** (order-independent targets, canonical diagnostics).
4. Optional: bounded synthetic scale smoke (10k-class) — **insufficient evidence** for a dedicated release theme without a harness first.
5. Native FS events — platform-qualified only; poll stays portable path.

---

### F9 — authoring / HTML polish → **heading + layout/theme shipped**

| Field | Content |
|-------|---------|
| **Name / id** | F9 (slices  heading wiki · 9.1 · 9.2) |
| **User outcome** | Sample site and author features feel complete for real docs, without inventing MDX. |
| **Shipped** | **PR #40** — `[[entity-id#heading-id]]` / labeled form; Apex-rendered `id` match; fail loud (`heading-ids.md`). **PR #41 (F9.1)** — closed layout plan + target-owned theme assets (`templating-and-themes.md`). **PR #42 (F9.2)** — layout UTF-8 at split; orphan theme-asset scrub; expanded fixture/failure coverage. |
| **Contract work** | [`heading-ids.md`](contracts/heading-ids.md), [`templating-and-themes.md`](contracts/templating-and-themes.md); theme-site + theme-adversarial fixtures. |
| **Code hotspots** | `wikilink`, `html_toc`, `assemble`, `theme`, `compile`, `content/`. |
| **Risks** | Second component without registry discipline; Apex fenced-div quirks — document, don’t fake (`APEX-PENDING`). |
| **Verification** | HTML fixtures; theme-site full vs incremental; content smoke; no IR schema change. |
| **Residual F9-adjacent** | TOC/nav polish; sample-content honesty; components policy remains Aside-only unless reopened. Post-F9.2 items live in **§13**. |

---

### F10 — IR edge expansion (optional, deferred) → **0.5.0?**

| Field | Content |
|-------|---------|
| **Name / id** | F10 |
| **User outcome** | External IR consumers see layout/asset deps the HTML cache already tracks. |
| **Why now** | **Not now by default.** IR 0.2 deliberately omits these kinds; expand when a consumer or multi-layout story requires it. Explicitly deferred after F9.2. |
| **Contract work** | New IR schema (recommend **0.3.0**) + fixtures; amend non-goals in ir-schema. |
| **Code hotspots** | `graph`, `json_out`, `dependency`, pipeline freeze. |
| **Risks** | Schema churn; awkward non-page layout endpoints. |
| **Verification** | New goldens; dual-run; release-gate. |
| **PR / agent split** | Contract-first PR → implement PR. Re-apply freeze rules on graph/emit. |

---

## 5. Candidate themes — rank / cut / resequence

### Graph / IR / build system

| Theme | Recommendation | Rationale |
|-------|----------------|-----------|
| F8.3 dirty-set productization | **Shipped (v0.3.1)** | Reverse-index-backed incremental dirty-set is product reality. |
| IR-visible layout/asset edges | **Deferred (F10)** | Contract forbids as v0.2 kinds; HTML fingerprints cover rebuild correctness. |
| Wiki `[[id#heading]]` | **Shipped (PR #40)** | Apex heading-id contract + fail-loud HTML validation. |
| HTML/IR include parity residual | **Shipped with F8.2** | Same syntax/diagnostics; residual = goldens + dual-path tests. |
| Reverse-index watch fan-out | **P4 residual (optional)** | Correctness uses shared reverse semantics; fan-out is optimization. |
| Cache residual (size vs hash) | **Shipped slice** (`output_digest`) | Size remains prefilter; content digest closes same-length corruption. |

### Authoring / HTML product

| Theme | Recommendation |
|-------|----------------|
| More components beyond Aside | **Explicit non-support for 0.3–0.4** unless a named component + registry contract opens. Prefer Apex-native + Aside. |
| Sample content honesty / dogfood | **Ongoing hygiene** after every feature cut; root `content/` is SoT. |
| TOC/nav polish; fenced divs pending | **Low-priority residual**; keep pending honesty for fenced divs. |
| Closed layout + theme assets (F9.1/F9.2) | **Shipped** (#41 / #42). |
| Multi-target + incremental ergonomics | **Shipped P4 slice**; residual measurement work only. |
| Page layout selection / external CSS / DaisyUI | **Post-F9.2 future (§13)** — not product default claims. |

### Hardening / scale

| Theme | Recommendation |
|-------|----------------|
| TOCTOU / symlink publish residual | **Opportunistic hygiene**; not a version theme. Partial re-check already landed. |
| 10k–50k page perf | **Insufficient evidence** for a dedicated release without a harness. Measurement-first under residual P4. |
| Determinism / cross-OS honesty | **Keep current claims**; expand only with dedicated CI goldens. |
| Watch native FS events | **Optional residual**; poll remains portable baseline. |

### Packaging / release

| Theme | Recommendation |
|-------|----------------|
| **v0.3.0** | **Tagged** — F8.1+F8.2 (schema 0.2 emit + goldens + version bump + gate). |
| **v0.3.1** | **Tagged** — F8.3 dirty-set + P4 multi-target / cache freshness slices. |
| RAG × IR 0.2 | No RAG schema bump for F8; update `boris_version` only. |
| CI / release-gate growth | Graph-native fixture compile + dual-run; keep Linux + macOS; theme fixtures as HTML path grows. |

### Process

| Theme | Recommendation |
|-------|----------------|
| Multi-agent discipline | One agent = one topic branch = one primary folder set; freeze graph/pipeline/json_out during F8 (and F10). |
| STATUS cadence | Update STATUS the day features merge and on every product tag; contracts-first features update contracts in the same PR as emit. |
| Do not re-open as greenfield | F8.1–F8.3, heading-target wiki, F9.1, F9.2, closed adversarial #7–#28. |

---

## 6. Cut list / not now

Unless explicitly reopened:

- Subprocess markdown (`pandoc`, etc.)
- Next / Astro / React / other stacks as the site compiler
- Unrestricted MDX / executable components
- Full YAML frontmatter
- Embedded HTTP dev server
- Marketing performance claims without measurement
- Cross-OS bit-identical trees without evidence
- Parallel rewrites of freeze/emit during F8 (historical)
- Silent IR edge-kind expansion under `schemaVersion` `0.2.0`
- Standalone HTML/RAG pages per Aside
- Replacing Zig build system or Apex C-ABI path
- Node/bundler/Tailwind **in the product hot path** (optional prebuilt static CSS only; see §13)

---

## 7. Decision log

Open calls and **recommended defaults** until overridden. Outcomes noted where
resolved by shipping.

| ID | Decision | Recommended default / outcome |
|----|----------|-------------------------------|
| **D1** | Is **v0.3.0** = F8.1+F8.2 only, or must include F8.3? | **Resolved:** F8.1+F8.2 only as **v0.3.0**; F8.3 → **v0.3.1** (tagged). |
| **D2** | Schema policy for layout/asset in IR | **Stay internal** (HTML planner/cache); next emit change → IR schema **0.3.0**, not silent add under 0.2.0. **Still deferred (F10).** |
| **D3** | Scope of 0.3.x after tag | Graph-native IR + dirty-set unity + docs truth + opportunistic P4/F9 slices landed in-tree. |
| **D4** | Output cache freshness: size vs content hash | **Resolved slice:** size prefilter + SHA-256 `output_digest` of published page bytes. |
| **D5** | `[[id#heading]]` in 0.4 | **Resolved early:** shipped PR #40 with [`heading-ids.md`](contracts/heading-ids.md); Apex id parity, fail loud. |
| **D6** | Second registered component | **No** unless named + `components.md` registry design reopened. |
| **D7** | Watch reverse-index fan-out vs full rediscovery | **Correctness first** (rediscover + fingerprint + shared reverse expand); fan-out optimization only with measurement. |
| **D8** | RAG schema vs product 0.3 | **RAG schema stays `1`**; only `boris_version` tracks product. |

---

## 8. Near-term execution plan (2–4 weeks) — **historical F8 window**

The week-by-week plan below was the F8 critical-path schedule. It is retained
for history. **Do not execute as if F8.3 or early F9 were still open.**

### Freeze window (historical F8 merge guidance)

| Module / area | Policy |
|---------------|--------|
| `pipeline`, `graph`, `json_out` | **F8-only** (historical) |
| `include`, `wikilink` | F8 may touch for IR projection; no parallel syntax changes |
| `cache`, `compile` (dirty-set) | F8.3 only after F8.2 **or** same owner stacking |
| `content/`, TOC polish, STATUS drafts | **Parallel OK** |
| Unrelated adversarial / `src/*` | Prefer **after** F8 merge |

### Week-by-week outline (completed)

**Week 1 — Finish F8.1–F8.2 (completed)**

- Owner: Agent E (or sole implementer).
- Deliver: in-memory edges + reverseIndex; emit schema 0.2.0; goldens; version → 0.3.0 / `boris/0.3.0`.
- Human: review for contract conformance (sort keys, endpoint types, fail-loud include/wiki on IR).
- Gate: `zig build test` + dual IR + start release-gate extension.

**Week 2 — Tag v0.3.0 + Hygiene-G (completed)**

- F8.2 merged; product **v0.3.0** / IR **0.2.0** tagged.
- Docs: STATUS, README, RELEASE-GATE, CHANGELOG section, contracts README “implemented.”

**Week 3 — F8.3 → v0.3.1 (completed / tagged)**

- Unify dirty-set with frozen reverse index; keep fingerprint skip logic.
- Product/compiler **0.3.1** / `boris/0.3.1`; IR stayed 0.2.0.
- Tag **v0.3.1** shipped.

**Week 4 — P4 / F9 kickoff (largely completed beyond original outline)**

- P4 slices: multi-target CLI ergonomics, cache `output_digest`, watch hygiene.
- F9: heading-target wiki (PR #40); F9.1 layout/theme (PR #41); F9.2 hardening (PR #42).

### Merge order (historical + actual)

```text
F8.1 (internal freeze)
  → F8.2 (emit + goldens + 0.3.0 versions)
  → v0.3.0
  → Hygiene-G (docs)
  → F8.3 (dirty-set) → tag v0.3.1
  → P4 residual slices (CLI / cache / watch)
  → F9 heading wiki (#40) → F9.1 (#41) → F9.2 (#42)
  → post-F9.2 future (§13)
```

### Ownership sketch (historical)

| Role | Owns |
|------|------|
| **Human** | Tag authority, contract interpretation disputes |
| **Agent E** | F8.1–F8.3 lineage |
| **Agent Docs** | Hygiene-G / roadmap truth |
| **Agent P4 / F9** | Post-0.3.0 residual and authoring/theme slices |

---

## 9. First PR stack after F8 merges — **historical; most items done**

Original planned stack (status annotated):

1. **feat(f8.3):** reverseIndex-backed dirty-set + incremental e2e; tag **0.3.1** — **done / tagged**.
2. **test/chore(p4-cache):** residual freshness tests; document honesty limits — **done** (`output_digest`).
3. **docs/feat(p4-watch):** contract note or selective fan-out only with tests — **partial** (watch hygiene landed; optional fan-out residual).
4. **feat(f9):** heading wiki + layout/theme — **done** (#40 / #41 / #42).

### Freeze rules (re-apply for F10)

- One agent owns graph freeze + IR emit.
- Parallel agents stay off `pipeline` / `graph` / `json_out`.
- Contracts-first for any new edge kind or author syntax.
- Prefer smallest vertical slices over big rewrites.
- Label **insufficient evidence** rather than inventing scale claims.

---

## 10. Verification cheat sheet (by phase)

| Phase | Commands / checks |
|-------|-------------------|
| F8.2 | `zig build test`; IR dual-run; graph-native fixture golden; `./scripts/release-gate.sh` |
| F8.3 | Incremental e2e (include/wiki/layout); full-vs-incremental site compare |
| Hygiene-G | Grep stale version / “F8.3 pending” claims; `boris --quiet` on `content/` |
| P4 residual | Watch multi-target tests; cache unit tests; optional bounded stress |
| F9.1 / F9.2 | Theme-site + theme-adversarial; UTF-8 layout failures; orphan scrub; multi-target isolation |
| Heading wiki | HTML fixtures; `heading-ids.md` cases; content smoke |
| F10 (if ever) | New IR goldens; dual-run; schema bump checklist |

Hostile Apex / sanitizer policy unchanged: skip is not a pass.

---

## 11. Related docs

| Doc | Role |
|-----|------|
| [`STATUS.md`](STATUS.md) | Living “where we are” — update on tag |
| [`CHANGELOG.md`](../CHANGELOG.md) | What landed |
| [`contracts/ir-schema.md`](contracts/ir-schema.md) | IR 0.2 normative |
| [`contracts/includes-and-wiki-links.md`](contracts/includes-and-wiki-links.md) | F7 + IR projection |
| [`contracts/heading-ids.md`](contracts/heading-ids.md) | Heading wiki fragments (PR #40) |
| [`contracts/templating-and-themes.md`](contracts/templating-and-themes.md) | F9.1 / F9.2 layout + theme assets |
| [`contracts/parallel-rendering.md`](contracts/parallel-rendering.md) | Coordinator sequential; workers page-only |
| [`contracts/watch-mode.md`](contracts/watch-mode.md) | Watch / incremental relationship |
| [`RELEASE-GATE.md`](RELEASE-GATE.md) | Mechanical ship checks |
| [`AGENTS.md`](../AGENTS.md) | Hard constraints + long-term graph-native direction |
| [`README.md`](../README.md) | Human front door |

---

## 12. Changelog for this doc

| Date | Note |
|------|------|
| 2026-07-15 | Initial draft from post-F8 planning session. Defaults D1–D8; F8 treated as in-flight fixed contract work. |
| 2026-07-15 | Truth reconciliation after PR #42: F8.3 / v0.3.1 tagged; heading wiki #40; F9.1 #41; F9.2 #42 shipped; post-F9.2 future moved to §13; historical F8 weeks retained. |

When decisions D1–D8 change, update §7 and the phase table in the same edit.
Update [`STATUS.md`](STATUS.md) when a phase becomes active product reality — this
file is a roadmap draft, not the living phase banner.

---

## 13. Future work after F9.2

Active planning surface **after** shipped F8.3, PR #40, F9.1, and F9.2.
Nothing here is claimed as product default until contracted and tested.

### 13.1 Page layout selection rules

- **Today:** one layout per target (CLI / default path); theme root derived from
  layout path (`…/layouts/<file>.html`); `--theme ROOT` sugar for
  `ROOT/layouts/main.html`.
- **Open:** per-page or per-role layout selection (CLI vs config vs frontmatter).
  Deferred open decision in [`templating-and-themes.md`](contracts/templating-and-themes.md) §12.
- **Constraint:** must stay fail-loud, deterministic, multi-target isolated; no
  silent fall-back to a different layout.

### 13.2 External stylesheet policy

- **Today:** managed theme `assets/` inventory is opaque bytes; `{{asset-url
  assets/…}}` validated against inventory; ASCII-only path grammar.
- **Open:** opt-in external stylesheet warning / allowlist shape (deferred in
  templating contract §12). Prefer documenting trust boundaries over inventing
  a CSS pipeline inside Boris.
- **Non-goal:** Node bundler or CDN fetch in the compile hot path.

### 13.3 Optional DaisyUI / static-theme experiment

- Prebuilt CSS under theme `assets/` may be treated as opaque static files.
- Default `zig build`, release gate, and bare `boris` must **not** require Node,
  a bundler, or network access.
- Experiment only: fixture or sample theme may demonstrate DaisyUI-class markup
  when CSS is vendored; not a product dependency and not marketing copy for
  “Boris includes DaisyUI.”

### 13.4 IR layout / asset edges — explicitly deferred (F10)

- HTML planner/cache may track layout + referenced asset bytes for dirtying.
- IR **0.2.0** does **not** emit `layout` / `asset` edge kinds.
- Revisit only with a consumer need, contracts-first schema bump (recommend IR
  **0.3.0**), goldens, and freeze-window discipline on `graph` / `json_out`.
- Do not silently expand edge kinds under schema `0.2.0`.

### 13.5 Practical real-site migration and content conversion

- Root `content/` remains sample SoT; real migrations need authoring guides:
  closed frontmatter (`parent` only), includes tree, wiki entity ids, optional
  heading fragments, theme layout/asset layout.
- Conversion work is content + docs hygiene, not a second compiler dialect.
- Prefer measured incremental rebuilds on a real tree over synthetic slogans.
- Keep migration notes honest about default CLI (`boris` → `dist/`) and opt-in
  IR/RAG flags.

### 13.6 Suggested next PR themes (unordered)

| Theme | Notes |
|-------|-------|
| Layout selection design | Contract-first; one-layout-per-target remains default until accepted |
| External CSS policy note | Docs/contract honesty; no bundler |
| Static theme / DaisyUI sample | Optional opaque CSS only; gate must stay Node-free |
| Real-site content conversion | Sample or companion tree; no product language change |
| P4 residual | Watch fan-out measurement; native FS events platform-qualified |
| F10 IR layout/asset | **Only if** consumer demand; schema bump required |

Do not re-open F8.3, PR #40 heading wiki, F9.1, or F9.2 as greenfield work.
