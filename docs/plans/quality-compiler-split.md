# Quality split — controlled refactor of six hot files

> **Milestone:** quality-compiler-split — reduce function complexity and file size in six compiler-critical modules without behavioral or contract change, one concern per PR, green at every step.
>
> **Date:** 2026-08-21 · **Author:** quality review (Muse Spark) · **Integration line:** `afterparty` (Build Week; `main` frozen) · **Base:** `afterparty@676` · **Contract change:** none · **Toolchain change:** none

## 0. Why this exists

Review `2026-08-21` of six big-ish, important files found 3 systemic costs:

1. **Duplicated streaming JSON / evidence-input / binding logic** across `publication_claims.zig`, `publication_touches.zig`, `publication_proof_pack.zig` (~300 loc copied, 3 error-type remaps).
2. **Single monster functions** — `cli.zig:309` `parseOptions` 1623 loc (CC >120), `compile.zig:2349` `compilePagesInner` ~380 loc, `compile.zig:1254` `compileHtmlSiteMulti` 206 loc, `main.zig:1299` `buildStandardSiteProjection` 137 loc — each mixes 4–6 concerns under time pressure, making next bug high-risk.
3. **File size >2000 loc with tests interleaved** — `compile.zig:1` 10535 loc (prod ~2500 + 7000 test), `publication_touches.zig:1` 6108 loc — reviewers cannot scope impact.

This milestone does **not** invent targets, change IR, widen front-matter, add JS/bundlers, or claim perf gains. It repeatedly applies one operation: *extract a pure helper or a narrow orchestrator, keep the call site’s error type and diagnostics byte-identical, prove `zig build test` + `release-gate` still green, then land.*

Each slice keeps `zig build test` as baseline gate; slices touching HTML also run `./scripts/release-gate.sh` when scope permits.

---

## 0.1 Baseline metrics (afterparty tip)

| File | total | prod est. | largest prod fn | next |
|---|---|---|---|---|
| `src/compile.zig:1` | 10535 | ~2500 pre-tests | `compilePagesInner:2349` ~380 | `compileHtmlSiteMulti:1254` 206, `buildSiteHeadingIndex:1800` 143 |
| `src/publication_touches.zig:1` | 6108 | ~3500 | `parseCheckAfterBegin:579` 145 | `parseTouchesStreamInner:1818` 208 |
| `src/cli.zig:1` | 4132 | 4132 | `parseOptions:309` 1623 | `findBadArg:2260` 117 |
| `src/main.zig:1` | 3391 | 3391 | `runStandardSiteSmoke:1006` 276* | `runHtml:2637` 110, `buildStandardSiteProjection:1299` 137 |
| `src/publication_proof_pack.zig:1` | 3309 | ~1650 | `writeAfterTouches:295` 129 | `installPair:1748` 85, `renderSummary:557` 122 |
| `src/publication_claims.zig:1` | 2288 | ~1150 | `parseCheckAfterBegin:395` 138 | `parseChecksStream:698` 125 |

*`runStandardSiteSmoke` iterates over smoke phases; product complexity sits in dispatch, not size. `compile.zig` max is product, not the test helpers after `src/compile.zig:3525` (`findArtifactRecord:3597` 4732-cross-test inclusive — not a product candidate).

No external review packet drives this; executable behavior + current `docs/contracts/` are authority per `AGENTS.md:1`.

## 0.2 Guardrails (non-negotiable)

- Zig 0.16 only; Oliver native; `build.zig`/`build.zig.zon` stay authoritative; no Node/SSG/bundler/hydration introduced (`AGENTS.md:1`).
- No contract, schema, `schemaVersion`, `compiler_id`, or `dist/` default change. If a slice wants one, stop and open a separate contract PR.
- No behavioral change: same error sets (remapped where contracts demand `InvalidChecksReport` vs `InvalidClaimsReport` etc.), same diagnostics text, same atomic-stage/rename discipline.
- One agent owns a branch + its hot files until handoff/merge/abandon. No direct pushes to `main` or `afterparty`; fresh topic branch from up-to-date `afterparty` per slice (`AGENTS.md:1`).
- `zig build test` before + after every substantive change; `./scripts/release-gate.sh` for IR/HTML-facing slices when scope permits.
- Generated outputs (`dist/`, `rag/`, `source-rag/`, `zig-out/`, caches) stay ignored currency; preserve unrelated dirty files/worktrees.
- Each substantive PR ends with `docs/COMPLETION-REPORT-TEMPLATE.md:1` evidence block.

## 0.3 Milestone acceptance

- Each of the six files has **no prod function >120 loc** and **no file >1500 prod loc** (tests may stay inline per Zig convention, but prod modules factored).
- `zig build test` + `release-gate` green on every slice tip; sequential vs parallel HTML (`--jobs 1` vs `--jobs 4`) byte-identical on `fixtures/content/valid` and `test/fixtures/html/content`.
- No new public API beyond narrow internal modules; `docs/SOURCE-MAP.md:1` updated when a new job appears, otherwise untouched.
- No changelog fragment required unless a slice documents a user-visible contract; fragments are for product-visible changes only (`docs/changelog.d/README.md:1`).

---

## 1. Sequencing and dependencies

```
Slice 0 — baseline / prep (no product change)
   |
Slice 1 — shared publication JSON + evidence input  (enables 2–4)
   +---------+---------+
   v         v         v
Slice 2   Slice 3   Slice 4   (claims / touches / proof-pack, parallelizable after 1)
   \         |         /
    \        |        /
     v       v       v
Slice 5 — compile site-multi / PagesInner / stage+cache+heading (independent of 1–4, but after 1 for shared helpers)
   |
Slice 6 — cli parseOptions decomposition (largest CC, isolated)
   |
Slice 7 — main dispatch + profile-loader dedup (depends on 1, touches after 6 for flag plumbing)
```

Preferred landing order `0 → 1 → 2 → 3 → 4 → 5 → 6 → 7`. Slices 2/3/4 may land in any order after 1; 5 may land anytime after 0 but benefits from 1’s `EvidenceInput`. Do **not** batch: one PR per slice, one concern per commit where practical.

---

## 2. Slices — one subissue per slice

Each subissue below is a ready-to-file GitHub issue body. Branch names are prefixed `codex/quality-` per `AGENTS.md:1`. Assignee: one agent per branch.

---

### Slice 0 — QM-0: Baseline capture and slice harness

**Branch:** `codex/quality-baseline` → PR at `afterparty` · **Type:** docs / no product change · **Est.:** 0.5d

**Goal:** Freeze before/after measurement so later slices cannot claim silent drift.

**Scope:**
- Add this plan file if not yet landed.
- Record current LOC + longest fns (`wc -l` + `grep -n "^pub fn\|^fn "` table from 2026-08-21 review).
- Capture `git status --short`, `zig build test` timing, and `./scripts/release-gate.sh` pass log as baseline artifact (not committed bytes — paste log into PR body).

**Verification:**
```bash
git fetch origin && git checkout afterparty && git pull --ff-only
git checkout -b codex/quality-baseline
wc -l src/publication_claims.zig src/compile.zig src/publication_touches.zig src/cli.zig src/publication_proof_pack.zig src/main.zig
grep -n "^pub fn\|^fn " src/cli.zig | head
zig build test  # baseline
./scripts/release-gate.sh  # when scope permits
```

**Out of scope:** any product code move.

**Drives slices 1–7.**

---

### Slice 1 — QM-1: Shared publication JSON stream + evidence input

**Branch:** `codex/quality-shared-publication-json` → `afterparty` · **Est.:** 1d · **Risk:** low

**Context:** `src/publication_claims.zig:176` and `src/publication_touches.zig:188` share ~110 loc of `jsonTokenText`/`readJsonString`/`readJsonDigest`/etc with identical logic but distinct `fail_error` mappings (`InvalidChecksReport` vs `InvalidClaimsReport`). `EvidenceInput` struct (`publication_claims.zig:831` 47 loc, `publication_proof_pack.zig:103` 43 loc, touches variant) repeats no-follow open + hash-then-rewind pattern.

**Goal:** Extract without behavioral change:

- `src/publication_json_stream.zig` — pure helpers `jsonTokenText`, `freeJsonToken`, `nextJsonToken(e, Error)`, `nextJsonAllocToken`, `readJsonString/ Integer/Bool`, `validDigest`, `readJsonDigest`, `readStringArray`, `containsString`, `knownStatus/Kind/Coverage` (parameterize `Error` type; touches passes `InvalidTouchesReport`, claims passes `InvalidClaimsReport`).
- `src/publication_evidence.zig` — `EvidenceInput` (file, two streaming readers, sha256, count), `open/missing_error`, `hashPass/fail_error`, `rewindForParse`, `finish` → `FileBinding`; helper `bindingEqual`.

**Touched:** `src/publication_claims.zig:176-320`, `src/publication_touches.zig:188-340`, `src/publication_proof_pack.zig:103-145`, all call sites `parseScopeAfterBegin:307`, `parseChecksStream:698`, `writeAfterChecks:1077`.

**Steps:**
1. Create new modules with same signatures; delegate remap `publication_touches.zig:1380` `parseChecksStream` catch `InvalidClaimsReport => InvalidChecksReport` preserved at call site, not inside shared helper.
2. Replace bodies with imports; keep wrappers if re-export needed for tests.
3. Prove existing `buildHostileChecksBytes:1387` / `prepareTarget:1534` tests still reject overflow without panic.

**Gate:** `zig build test` (claims + touches + proof-pack tests green), grep confirms no duplicate helper remains.

**Next:** unblocks QM-2/3/4.

---

### Slice 2 — QM-2: publication_claims parsing and report split

**Branch:** `codex/quality-claims-parse-report` → `afterparty` · **Est.:** 1d · **Risk:** low-medium

**Context:** 
- `src/publication_claims.zig:395` `parseCheckAfterBegin` 138 loc (8 `have_*` booleans + inner counts loop).
- `src/publication_claims.zig:535` `parseBindingAfterBegin` 78 loc.
- `src/publication_claims.zig:698` `parseChecksStream` 125 loc.
- `src/publication_claims.zig:1018` `writeReport` 59 loc, `src/publication_claims.zig:1077` `writeAfterChecks` 64 loc vs `src/publication_claims.zig:1141` `renderFromBytes` 45 loc duplication.

**Goal:**
- Extract `parseCountsBlock(reader) -> counts` shared by `parseCheckAfterBegin`.
- Extract `validateCheckState` → `validateCoverage()` + `validateEligibility()` (`src/publication_claims.zig:654`), keeping error `InvalidChecksReport`.
- Extract `writeReport` → `writeHeader()`, `writeClaimsArray(gpa, out, checks)`, `writeLimitationsArray()`. Keep `call_ids`/`limitation_ids` ordering untouched.
- Collapse `writeAfterChecks` / `renderFromBytes` duplication via internal `deriveReport(gpa, target, inventory, checks, checks_binding) ![]u8` used by both (one takes `Io.Dir`, one takes `[]const u8`).

**Touched:** only `src/publication_claims.zig`.

**Verification:** all `writeAfterChecks` fault-injection tests (`test_fail_execution`, `test_fail_write`, stale-binding, invalid-report) green; byte-determinism test `claims report is byte-deterministic` still passes; `zig build test` green.

---

### Slice 3 — QM-3: publication_touches parsing / graph / validation split

**Branch:** `codex/quality-touches-parse-graph` → `afterparty` · **Est.:** 1.5d · **Risk:** medium (graph proof Pack coupling)

**Context:** 
- `src/publication_touches.zig:579` `parseCheckAfterBegin` 145 loc, `src/publication_touches.zig:1189` `parseEvidenceAfterBegin` 138 loc, `src/publication_touches.zig:1094` `parseClaimAfterBegin` 95 loc — same flag-heavy pattern.
- `src/publication_touches.zig:1818` `parseTouchesStreamInner` 208 loc — header + nodes + edges + topology in one fn.
- `src/publication_touches.zig:2816` `buildNodesAndEdges` 145 loc + `expectedNodeIds:2986` + `expectedEdges:3040` + `validateGraph:3120`.

**Goal (no new threads, keep error remaps):**

- `src/touches_parse.zig` — `parseCountsObject()`, `parseArtifactsBindingAfterBegin()` (already partially shared via QM-1, finish parameterizing `fail_error`), `parseChecksStreamInner:1394`, `parseClaimsStream:1578`.
- `src/touches_graph.zig` — `buildNodesAndEdges`, `expectedNodeIds`, `expectedEdges`, `validateGraph`, `edgePermits:2972`, `findingNodeId` helpers.
- Inside `publication_touches.zig`, shrink `parseTouchesStreamInner` to orchestrator: `parseHeaderBindings()` → `parseNodes()` → `parseEdges()` → `validateTopology()`.
- Keep metadata validators (`parseTargetMetadata:2190`, `parseArtifactMetadata:2218`, etc.) as is; only de-duplicate `indexOfString`/`hasDuplicate:724` via shared helper if not already in QM-1.

**Verification:** `buildHostileChecksBytes:4758` boundary test, `expectMetadataMutationRejected:4884`, tamper-rejection sweeps, and `validateGraph` byte-identical fixture (`tests clean fixture derives the canonical verified Touch Atlas`) green. No `InvalidTouchesReport` mapping changed.

**Parallelizable with QM-2 after QM-1.**

---

### Slice 4 — QM-4: publication_proof_pack renderer + transaction split

**Branch:** `codex/quality-proof-pack-render-txn` → `afterparty` · **Est.:** 1.5d · **Risk:** medium (pair transaction is first-slice correctness)

**Context:** `src/publication_proof_pack.zig:1` 3309 loc (prod ~1650, tests ~1400). Prod hot set:
- `writeAfterTouches:295` 129 loc opens 4 evidences, validates 7 bindings, 3 semantic validations, renders 2 outputs.
- `renderJson:500` + `renderSummary:557` 122 + `renderArtifacts:746`/`renderChecks:790`/`renderFindings:852` — 5 helpers but counting inline.
- `renderHtml:1158` + `renderHtmlSummary:1226` 121 + 6 `renderHtml*` + `embedded_css:1050` 106 loc — ~800 loc.
- `installPair:1748` 85 + `rollbackPair:1841` + `verifyTmpBytes:1676`.

**Goal:**

- `src/proof_pack_json.zig` — move `renderJson`, `renderSummary`, `renderArtifacts`, `renderChecks`, `renderFindings`, `renderClaims:905`, `renderLimitations:928`, `renderRelationships:949`, `renderPresentation:989`, helpers `writeStringArray:430`, `writeRelationArray:734`, `stripPrefix:680`, `relatedClaimIdsForArtifact:707`.
- `src/proof_pack_html.zig` — move `renderHtml`, `renderHtmlSummary:1226`, `renderHtmlInputs:1349`, `renderHtmlArtifacts:1384`, `renderHtmlChecks:1432`, `renderHtmlFindings:1487`, `renderHtmlClaims:1527`, `renderHtmlLimitations:1549`, `renderHtmlRelationships:1581`, `embedded_css`, `writeHtmlNumber:1012`/`escapeHtml:1018`.
- `src/proof_pack_transaction.zig` — `writeTmpFile:1652`, `verifyTmpBytes:1676`, `installPair:1748`, `rollbackPair:1841`, `PairState` — keep `.prev` order (`index.html` first preserved, `proof-pack.json` last commit) verbatim.
- Inside `src/publication_proof_pack.zig`, keep thin `writeAfterTouches` orchestrator: `openAndHashFour()` → `validateAllBindings()` → `validateGraph()` → `renderPair()` → `installPair()`; extract `deriveOverallStatus:154` stays pure, `renderHtmlAttentionExplanation:215` moves with html module.

**Verification:** all proof-pack determinism + tamper + staged-transaction fault-injection tests (`JsonTmpWriteFailed`, `PreserveHtmlFailed`, `InstallJsonFailed`, `RestoreHtmlFailed` etc.) green under `std.testing.allocator` and failing-allocator sweeps (`proofPackAllocationCase:3297`). Pair split/absent reporting string unchanged.

**Parallelizable with QM-2/3 after QM-1.**

---

### Slice 5 — QM-5: compile site-multi / PagesInner / cache+heading+stage

**Branch:** `codex/quality-compile-site-multi` → `afterparty` · **Est.:** 2d · **Risk:** medium (HTML default, staging atomicity, incremental cache)

**Context:** `src/compile.zig:1` 10535 loc. Prod hot:
- `compilePagesInner:2349` ~380 loc (biggest CC).
- `compileHtmlSiteMulti:1254` 206 loc.
- `SharedCompileState.init:1084` 102 loc, `buildSiteHeadingIndex:1800` 143 loc, `validatePrepublicationTarget:2213` 135 loc.
- Stage helpers `ensureValidParentDirs:2038`, `publishStageFile:2080`, `publishStageTree:2118`, cache `writeCacheManifest:947`, `collectTransitIncludes:918`.

**Goal (incrementally, one PR may split 5a/5b if needed):**

- `src/compile_stage.zig` — `ensureValidParentDirs`, `publishStageFile` (rename→CrossDevice copy+delete), `publishStageTree` (deferred `artifacts.json` last).
- `src/compile_cache.zig` — `writeCacheManifest`, `expandDirtySet:1945`, `stageRelForDist:1983`, `readPriorSitemapOwnership:1999`, `collectTransitIncludes:918`, `fingerprintHex:1641`.
- `src/compile_heading.zig` — `collectFragmentTargetSet:1653`, `headingHarvestKey:1739`, `writeHeadingHarvestCache:1769`, `buildSiteHeadingIndex:1800`.
- Inside `compile.zig`:
  - Shrink `compilePagesInner:2349` → `preparePageLayouts(layouts_by_path, db)` → `validateVerificationSurfaces()` → `runHeadingHarvestAndAudit()` → `publishPagesAndManifest()`.
  - Shrink `compileHtmlSiteMulti:1254` → `preflightValidateLayouts(plans, db)` + `loadLayoutsForPlans()` + `compileOneTarget(plan, ...)`, aggregate `any_failed/any_io_failed` unchanged.
  - Keep `freezeSiteFromPageDb:171`, `renderPageSlots:735`, `renderAndPublishPage:841` interfaces byte-identical; only internal extraction.

**Invariants to preserve:** `arena.reset(.free_all)` after each page (success or error) documented in header; `layout_arena` long-lived; per-target isolated `dist_dir` + `.boris-stage`; sitemap deferred commit.

**Gate:** `zig build test` (compile + assemble + cache tests), `zig build --build-file editor/build.zig test` untouched, `./scripts/release-gate.sh` pass, manual dual-run `boris --quiet` vs `boris --jobs 4 --quiet` produces identical `dist/` tree (`expectDirTreesEqual:8329` logic).

---

### Slice 6 — QM-6: cli parseOptions decomposition (largest CC)

**Branch:** `codex/quality-cli-parse` → `afterparty` · **Est.:** 2d · **Risk:** high CC, low behavioral risk if table-driven

**Context:** `src/cli.zig:309` `parseOptions` 1623 loc — single while loop over `args` with ~60 `if (std.mem.eql(...))` blocks, interleaved `saw_*` flags, conflict matrix `src/cli.zig:1558` 35 conditions, mode selection `src/cli.zig:1596` 18 conditions, synthetic `default` target injection `src/cli.zig:1648`.

**Goal (no new flags, no new defaults):**

- Table-driven helpers (keep `takeValue:1897`/`takeValueAllowEmpty:1919`):
  ```
  parseCommandPrefix(args, &i, &command)                 // :454-546
  parseGlobalFlags(a, &saw_quiet, &saw_timings)          // :598-609
  parseModeFlags(a, &saw_rag, &saw_context, ...)         // :717-775
  parseTargetSpecs(a, args, &i, &targets, &target_layouts, &target_profiles, &pending_rules) // :836-930
  parseStandardSiteFamily(a, args, &i, &standard_site_command) // :504-542
  parseNostrFamily(a, args, &i)
  validateFlagConflicts(saw_*) -> ParseError!void        // extract :1558 matrix as table
  resolveMode(saw_*) -> Mode                              // :1596-1614
  buildOptionsForMode(mode, saw_*, ...) -> Options        // :1745 switch, keeps synthetic default target logic
  ```

- Keep `Options:83` shape, `ParseError:260` set, `printUsage:1932`/`printStandardSiteUsage:2126` strings byte-identical (only generation moves if refactored to table later — not in this slice).

- Optionally shrink `findBadArg:2260` 117 loc by deriving unknown-flag list from same flag table (follow-up within same PR if cheap, else separate polish).

**Verification:**
- Existing `cli.zig` tests (if any) + `zig build test` green.
- Manual argv matrix: bare CLI → `html` default, `--out` → `ir`, `--rag` → `rag`, `--sitemap` without `--site-url` → `SitemapSiteUrlRequired`, `--target X=dir --target-layout X=path` out-of-order → same `Options.targets` sorted order, duplicate `--target` → `DuplicateFlag`.
- No `printParseError` / `printUsage` wording change.

---

### Slice 7 — QM-7: main dispatch + profile loader dedup

**Branch:** `codex/quality-main-dispatch` → `afterparty` · **Est.:** 1d · **Risk:** low-medium (publish/verify paths sensitive)

**Context:** `src/main.zig:1` 3391 loc.
- `runPipelineTimed:141` 56 loc — linear `if (command==.plan) ... else if (.standard_site) switch ... else if (.nostr_plan) ... else switch(mode)` chain for 15 commands.
- `buildStandardSiteProjection:1299` 137 loc, `loadHtmlVerification:1155` 65 loc, `loadHtmlNostr:1225` 57 loc — three copies of `readFileAlloc`+`currentPathAlloc`+`profileWorkspace`+`parseBytes`.
- `runStandardSitePublish:1641` 123 loc, `runStandardSiteVerify:1533` 97 loc, `runStandardSiteSmoke:1006` etc. — verbose but isolated.

**Goal:**

- `src/main_profile_loader.zig` (or `src/publication_profile_loader.zig`) — single `readProfileRequest(gpa, io, opts) -> PublicationRequest` used by `buildStandardSiteProjection`, `loadHtmlVerification`, `loadHtmlNostr`, `runPublicationPlan:336`, `runNostrPlan:405`. Keeps `reportPublicationPlanConfigError:509` mapping (`OutOfMemory→io_error` else `usage`) central.
- `src/main_dispatch.zig` — table `Command -> fn(io,gpa,opts,recorder)`; keep `mapPathError:107`, `classifyPublishError:524`, `reportPublishError:577`, `SessionProvider:630` wiring unchanged.
- Inside `main.zig`, shrink `runPipelineTimed:141` to `dispatchCommand(opts)`, preserve `timings.Recorder` start/stop/`printTimingsReport:236` contract (report is observational, never changes artifacts/exit code).
- Optional: split `runValidate:2216` (30 loc) already small; keep.

**Gate:** `zig build test` + `./scripts/release-gate.sh` + `standard-site plan` offline fixture still byte-identical (`standard_site.renderPlan` golden).

---

## 3. Per-slice checklist (copy into each PR description, per AGENTS.md)

```markdown
### Slice X — <title>
- [ ] Branch from up-to-date `afterparty` (`git fetch && git checkout afterparty && git pull --ff-only && git checkout -b codex/quality-...`)
- [ ] `git status --short` captured before/after
- [ ] Contracts checked (no change expected; if changed, contract file updated in same PR)
- [ ] `zig build test` before + after (paste tail)
- [ ] `./scripts/release-gate.sh` when HTML/IR touching (or explicit N/A with reason)
- [ ] Determinism proof where relevant (sequential vs `--jobs 4`, or `proof-pack` byte-identical)
- [ ] `docs/SOURCE-MAP.md:1` updated iff new job introduced
- [ ] No generated output committed; unrelated files/worktrees preserved
- [ ] PR targets `afterparty`, not `main`
- [ ] Completion report `docs/COMPLETION-REPORT-TEMPLATE.md:1` pasted
```

## 4. Rollback and sizing rules

- Keep each PR **<250 prod lines moved + <100 new lines** where possible; prefer rename + re-export shim in first commit, then switch call sites in second.
- If a slice’s test delta is >5% flaky, split 5a/5b (e.g., QM-5 stage vs QM-5 heading).
- Any slice that wants a contract change stops, files a separate `docs/contracts/` PR, and does not ride this milestone.
- Milestone ships when every slice PR is merged to `afterparty`; no single big-bang `quality-compiler-split` PR.

## 5. What we deliberately do not do

- No markdown rendering change (Oliver path `src/render.zig` untouched).
- No concurrency redesign (`parallel-rendering.md:1` workers bounded; coordinator sequential).
- No new runtime deps, no micro-test framework, no wasm ABI change.
- No changelog fragments for pure refactors (fragments are for user-visible/contract-visible changes per `docs/changelog.d/README.md:1`). Doc-only `STATUS.md` update only if phase moves.

## 6. Execution for tomorrow

1. Land **QM-0** today (this file, no product code).
2. Tomorrow morning: `git fetch origin && git checkout afterparty && git pull --ff-only` then start **QM-1**. Reviewer: compare each extracted helper’s error set against source — search `InvalidChecksReport`/`InvalidClaimsReport`/`InvalidTouchesReport` remaps.
3. Land QM-1, then open QM-2/3/4 in parallel (one agent per branch, hot-file ownership respected).
4. QM-5 and QM-6 can start in parallel once QM-1 merges; QM-7 last.

---

## Appendix — review pointer for tomorrow’s implementer

Hot file review that drove this plan: `src/publication_claims.zig:1`, `src/compile.zig:1`, `src/publication_touches.zig:1`, `src/cli.zig:1`, `src/publication_proof_pack.zig:1`, `src/main.zig:1` — see inline `LOC / CC` table §0.1. Keep this plan next to `docs/STATUS.md:1` and `docs/contracts/README.md:1` during each slice.
