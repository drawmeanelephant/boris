# Roadmap — post Feature 8 (draft)

**As of:** 2026-07-15 · product **0.3.0** / IR **0.2.0** · plan only · not a
substitute for [`STATUS.md`](STATUS.md)
**Current state:** F8.1–F8.2 are shipped. F8.3 remains pending; it must not be
described as reverse-index-backed incremental or watch behavior until it lands.
Plan everything *after* the shipped F8.1–F8.2 work, plus the remaining F8.3 and
future roadmap items.

Normative behavior: [`docs/contracts/`](contracts/). Hard constraints:
[`AGENTS.md`](../AGENTS.md). Living phase: [`STATUS.md`](STATUS.md).

---

## 1. Executive summary

**Today (product 0.3.0):** Boris is an HTML-first Zig documentation compiler —
Apex Unified, Trunk/Satellite graph, Feature 7 includes + wiki on the HTML path,
P2/P3 incremental / watch / jobs / multi-target. Machine IR emits
`schemaVersion` **0.2.0** with typed dependency edges and a deterministic
`reverseIndex`.

**F8.1–F8.2 shipped (product 0.3.0):** the public IR is graph-native —
`schemaVersion` **0.2.0**, typed `page` / `source` endpoints, direct
`parent` / `include` / `reference` edges, and deterministic `reverseIndex`.
HTML authoring and default CLI outcomes stay. F8.3 is the future work to unify
incremental dirty-set consumption; current incremental/watch behavior is not
claimed to be reverse-index-backed.

**Next ~3–6 cuts:** complete F8.3 as **0.3.1** if not bundled, keep docs
hygiene current, then build-system productization (**0.4**) and authoring
polish — not polyglot SSG work, not unrestricted MDX, not marketing perf claims
without measurement.

---

## 2. Assumptions after F8

| Assumption | Detail |
|------------|--------|
| Binary ↔ IR | Product 0.3.0 emits IR 0.2.0 with compiler id `boris/0.3.0`; F8.1–F8.2, goldens, and the release-gate check are shipped. |
| Include / wiki | Same fence-aware, fail-loud rules on HTML and IR paths; Apex FS includes stay off. |
| layout / asset | May exist in internal `DependencyIndex`; **not** IR v0.2 edge kinds until a later schema decision. |
| Determinism | Dual-run byte-identical IR **per host**; no bit-identical cross-OS claim without evidence. |
| Watch | Portable polling remains the baseline; native FS events are platform-qualified bonus. |
| RAG | Format `boris-rag` / schema `1` stays unless catalog deliberately embeds IR edges; only `boris_version` tracks product. |
| F8.3 packaging | May ship as **0.3.1** if not green in the same freeze as F8.2. |
| Non-goals | Subprocess markdown, Next/Astro/React as compiler, unrestricted MDX, full YAML frontmatter, embedded HTTP dev server. |

### Situation snapshot (mid-2026-07-15)

- **Shipped:** v0.2.0 (HTML default, Apex, nav/TOC, P2/P3); v0.2.1 (Feature 7 includes/wiki); v0.3.0 (F8.1–F8.2, IR 0.2).
- **Pending:** F8.3 incremental dirty-set consumption; the current HTML
  incremental/watch path is not claimed to consume the IR `reverseIndex`.
- **Hardening:** adversarial issues #7–#28 closed; do not re-plan as greenfield.
- **Docs follow-through:** Hygiene-G updates only this roadmap and the two
  contract index files in this patch; historical docs and version-banner cleanup
  remain out of scope.

### State after F8 lands (vs today)

After F8.2, consumers of `--out` get a frozen graph that matches include/wiki
reality, not only parent topology. Incremental HTML should eventually walk the
**same** reverse index IR publishes (F8.3), reducing divergent “why didn’t this
rebuild?” behavior; that unification is not shipped yet. Authors keep writing
Markdown the same way.

---

## 3. Phased roadmap table

| Phase | Product | Theme | User outcome |
|-------|---------|-------|--------------|
| Close F8 | **0.3.0** | F8.1 + F8.2 | **Shipped:** `--out` emits IR 0.2 with edges + reverseIndex; compiler `boris/0.3.0` |
| Dirty-set | **0.3.1** | F8.3 | Incremental dirty-set uses frozen reverse index (one graph story) |
| Truth | docs | Hygiene-G | STATUS / README / RELEASE-GATE match the binary |
| Build productization | **0.4.0** | P4 | Watch / cache / multi-target ergonomics; residual correctness |
| Authoring polish | **0.4.x** | F9 | Dogfood honesty; optional heading wiki; TOC/nav residual |
| Edge expansion | **0.5.0** | F10 *optional* | IR-visible layout/asset only if needed (schema **0.3.0**) |

### Sequencing (mental model)

```text
[today 0.3.0, IR 0.2]
        │
        ▼
   F8.1 freeze ──► F8.2 emit ──► v0.3.0 (IR 0.2)
        │                              │
        │                              ├─ Hygiene-G (docs)
        │                              ▼
        └──────── F8.3 dirty-set ──► v0.3.1
                                       │
                    ┌──────────────────┼──────────────────┐
                    ▼                  ▼                  ▼
                   P4                 F9              (later F10)
              watch/cache         authoring          IR layout/asset
              multi-target        heading wiki?      schema 0.3
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

**Tag policy:** **v0.3.0 = F8.1 + F8.2**, as shipped. F8.3 remains a separate
0.3.1 planning line unless deliberately bundled in a later release decision.

---

### F8.3 → **v0.3.1** (or same cut if free)

| Field | Content |
|-------|---------|
| **Name / id** | F8.3 |
| **User outcome** | `--incremental` / watch rebuilds use the same frozen reverse dependencies IR publishes. |
| **Why now** | HTML already has fingerprints + `getAffectedPages`; unify dirty-set consumption with the frozen reverse index rather than grow a second graph. Current incremental/watch behavior remains fingerprint-based until this work lands. |
| **Contract work** | Clarify dirty-set source of truth in ir-schema / html-output (or a thin incremental note). **No** `schemaVersion` bump if emit unchanged. |
| **Code hotspots** | `src/cache.zig`, `src/dependency.zig`, `src/compile.zig`; shared freeze structure with IR path. |
| **Risks** | Path vs entity-id reverse keys; layout edges internal-only but must still dirty pages; false cache hits if output freshness is size-only. |
| **Verification** | Include/wiki incremental e2e; dual full-vs-incremental site compare on fixture tree; no IR golden change required. |
| **PR / agent split** | Prefer after F8.2 merge; if stacked, separate commit/PR for review. Freeze `cache` + `compile` dirty paths during. |

---

### Hygiene-G — truth after tag

| Field | Content |
|-------|---------|
| **Name / id** | Hygiene-G |
| **User outcome** | Agents and humans read one story: product 0.3.0, IR 0.2, F8.1–F8.2 shipped, and F8.3 is the pending next step. |
| **Why now** | Independent of code; prevents re-planning F8 as greenfield. |
| **Contract work** | None (STATUS, CHANGELOG tag section, README versions, RELEASE-GATE header, contracts README capability row). |
| **Code hotspots** | `docs/*`, optionally sample `content/` notes. |
| **Risks** | Overclaiming reverse-index-backed incremental/watch behavior before F8.3 ships. |
| **Verification** | Grep for stale product/IR claims; smoke `boris` on `content/`. |
| **PR / agent split** | Fully parallel after green F8; docs-only agent. |

### Knowledge-system extension — semantic relations + Context Bundles

This is the next product direction after graph-native dependencies: make the
validated graph useful as an explicit knowledge surface without turning Boris
into a JavaScript application stack.

| Cut | User outcome | Contract / gate |
|-----|--------------|-----------------|
| Semantic relations | Authors can declare bounded directional relations; relation-bearing IR is explicitly 0.3 while relation-free IR 0.2 remains stable. | [`semantic-relations.md`](contracts/semantic-relations.md); all four kinds, invalid-target diagnostics, and deterministic relation golden. |
| AI Context Bundle | `--context` emits one uploadable Markdown bundle plus machine manifest, graph, per-page provenance, and source hashes. | [`context-bundle.md`](contracts/context-bundle.md); repeated export identity and failed-input preservation. |
| Follow-on | Add relation-aware retrieval/impact selection and bundle profiles only after the base bundle contract is proven. | Do not silently mutate RAG schema 1; add a deliberate contract first. |

---

### P4 — build-system productization → **v0.4.0**

| Field | Content |
|-------|---------|
| **Name / id** | P4 |
| **User outcome** | Large-site rebuilds stay correct under watch and multi-target; residual cache bugs closed; ergonomics improved. |
| **Why now** | Needs F8 reverse index as product truth; independent of new authoring features. |
| **Contract work** | Amend [`watch-mode.md`](contracts/watch-mode.md) if fan-out behavior changes; honesty notes in STATUS. **No** IR kind expansion. |
| **Code hotspots** | `src/watch.zig`, `src/cache.zig`, `src/compile.zig`, `src/target.zig`. |
| **Risks** | Over-promising native FS events; marketing “instant” rebuilds without measurement. |
| **Verification** | Multi-target watch tests; incremental stress on synthetic trees (time-bounded / opt-in if needed). |
| **PR / agent split** | One agent: watch. One agent: cache residual. **Not** both editing `compile.zig` at once. |

**P4 sub-themes (ordered):**

1. Residual cache correctness (output size vs content hash policy — document or fix).
2. Reverse-index-aware watch fan-out **or** explicit “fingerprint remains SoT” contract note.
3. Multi-target + incremental CLI/help ergonomics.
4. Optional: bounded synthetic scale smoke (10k-class) — **insufficient evidence** for a dedicated release theme without a harness first.
5. Native FS events — platform-qualified only; poll stays portable path.

---

### F9 — authoring / HTML polish → **v0.4.x**

| Field | Content |
|-------|---------|
| **Name / id** | F9 |
| **User outcome** | Sample site and author features feel complete for real docs, without inventing MDX. |
| **Why now** | Independent of IR once 0.3 is out; improves dogfood and showcase honesty. |
| **Contract work** | Components policy (Aside-only vs next registered component); **heading-id contract** if `[[id#heading]]` ships. |
| **Code hotspots** | `aside` / components, `wikilink`, `html_toc`, `html_nav`, `content/`. |
| **Risks** | Second component without registry discipline; Apex fenced-div quirks — document, don’t fake (`APEX-PENDING`). |
| **Verification** | HTML fixtures; content smoke; no IR schema change. |
| **PR / agent split** | Content + TOC polish parallel; heading wiki is its own PR after contract. |

---

### F10 — IR edge expansion (optional) → **v0.5.0**

| Field | Content |
|-------|---------|
| **Name / id** | F10 |
| **User outcome** | External IR consumers see layout/asset deps the HTML cache already tracks. |
| **Why now** | **Not now by default.** IR 0.2 deliberately omits these kinds; expand when a consumer or multi-layout story requires it. |
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
| F8.3 dirty-set productization | **Soon after F8.2** (0.3.1 or same release if free) | Highest leverage of reverseIndex; incomplete F8 without it. |
| IR-visible layout/asset edges | **Internal-only through 0.4.x**; revisit as F10 | Contract forbids as v0.2 kinds; HTML fingerprints cover rebuild correctness. |
| Wiki `[[id#heading]]` | **Later (F9 optional)**; heading-id contract first | STATUS “Later”; align with TOC/rendered ids before inventing fragment URLs. |
| HTML/IR include parity residual | **Gate F8.2** | Same syntax/diagnostics; residual = goldens + dual-path tests. |
| Reverse-index watch fan-out | **P4 after F8.3** | Watch contract today: fingerprints SoT; fan-out is optimization, not correctness rewrite. |
| Cache residual (size vs hash) | **P4 micro** or 0.3.1 hygiene if easy | Prefer documented policy + tests; full output hash costs I/O — measure first. |

### Authoring / HTML product

| Theme | Recommendation |
|-------|----------------|
| More components beyond Aside | **Explicit non-support for 0.3–0.4** unless a named component + registry contract opens. Prefer Apex-native + Aside. |
| Sample content honesty / dogfood | **Hygiene-G + F9** after every feature cut; root `content/` is SoT. |
| TOC/nav polish; fenced divs pending | **F9 low-priority**; keep pending honesty for fenced divs. |
| Multi-target + incremental ergonomics | **P4** (docs + help + selective watch), not new IR. |

### Hardening / scale

| Theme | Recommendation |
|-------|----------------|
| TOCTOU / symlink publish residual | **Opportunistic hygiene**; not a version theme. Partial re-check already landed. |
| 10k–50k page perf | **Insufficient evidence** for a dedicated release without a harness. Measurement-first under P4. |
| Determinism / cross-OS honesty | **Keep current claims**; expand only with dedicated CI goldens. |
| Watch native FS events | **Optional P4+**; poll remains portable baseline. |

### Packaging / release

| Theme | Recommendation |
|-------|----------------|
| When to tag **v0.3.0** | When F8.1+F8.2 are green (schema 0.2 emit + goldens + version bump + gate). |
| RAG × IR 0.2 | No RAG schema bump for F8; update `boris_version` only. |
| CI / release-gate growth | F8.2 adds graph-native fixture compile + dual-run; keep Linux + macOS. |

### Process

| Theme | Recommendation |
|-------|----------------|
| Multi-agent discipline | One agent = one topic branch = one primary folder set; freeze graph/pipeline/json_out during F8 (and F10). |
| STATUS cadence | Update STATUS the day F8 merges and on every product tag; contracts-first features update contracts in the same PR as emit. |
| Do not parallel with F8 | Second rewrite of edge freeze, reverseIndex sort, IR emit keys, or include/wiki IR projection. |

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
- Parallel rewrites of freeze/emit during F8
- Silent IR edge-kind expansion under `schemaVersion` `0.2.0`
- Standalone HTML/RAG pages per Aside
- Replacing Zig build system or Apex C-ABI path

---

## 7. Decision log

Open calls and **recommended defaults** until overridden:

| ID | Decision | Recommended default |
|----|----------|---------------------|
| **D1** | Is **v0.3.0** = F8.1+F8.2 only, or must include F8.3? | **F8.1+F8.2 only**; F8.3 → **0.3.1** unless already done in freeze. |
| **D2** | Schema policy for layout/asset in IR | **Stay internal through 0.4**; next emit change → IR schema **0.3.0**, not silent add under 0.2.0. |
| **D3** | Scope of 0.3.x after tag | **0.3.x = graph-native IR + dirty-set unity + docs truth.** Authoring → 0.4.x. |
| **D4** | Output cache freshness: size vs content hash | **Keep size+fingerprint for 0.3**; ticket in P4 if false-hit reproduced; document residual. |
| **D5** | `[[id#heading]]` in 0.4 | **Out of 0.3**; enter only after heading-id contract + Apex id parity tests. |
| **D6** | Second registered component | **No** unless named + `components.md` registry design reopened. |
| **D7** | Watch reverse-index fan-out vs full rediscovery | **Correctness first** (rediscover + fingerprint); fan-out optimization only after F8.3 + measurement. |
| **D8** | RAG schema vs product 0.3 | **RAG schema stays `1`**; only `boris_version` tracks product. |

---

## 8. Near-term execution plan (2–4 weeks)

Assume F8 is the critical path. Human + 1–3 agents.

### Freeze window (historical F8 merge guidance)

| Module / area | Policy |
|---------------|--------|
| `pipeline`, `graph`, `json_out` | **F8-only** |
| `include`, `wikilink` | F8 may touch for IR projection; no parallel syntax changes |
| `cache`, `compile` (dirty-set) | F8.3 only after F8.2 **or** same owner stacking |
| `content/`, TOC polish, STATUS drafts | **Parallel OK** |
| Unrelated adversarial / `src/*` | Prefer **after** F8 merge |

### Week-by-week outline

**Week 1 — Finish F8.1–F8.2 (completed)**

- Owner: Agent E (or sole implementer).
- Deliver: in-memory edges + reverseIndex; emit schema 0.2.0; goldens; version → 0.3.0 / `boris/0.3.0`.
- Human: review for contract conformance (sort keys, endpoint types, fail-loud include/wiki on IR).
- Gate: `zig build test` + dual IR + start release-gate extension.
- **Do not** open layout/asset IR or heading wiki PRs.

**Week 2 — Tag v0.3.0 + Hygiene-G (0.3.0 state now)**

- F8.2 was merged; product **v0.3.0** / IR **0.2.0** is the current state.
- Docs agent: STATUS, README, RELEASE-GATE, CHANGELOG section, contracts README “implemented.”
- Optional: sample content note that IR now exposes include/reference edges (authors need not change Markdown).
- Human: full `./scripts/release-gate.sh`; CI green Linux + macOS.

**Week 3 — F8.3 (0.3.1)**

- Owner: same lineage or one agent; freeze `cache` / `compile` dirty paths.
- Unify dirty-set with frozen reverse index; keep fingerprint skip logic.
- Tests: include via fragment title change; shared include multi-parent; layout change dirties all.
- Tag **v0.3.1** if not folded into 0.3.0.

**Week 4 — P4 kickoff / residual only**

- Pick **one** vertical: (a) cache freshness residual + tests, or (b) watch contract clarification + multi-target ergonomics, or (c) synthetic scale smoke if time.
- Explicitly **not** F10 schema work.
- Human: confirm D4/D7 with any new evidence from F8.3.

### Merge order

```text
F8.1 (internal freeze)
  → F8.2 (emit + goldens + 0.3.0 versions)
  → v0.3.0
  → Hygiene-G (docs; this scoped patch)
  → F8.3 (dirty-set) → tag v0.3.1
  → P4 / F9 in parallel branches after freeze lifts
```

### Ownership sketch

| Role | Owns |
|------|------|
| **Human** | Tag authority, contract interpretation disputes, “ship 0.3.0 without F8.3?” call |
| **Agent E** | F8.1–F8.2 (and F8.3 if continuous) |
| **Agent Docs** | Hygiene-G only after green F8 |
| **Agent P4** | Starts only post-0.3.0; no graph freeze files |

---

## 9. First PR stack after F8 merges

1. **feat(f8.3):** reverseIndex-backed `getAffectedPages` + incremental e2e; tag **0.3.1**.
2. **test/chore(p4-cache):** residual freshness tests; document honesty limits.
3. **docs/feat(p4-watch):** contract note or selective fan-out only with tests.
4. **feat(f9):** content dogfood / TOC; heading wiki only with a prior contract PR.

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
| Hygiene-G | Grep stale version claims; `boris --quiet` on `content/` |
| P4 | Watch multi-target tests; cache unit tests; optional bounded stress |
| F9 | HTML fixtures; content smoke |
| F10 | New IR goldens; dual-run; schema bump checklist |

Hostile Apex / sanitizer policy unchanged: skip is not a pass.

---

## 11. Related docs

| Doc | Role |
|-----|------|
| [`STATUS.md`](STATUS.md) | Living “where we are” — update on tag |
| [`CHANGELOG.md`](../CHANGELOG.md) | What landed |
| [`contracts/ir-schema.md`](contracts/ir-schema.md) | IR 0.2 normative |
| [`contracts/includes-and-wiki-links.md`](contracts/includes-and-wiki-links.md) | F7 + IR projection |
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

When decisions D1–D8 change, update §7 and the phase table in the same edit.
Update [`STATUS.md`](STATUS.md) when a phase becomes active product reality — this
file is a roadmap draft, not the living phase banner.
