# Code-health audit report — embedding, Wasm ABI, worker host, and job runner

**Card:** #819 (milestone [Code health pass](https://github.com/drawmeanelephant/boris/milestone/2), epic #807, second tranche)
**Authority:** review only — no product-code changes on this card. Findings
filed individually: #908 (Confirmed, high), #909 (Confirmed, medium-low),
#910 (Likely, low), #911 (Confirmed doc-gap, low).
**Commit audited:** `main` @ `cbc9fa9f` (branch `audit/819-embedding-wasm`)
**Zig:** 0.16.0 (homebrew), macOS arm64 (darwin)
**Gate:** `zig build test` exit 0 before probes and after (exit 0).

## Setup

- Fresh worktree of `origin/main` tip `cbc9fa9f`; `git status --short` clean
  except the report file; `zig build test` → exit 0 baseline.
- Contracts read first (normative): `docs/contracts/embedding.md` (M0–M7),
  `docs/contracts/cloudflare-container-runner.md` (v1 `boris-job-1`).
- Locus files read in full: `src/render_wasm.zig`, `src/wasm_image.zig`,
  `src/embed.zig`, `src/embed_evidence.zig`, `src/embed_wasm.zig`,
  `src/job_runner.zig`; host glue `hosts/cloudflare-worker/src/{worker,handler,abi,wasi,paths,limits,r2}.mjs`
  and `test.mjs`; supporting `src/compile.zig` (`compileHtmlToSink`,
  layout-load paths), `src/source_provider.zig`,
  `src/publication_evidence_state.zig` (#728 identity pinning),
  `examples/cloudflare-container/Dockerfile`. Drift checked both directions.
- Black-box helpers built from the same worktree: `zig build` →
  `boris-embed{,-small}.wasm`, `boris-render{,-small}.wasm`,
  `boris-job-runner`, `boris`.

## Falsification table

| # | Probe | Commands (abridged) | Result | Classification | Evidence |
|---|-------|---------------------|--------|----------------|----------|
| P1 | Embed ABI surface vs `embedding.md` M5 | `WebAssembly.Module.exports/imports` over both built modules | 14 exports each: `memory` + exactly the 13 M5 symbols; missing vs contract list: NONE; imports are only the 27 `wasi_snapshot_preview1` stubs | Non-issue (surface matches) | `src/embed_wasm.zig:61-218` vs `embedding.md:141-152` |
| P2 | M0 import rule: render module must have no imports | same API over `boris-render{,-small}.wasm` | `imports(0)`; exports exactly `boris_alloc/free/render/result_{ptr,len,free}` + `memory` | Non-issue | `src/render_wasm.zig:20-60` vs `embedding.md:29-47` |
| P3 | Breaking-shape probes on the embed ABI | instantiate `boris-embed-small.wasm` with trap stubs; `boris_compile` with invalid JSON; with `{"path":"a.md","ptr":0,"len":5}`; valid IR-only compile; html+layout compile | invalid JSON → `handle=0 last_status=-2`; null file ptr → `handle=0 last_status=-3`; valid IR → `handle=1 status=0 ok=true artifacts=4`; html with layout → `handle=1 ok=true artifacts=5` — all per the M5 status table | Non-issue | `src/embed_wasm.zig:91-131` vs `embedding.md:166-178` |
| P4 | Missing layout in bundle (`html:true`) | same probe, no `layouts/main.html` file | `handle=0 last_status=-4`, no diagnostics; native path produces `ELAYOUT` diagnostic instead (`compile.zig:983-995`) | **Confirmed defect → #909** | `src/compile.zig:467`, `src/embed.zig:83-87`, `src/embed_wasm.zig:126-131` |
| P5 | Evidence determinism through the Wasm ABI | two `boris_compile(evidence:true)` runs of the same bundle; sha256 each artifact + manifest | manifest sha256 `8733d757…` identical both runs; all 10 artifacts byte-identical incl. the 4 `_boris/proof/*` files; `wasi stub calls: 0` | Non-issue (deterministic) | `src/embed_evidence.zig:61-115`; in-tree assertion `src/embed.zig:351-356`; `zig build test-embed --summary all` → 829/829 pass |
| P6 | Identity pinning (#728 relationship) | `boris_version` read over the ABI; checks/claims statuses | `boris/0.8.2;ir=0.2.0;profile=embed-ir+html+evidence`; checks `artifact-integrity=passed, rendered-html=passed, rendered-search=not-applicable`; claims `…match-inventory=verified`, `rendered-search…=not-verified` — honest limitation as contracted | Non-issue (#728's compiler_id reuse pin is the *native incremental* mechanism, `src/publication_evidence_state.zig:8-11`; embed has no incremental state, identity pinned at the ABI/manifest level) | `src/embed_wasm.zig:20,238-241`; `embedding.md:195-208` |
| P7 | Module size gates | `ls` + `gzip -9` on built modules | ReleaseSafe 7 359 KiB (< 16 MiB), ReleaseSmall 934 KiB (< 8 MiB), gzip 332.9 KiB (< 3 MiB Workers Free) | Non-issue | `embedding.md:244-255`; snapshot parity with `embedding.md:250-252` |
| P8 | Worker-host glue discipline | read-only sweep + `bash hosts/cloudflare-worker/copy-wasm.sh && node hosts/cloudflare-worker/test.mjs` | smoke passes: `valid: 9 artifacts, 15 ms, r2=9`; `poisoned: status=1 diagnostics=1 r2=none` (no upload on failure, `handler.mjs:148,126-130` FALSE_CLAIM guard); host owns only transport/limits/persistence — no Markdown/graph/validation/render code; bounds quoted: `handler.mjs:1` ("No Markdown parsing. Host glue only"), `embedding.md:264-270` | Non-issue | `hosts/cloudflare-worker/src/*.mjs`; limits exactly the M7 table (`limits.mjs:4-23` vs `embedding.md:287-298`) |
| P9 | Worker path canonicalization vs `identity.canonicalize` | read-only: `paths.mjs` vs `src/identity.zig` | rejects absolute, drive, `.`, `..`, empty/`.` segments, control chars, trailing sep, duplicates after `./` folding; sorts output | Non-issue | `hosts/cloudflare-worker/src/paths.mjs:16-75`; `embedding.md:275-277` |
| P10 | Job-runner `boris-job-1` result shape | black-box `--once` runs; fixed key order check | key order exactly `schemaVersion, format, ok, status, runnerClass, exitCode, compilerId, borisVersion, runnerId, imageDigest, jobId, command, diagnostics, artifacts, limits, timings, workspaceRemoved, retried`; two runs equal modulo `timings` (parity-excluded); `jobId` = 16-hex SHA-256 prefix; `retried: false`; workspace removed | Non-issue | `src/job_runner.zig:601-706,198-203` vs `cloudflare-container-runner.md:92-128` |
| P11 | Job-runner lifecycle (happy path) | `boris-job-runner --once --archive selfcontained.tar … --result-json ok1.json` | `exit=0`; `runnerClass: ok`, `ok: true`, `exitCode: 0`, 9 artifacts with sha256; `test-output/job-probe/<jobId>/` deleted (workspace removed) | Non-issue | `src/job_runner.zig:449-599`; full output below |
| P12 | Hostile-archive probes | pax-default bsdtar archive; traversal member `content/../escape.md` (in-tree test) | pax-only → `runnerClass: archive` (contract-required rejection, `cloudflare-container-runner.md:57-58,155`); traversal → `archive`, `exitCode: null`, boris never exec'd | Non-issue (rejections correct) | `src/job_runner.zig:479-487,1363-1393` |
| P13 | Standard directory members in archive | `tar --format ustar -cf withdirs.tar content` (bsdtar writes `content/` with trailing slash) | `exit=2`; `runnerClass: archive`, `exitCode: null`, 0 diagnostics, boris never exec'd — identical payload without directory members succeeds (P11) | **Confirmed defect → #908** | `src/job_runner.zig:177-186`; in-tree gap: `packContentTree` (:781-818) emits file members only |
| P14 | Job-runner HTTP classes and env assumptions | read-only + Dockerfile | `httpStatus` map matches the contract table (200/400/413/504/401/500); `BORIS_JOB_TOKEN`/`BORIS_IMAGE_DIGEST` in contract; `BORIS_BIN`/`BORIS_WORK_ROOT` **absent from contract** | **Confirmed doc-gap → #911** | `src/job_runner.zig:918-932,934-943`; `cloudflare-container-runner.md:60-64,113,196,134-148` |
| P15 | Top-level `theme/`/`layouts/` visibility in the job archive | read-only + black-box cwd probe | contract claims archive-root `theme/`, `layouts/` are "visible to the compiler when the allowlisted flags name them" — the fixed argv names no such flag; a valid `content/` bundle fails `ELAYOUT` when run from a cwd without `themes/boris/` | **Likely defect → #910** | `cloudflare-container-runner.md:60-64` vs `src/job_runner.zig:497-520`; `examples/cloudflare-container/Dockerfile:5-9,18` |

## Black-box probe output (pasted)

### P5 — evidence determinism (two `boris_compile(evidence:true)` runs)

```
run1 manifest sha256: 8733d757938e3bd6fc6928f6a3e17db9c6814a70ce1cf7967d9aefba0868b03d
run2 manifest sha256: 8733d757938e3bd6fc6928f6a3e17db9c6814a70ce1cf7967d9aefba0868b03d
manifest identical: true
manifest.json: IDENTICAL
graph.json: IDENTICAL
completion.json: IDENTICAL
build-report.json: IDENTICAL
index.html: IDENTICAL
index.assets/logo.svg: IDENTICAL
_boris/proof/artifacts.json: IDENTICAL
_boris/proof/checks.json: IDENTICAL
_boris/proof/claims.json: IDENTICAL
_boris/proof/touches.json: IDENTICAL
evidence files: _boris/proof/artifacts.json, _boris/proof/checks.json, _boris/proof/claims.json, _boris/proof/touches.json
wasi stub calls: 0
```

### P6 — identity + honest claims

```
boris_version: boris/0.8.2;ir=0.2.0;profile=embed-ir+html+evidence
profile: embed-ir+html+evidence
check: artifact-integrity = passed
check: rendered-html = passed
check: rendered-search = not-applicable
claim: committed-artifacts-match-inventory = verified
claim: rendered-html-passed-declared-audit = verified
claim: rendered-search-matches-selected-html = not-verified
```

### P8 — worker host smoke

```
copied …/zig-out/bin/boris-embed-small.wasm -> hosts/cloudflare-worker/src/boris-embed-small.wasm
valid: 9 artifacts, 15 ms, r2=9
hashed: 9 artifacts with sha256
poisoned: status=1 diagnostics=1 r2=none
hosts/cloudflare-worker local smoke passed   (exit 0)
```

### P11 — job-runner happy path

```
$ zig-out/bin/boris-job-runner --once --archive selfcontained.tar \
    --boris zig-out/bin/boris --work-root test-output/job-probe \
    --result-json ok1.json
exit_nodirs=0
no-dir-members -> runnerClass: ok | ok: True | exitCode: 0 | artifacts: 9
```
`result.json` key order and two-run equality (modulo `timings`) verified
programmatically; `workspaceRemoved: true`, `retried: false`,
`runnerId: boris-job-runner/0.8.2`.

### P13 — the #908 repro

```
$ tar --format ustar -cf withdirs.tar content        # bsdtar: dir member "content/"
$ zig-out/bin/boris-job-runner --once --archive withdirs.tar … ; echo $?
exit_dirs=2
with-dir-members -> runnerClass: archive | ok: False | exitCode: None | artifacts: 0
```

## Observations classified once

- **Confirmed defect** — directory-member archives rejected (#908); missing
  layout → ABI `-4` with diagnostics dropped (#909); `BORIS_BIN`/
  `BORIS_WORK_ROOT` env assumptions missing from the contract (#911).
- **Likely defect** — contract's top-level `theme/`/`layouts/` visibility
  claim not implementable by the fixed argv (#910).
- **Non-issue** — embed ABI surface, M0 import rule, breaking-shape status
  codes, evidence determinism + honest claims, module size gates, worker
  glue discipline + canonicalization + limits, `boris-job-1` result shape,
  happy-path lifecycle, pax/traversal rejections.
- **Documented limitation** — default theme resolves against process cwd;
  the official image ships it (`examples/cloudflare-container/Dockerfile:5-9,18`),
  and #910's remediation option (b) would codify it in the contract.
- **Insufficient evidence** — none outstanding after P1–P14.

## Findings rule

Four material findings, each filed as its own issue with severity, class,
locus, repro, impact, smallest remediation, and verification: #908, #909,
#910, #911. All linked to #819.
