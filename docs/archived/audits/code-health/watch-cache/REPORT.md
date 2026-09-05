# Code-health audit report — watch, cache, and parallel jobs (timings)

**Card:** [#815](https://github.com/drawmeanelephant/boris/issues/815) (milestone
[Code health pass](https://github.com/drawmeanelephant/boris/issues?q=label%3Areview-sweep), epic
[#807](https://github.com/drawmeanelephant/boris/issues/807))
**Authority:** review only — no product-code changes on this card. Findings
filed individually: [#876], [#877].
**Commit audited:** `main` @ `d60956b9` (branch `audit/815-watch-cache`).
**Zig:** 0.16.0, macOS arm64 (darwin 27).
**Gate:** `zig build test` green before probes (exit 0, incl. the #392 serve +
watch-json suites); no product code touched, so no re-run drift.

## Setup

- Branch `audit/815-watch-cache` at `main` tip `d60956b9` (== `origin/main`);
  `git status --short` clean; `zig build test` exit 0 before any probe.
- Black-box binary: `zig-out/bin/boris` (0.8.2) against a scaffolded site
  (trunk `index.md` wiki-linking `guides/intro.md`, an `{{include}}` consumer,
  `content/includes/sidebar.md`) under `/var/folders/…/T/opencode/p815/`.
- Contracts read first (normative): `docs/contracts/watch-mode.md`,
  `docs/contracts/parallel-rendering.md`. Locus files read in full:
  `src/cache.zig` (527), `src/watch.zig` (1836), `src/timings.zig` (269).
  Supporting walks: `src/watch_json.zig`, `src/preview_server.zig`,
  `src/publication_evidence_state.zig`, `src/compile_cache.zig`, and the
  incremental/fingerprint/parallel sections of `src/compile.zig`.

## Contract drift check (both directions)

- **Contract → code:** `watch-mode.md` §1–§8 and `parallel-rendering.md` all
  have direct code counterparts: debounce 100 ms / idle 500 ms
  (`watch.zig:16-21`), normalization & prefix-boundary stripping
  (`watch.zig:296-381, 487-499`), exclusion sets incl. sibling staging trees
  (`watch.zig:387-396`, tests `isIgnored helper`,
  `processEvents does not ignore legitimate .boris-stage source paths`), no
  concurrent builds (single-threaded coordinator loop, `watch.zig:1136-1165`),
  async-signal-safe shutdown latch (`watch.zig:502-507`), recoverable vs
  unrecoverable classification (`watch.zig:517-519` +
  `compile.isContentCompileFailure`, test
  `isRecoverableBuildError classification stays content-only`), NDJSON §8
  byte shapes (`watch_json.zig` — every renderer has a byte-exact golden test).
  Parallel path: fingerprinting/affected-set single-threaded before workers
  (`compile.zig:2764-2849`), immutable inputs after spawn, coordinator-only
  logging in plan order (`compile.zig:2929-2939`), manifest written after join
  in entity order (`compile.zig:3000-3063`), `--jobs` range/usage gating in
  `cli.zig`. All conform.
- **Code → contract (drift found):**
  1. `PollingWatcher.poll` transient-error handling contradicts its own
     stated policy ("keep the previous snapshot") — **Confirmed defect → #876**.
  2. The debounce loop adds a 2000 ms hard burst cap (`max_debounce_burst_ms`,
     `watch.zig:18`, loop at `watch.zig:1148-1158`, cited #17) that
     `watch-mode.md` §3 does not mention. Conservative behavior beyond the
     contract, deterministic, unit-tested indirectly. **Documented limitation**
     (contract could name the cap; no action required on this card).
  3. `timings.zig` itself is conformant (pure observation, monotonic
     `.awake` clock, canonical enum order, only-started phases; tests
     `renderJson reports only started phases in canonical order`,
     `stopAll closes phases left active by an error path`), and the parallel
     path records strictly on the coordinator thread (render wrap
     `compile.zig:2868/2988`, `page_reads` after join `compile.zig:2987-2995`,
     `hash_bytes`/`fast_path_hits` in the sequential fingerprint pass
     `compile.zig:2793-2839`; workers never touch the Recorder). But
     `watch --timings` never threads the recorder into the watch compile path —
     **Likely defect → #877**.

## Falsification table

| # | Probe | Commands (abridged) | Result | Classification | Evidence |
|---|-------|---------------------|--------|----------------|----------|
| B1 | Unchanged incremental rebuild (baseline reuse) | `boris --html-dir dist --html-layout layouts/main.html --incremental --quiet --timings` (twice, no edits) | exit 0; second run: `render` 103 µs, `checks/claims/touches/proof_pack` 41–83 ns (evidence-reuse stubs), `fast_path_hits: 7` | Non-issue (contract-conformant: reuse, not re-derivation) | `publication_evidence_state.reuseValid` (`compile.zig:2436-2450`); timings report pasted below |
| B2 | Stale-reuse rejection: foreign manifest `format_version` | `sed -i 's/boris-cache-v3-nav-digest/boris-cache-v2-foreign/' dist/.boris-cache/manifest.json`, rebuild | both pages re-rendered (`fast_path_hits` 7→5, `page_reads` 4→6) and manifest rewritten with canonical `boris-cache-v3-nav-digest` | Non-issue (conformant rejection) | `compile.zig:2404-2408` (pre-P3.3/foreign manifest deinit'd, cold rebuild); `compile_incremental_test.zig:287` |
| B3 | Stale-reuse rejection: compiler identity on the evidence chain (#728 area) | `sed -i 's/boris\/0.8.2/boris\/0.9.9/' dist/.boris-cache/evidence-state/default.json`, rebuild | full evidence re-derivation (`checks` 2.7 ms, `claims` 0.9 ms, `touches` 1.4 ms, `proof_pack` 2.5 ms — vs 41–83 ns reuse stubs); state file rewritten with `"compiler_id":"boris/0.8.2"` | Non-issue (conformant) | `publication_evidence_state.zig:8-10, 77-101` (compiler_id required + mismatch → null → full chain); black-box twin of `compile_incremental_test.zig:754-764` |
| B4 | Cache discriminator gap: page-cache manifest has no compiler identity | read manifest + `cache.zig` | manifest records only `format_version`; fingerprint inputs (`cache.zig:132-210`) exclude compiler id. A compiler upgrade that changes rendering without changing fingerprint inputs would silently reuse pages. Mitigated today by the evidence-chain pin (B3) and the documented bump policy | **Documented limitation** (policy comment `cache.zig:6-11`: bump only when fingerprint inputs or discriminator semantics change; contract-free zone) | manifest excerpt below; cross-ref #728 |
| B5 | Invalidation: include edit → consumer re-render | `sed 's/Sidebar v2/v3/' content/includes/sidebar.md`, `--incremental` rebuild | consumer `guides/intro.html` re-published (`Sidebar v3` in output bytes) | Non-issue (conformant) | `expandDirtySet` reverse walk (`compile_cache.zig:121-156`), unit test `Affected pages query scenarios` (include→page arm) |
| B6 | Invalidation: wiki-target **title rename** → referrer re-render (the #811 assumption this cache relies on) | `sed 's/title: Intro/title: Intro Renamed/' content/guides/intro.md`, `--incremental --timings` | referrer `index.html` re-rendered: `render` 2.7 ms, `fast_path_hits` 7→5, referrer fingerprint changed `fcef75…da` → `ded570…75`, link label updated to "Intro Renamed" | Non-issue (conformant) | fingerprint reference-material input (`includes-and-wiki-links.md:117-125`, `wikilink.referenceMaterialMultiWithMap`), `compile.zig:2644` |
| B7 | Invalidation boundary: wiki-target **body** edit must NOT dirty the referrer | `sed 's/Intro body v3/v4/' content/guides/intro.md` (body only), `--incremental` | referrer untouched: fingerprint identical, bytes identical, `fast_path_hits` 7 — correct, because reference material is id/path/title only, and the referrer's bytes cannot contain the target body (wiki-link label comes from the target title) | Non-issue (contract-conformant boundary) | `includes-and-wiki-links.md:121-125`; unit test `Source change changes only that page's key` |
| B8 | `watch --serve` lifecycle: start → serve → edit → reload → SIGTERM → port release | `boris watch --serve --port 8157 --html-dir dist …` &; `curl /`, `curl /__boris/`, SSE client; edit; `kill -TERM` | initial build; `preview: http://127.0.0.1:8157/` banner; edit produced rebuild + SSE `reload` generation 0→1→2; served page carried the new body (`Intro body v6`); SIGTERM → `watch: received shutdown signal, cleaning resources...`, port refused afterward (`connection refused as expected`) | Non-issue (conformant) | `watch-mode.md` §6 shutdown; `preview_server.zig` generation/SSE design; live test `preview server serves files and pushes reload events`; output below |
| B9 | `--serve` port handling: bind conflict + usage gates | hold 8157 in a listener, run `watch --serve --port 8157` (foreground, timeout); `validate --watch --serve`; `--watch-json` without watch | bind conflict: `error: I/O or system failure: AddressInUse`, **exit 3** (fail-fast at init, before any build); `validate --watch --serve` → exit 2; `--watch-json` without watch → exit 2 | Non-issue (conformant) | bind-at-init `watch.zig:637-649` + `preview_server.zig:59-78`; usage gates `cli.zig:1851-1852, 1874, 1878` + tests `parse: watch --serve and --port`, `parse: --watch-json (watch only)` |
| B10 | `--watch-json` NDJSON: full cycle incl. recoverable failure + recovery, stream purity | `boris watch --watch-json --html-dir dist …` &; real edit; add `broken.md` with unknown frontmatter key; remove it; SIGTERM | stream (below) is exclusively NDJSON on stderr (stdout 0 bytes); `hello` handshake schema 1 + `boris/0.8.2`; initial/rebuild `build-started/succeeded` with `phase/mode/targets/changed/pages_written/duration_ms`; `build-failed` with `errors:1`, diagnostic object byte-shaped per §8 (`EFRONTMATTER`, null `id`), `recoverable:true`; recovery `build-succeeded` in the same session; `watcher-started`, `watch-stopped reason:"signal"` | Non-issue (field-for-field §8 match) | full stream pasted below; golden tests in `watch_json.zig` |
| B11 | Transient root scan failure under watch | `chmod 000 content; sleep 3; chmod 755 content` during a live watch | author changed nothing, yet all three content files surfaced as changed; rebuild fired; `error: rebuild failed with unrecoverable I/O error: AccessDenied` → watcher **exited** | **Confirmed defect → #876** | output below; `watch.zig:177-188, 209-217, 224-225` |
| B12 | `watch --timings` report | `boris watch --timings --html-dir dist …` &; one real edit; SIGTERM | report printed with **zero phases and zero counters** while the daemon demonstrably rebuilt pages | **Likely defect → #877** | empty report pasted below; recorder dropped in `main.zig:2762-2780`, never set in `watch.zig:742-820` |
| W1 | `serve-started` under `--watch-json` (§8: only port discovery, even under quiet) | `boris watch --watch-json --serve --port 0 …` &; SIGTERM | `{"event":"serve-started","url":"http://127.0.0.1:53074/","helper":"http://127.0.0.1:53074/__boris/","port":53074}` — ephemeral port 0 resolves to the actual bound port | Non-issue (conformant) | `watch.zig:1126-1134`, `watch_json.renderServeStarted`, golden test `serve-started carries bound port url and helper` |
| W2 | `validate --watch` zero-write daemon | (unit-level; not re-run black-box on this card) | zero-write across valid/fail/fix cycles, no output roots to ignore | Non-issue | test `validate --watch cycles run the zero-write preflight and write nothing (#647)`; usage gates in B9 |

## Key probe output (pasted)

**B1 — unchanged rebuild (`--timings`, second run):**

```json
"counters": {
  "page_reads": 4, "include_reads": 0, "hash_bytes": 665,
  "link_resolutions": 5, "fast_path_hits": 7
},
"totalNs": 29777333
```

`checks` 83 / `claims` 41 / `touches` 42 / `proof_pack` 42 (ns — evidence-reuse stubs), `render` 103166 ns.

**B4 — manifest head (no compiler identity field):**

```json
{
  "format_version": "boris-cache-v3-nav-digest",
  "entries": [
    {
      "entity_id": "guides/intro",
      "fingerprint": "7b79fbbf48913e181c4f57aaecd59e6b17e438e603ecf3f6b197cf0b3b14beeb",
      "output_path": "guides/intro.html",
      "selected_layout": "layouts/main.html",
      "output_size": 352,
      "output_digest": "fb5541a28f56fde862fb73102c96683fe322cb6519aeda48db3b1f7a8663bac6"
    },
```

Evidence state (B3) does pin identity: `{"format":"boris-evidence-state-v1","compiler_id":"boris/0.8.2","target":"default",…}`.

**B10 — full `--watch-json` stream (stderr, unedited; stdout 0 bytes):**

```text
{"event":"hello","watch_events_schema":1,"compiler":"boris/0.8.2"}
{"event":"build-started","phase":"initial","mode":"html","targets":["default"]}
{"event":"build-succeeded","phase":"initial","mode":"html","targets":["default"],"pages_written":2,"duration_ms":35}
{"event":"watcher-started","mode":"html","targets":["default"]}
{"event":"build-started","phase":"rebuild","mode":"html","targets":["default"],"changed":["guides/intro.md"]}
{"event":"build-succeeded","phase":"rebuild","mode":"html","targets":["default"],"changed":["guides/intro.md"],"pages_written":2,"duration_ms":56}
{"event":"build-started","phase":"rebuild","mode":"html","targets":["default"],"changed":["broken.md"]}
{"event":"build-failed","phase":"rebuild","mode":"html","targets":["default"],"changed":["broken.md"],"errors":1,"diagnostics":[{"severity":"error","code":"EFRONTMATTER","message":"unsupported frontmatter key","remediation":"Fix the frontmatter or encoding for this file","sourcePath":"broken.md","line":3,"column":1,"id":null}],"recoverable":true,"duration_ms":5}
{"event":"build-started","phase":"rebuild","mode":"html","targets":["default"],"changed":["broken.md"]}
{"event":"build-succeeded","phase":"rebuild","mode":"html","targets":["default"],"changed":["broken.md"],"pages_written":0,"duration_ms":34}
{"event":"watch-stopped","reason":"signal"}
```

**B11 — transient permission flip (watch stderr, unedited):**

```text
watch: changed paths detected:
  - guides/intro.md
  - includes/sidebar.md
  - index.md
watch: triggering incremental rebuild...
error: rebuild failed with unrecoverable I/O error: AccessDenied
error: I/O or system failure: AccessDenied
```

**B12 — `watch --timings` report at shutdown (complete stdout):**

```json
{
  "format": "boris-timings",
  "schemaVersion": "1",
  "mode": "html",
  "phases": {

  },
  "counters": {
    "page_reads": 0,
    "include_reads": 0,
    "hash_bytes": 0,
    "link_resolutions": 0,
    "fast_path_hits": 0
  },
  "totalNs": 5234167042
}
```

## Findings

- [#876] — **Confirmed defect**, medium. `PollingWatcher` transient root scan
  failure swaps in a partial snapshot → mass delete events → spurious rebuild
  storm; when the tree is unreadable during the storm the watcher exits
  (contract §5 exit is for *unrecoverable* I/O; the trigger here is transient,
  and the module's own comment promises snapshot preservation). B11.
- [#877] — **Likely defect**, low. `watch --timings` prints an all-zero
  `boris-timings` report: the recorder never reaches
  `WatchCoordinator.runCompile`. B12.

No other Confirmed/Likely findings.

## Non-issue / documented-limitation observations (for the record)

- **B4:** page-cache manifests pin `format_version` only, not compiler
  identity — deliberate per the `CACHE_FORMAT_VERSION` policy comment
  (`cache.zig:6-11`); rendering changes must bump it. The evidence chain
  (B3) independently pins `compiler_id` (#728). Cross-ref #728.
- **Burst cap drift:** the 2000 ms coalescing cap (`watch.zig:18, 1148-1158`)
  is beyond `watch-mode.md` §3 (which names only the 100 ms window and 500 ms
  idle poll). Deterministic, conservative, cited #17. Documented limitation;
  a one-line contract addition would close the drift.
- **`FakeWatcher.poll` leaks already-duped events if an append fails
  mid-burst** (`watch.zig:99-111`, no errdefer). Test-only backend, GPA
  failure path; Non-issue.
- **Coalescing-tail poll errors are swallowed** (`watch.zig:1156`
  `catch break`): a burst rebuild may run on the partial set, but the next
  poll observes the remainder as a follow-up rebuild — matching §4's
  "observed on the next poll" serialization. Non-issue.
- **Worker/recorder isolation:** parallel workers never record timings and
  never log; stdout/stderr progress is coordinator-only in plan order
  (`compile.zig:2929-2939`). Conformant with `parallel-rendering.md`
  determinism section.
- **`--watch-json` implies quiet for the compile path** and the event stream
  is emitted regardless (`watch.zig:776-778, 989-991`); B10 stream purity
  (0 stdout bytes) confirms.

## Probes and evidence summary

- Probes run: **14** (13 black-box: B1–B12 plus W1; W2 is unit-cited; falsifying
  probes include 2 tamper-rejections, 3 invalidation-direction probes, 4
  lifecycle/usage probes, 1 failure-recovery cycle, 1 defect reproduction).
- All commands and full outputs above and in the session transcript; per-row
  file:line + test-name citations in the table.
- Cross-ref: the cache's invalidation assumes #811's dependency-index
  correctness; #811's W1/B5 finding (#854, untyped string key space in
  `DependencyIndex`/`NodeLookup`) is the known shared fragility and is **not**
  re-filed here. The affected-set walk (`cache.zig:228-340`) inherits #854's
  precondition, not a new defect.
