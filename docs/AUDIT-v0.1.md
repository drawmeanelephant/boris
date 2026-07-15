# Boris v0.1 self-audit report

**Date:** 2026-07-13  
**Milestone:** 10 (final v0.1 hardening)  
**Auditor:** automated implementation pass + local mechanical verification  

This document records **repository facts as verified on the host that ran the
commands below** as of the m10 audit date. It is a **historical snapshot**, not
the living roadmap. For current phase status (including P2/P3 HTML scale-out
that landed after this audit), see [`STATUS.md`](STATUS.md) and
[`CHANGELOG.md`](../CHANGELOG.md).

---

## 1. Repository facts and commands run

| Item | Value |
|------|--------|
| Product version | `0.0.1` (`pipeline.boris_version`) |
| Compiler id | `boris/0.1.1` |
| IR `schemaVersion` | `0.1.0` |
| RAG catalog format | `boris-rag` / `schema_version` `1` |
| Exact Zig version (host) | **0.16.0** |
| Package pin | `build.zig.zon` `minimum_zig_version = "0.16.0"` |
| CI pin | `.github/workflows/ci.yml` `0.16.0` |

### Commands executed successfully (this audit)

```bash
zig version                    # 0.16.0
zig build
zig build test                 # 938 tests across module roots
zig build test-apex-hostile
zig-out/bin/boris --input fixtures/content/valid --out /tmp/boris-ir-m10 --quiet
zig-out/bin/boris --input fixtures/content/valid --rag-dir /tmp/boris-rag-m10 --quiet
zig-out/bin/boris --input content --out /tmp/boris-content-ir --quiet
zig-out/bin/boris --input content --rag-dir /tmp/boris-content-rag --quiet
# Dual IR: manifest.json + graph.json byte-identical across two out dirs
# Dual RAG: full trees byte-identical across two rag-dirs
# Every IR JSON file parses; every catalog.jsonl line parses independently
# Experimental HTML covered by zig build test (compile + hardening)
```

`zig build test-apex-sanitize` remains **opt-in** (documented skip when host
lacks sanitizer runtime). Not required for CI green.

---

## 2. Module map and entry points

| Module | Role |
|--------|------|
| `src/main.zig` | CLI entry |
| `src/cli.zig` | Flag parse / dispatch |
| `src/pipeline.zig` | Shared compile: scan → FM parse → Aside tokenize → PageDb → graph → IR publish |
| `src/scanner.zig` | Deterministic discovery |
| `src/identity.zig` | Paths, entity ids, safe output / RAG paths |
| `src/parser.zig` | Bounded frontmatter + body slice |
| `src/aside.zig` | Aside tokenizer, HTML render, RAG `:::kind` format |
| `src/page.zig` | PageList / PageDb |
| `src/graph.zig` | validate + freeze |
| `src/json_out.zig` | Deterministic JSON helpers |
| `src/rag.zig` | Optional RAG export |
| `src/apex.zig` | Apex C ABI wrapper |
| `src/compile.zig` | Experimental HTML site loop |
| `src/assemble.zig` | Layout split + Atomic publish |
| `src/diag.zig` | Diagnostic codes |
| `src/hardening_test.zig` | m10 integration tests |
| `src/fuzz.zig` | Bounded fuzz (FM, component, Apex, graph) |
| `tools/source-rag/` | Source pack tool (not product RAG) |
| `vendor/apex/` | C engine + hostile double + sanitizer smoke |

**Product entry:** `zig-out/bin/boris`  
**Default modes:** IR (`--out`) or RAG (`--rag` / `--rag-dir`).  
**HTML:** library/tests only (`compile.experimental == true`).

---

## 3. ABI properties (Apex)

| Class | Properties |
|-------|------------|
| **Mechanically enforced (Zig)** | Status checked before outputs; null+nonzero rejected; empty MD uses non-null sentinel; `forbidApexFree` path; arena free no-op; wrapper rejects dirty error outputs |
| **Test-covered** | Unit tests in `apex.zig`; hostile C double (`test-apex-hostile`); fuzz pointer/len contracts; HTML compile uses real engine |
| **Vendor-contract only** | No retained pointers after `apex_render` against *arbitrary* C engines; no libc free of arena memory; synchronous completion; minimal stub ≠ CommonMark |

Normative: `docs/contracts/apex-abi.md`.

---

## 4. Whiteboard ownership / lifetime

| Object | Owner | Lifetime |
|--------|-------|----------|
| PageDb strings (entity_id, title, parent, paths, tags) | Retain arena | Compile/site lifetime |
| Source bytes (HTML path) | Document Whiteboard | One page |
| Frontmatter/body views | Borrow source | Until source free / free_all |
| Aside token slices | Borrow body | Until free_all |
| Apex HTML | Whiteboard | Until free_all after publish |
| Layout prefix/suffix | Layout arena | Site lifetime |
| Writer stack buffer | Stack | `writePage` call only |

**Reset rule:** `free_all` only after Apex return, flush, temp close, publish
attempt, and no retained Whiteboard slices.

---

## 5. Path / symlink policy

- Content-root-relative paths with `/` separators after canonicalize.
- Entity ids: no empty / `.` / `..` segments; validated grammar.
- Output paths built **only** from validated entity ids (`safeOutputRelativePath`,
  `ragPagePath`) — cannot introduce `..` or absolute segments.
- Discovery **rejects** directory and page-file symlinks under content (v0.1).
- Symlink create tests may skip on Windows or permission denial (**platform-qualified**).

---

## 6. Parser bounds

| Bound | Value (from `page.zig`) |
|-------|-------------------------|
| Max source bytes | 1 MiB |
| Max frontmatter bytes | 64 KiB |
| Max frontmatter fields | 32 |
| Max title bytes | 512 |
| Max tag bytes / count | 64 / 32 |
| Aside id | 1…64, `[A-Za-z0-9][A-Za-z0-9_-]*` |
| Aside kinds | `note`, `tip`, `info`, `warning`, `danger` |

Frontmatter: closed keys only; not YAML. Aside: quoted attributes only;
outside fences only; nested Aside rejected. Normative: `frontmatter.md`,
`components.md`.

---

## 7. Graph validation path (shared IR / RAG)

Both modes call `pipeline.compile` → `graph.validate` (then freeze when clean).

Same diagnostic **codes** for invalid graph fixtures (verified in
`hardening_test` + `rag` tests): `EDUPLICATEID`, `EPARENTMISSING`,
`EPARENTSELF`, `EPARENTNOTTRUNK`, `EPARENTCYCLE`.

Component failures: `ECOMPONENT` on the same diagnostic list before success.

Failed validation: IR publishes only `build-report.json`; RAG does not publish
a graph-dependent corpus.

---

## 8. RAG reproducibility findings

| Check | Result |
|-------|--------|
| Dual export distinct dirs, full tree byte-compare | **Pass** (host) |
| Stable sorts (system path, entity id, edges, catalog path) | **Pass** |
| No timestamps / absolute paths / hostnames in artifacts | **Pass** (by construction + tests) |
| `catalog_meta.json` fixed shape | **Pass** |
| Independent JSON parse of each `catalog.jsonl` line | **Pass** |
| Aside → `:::kind` export; no residual `<Aside>` | **Pass** (`content/` + tests) |
| Cross-OS bit-identity | **Not claimed** |

---

## 9. Publication guarantees and non-guarantees

| Surface | Guarantee | Non-guarantee |
|---------|-----------|---------------|
| IR | Staging dir then per-file rename into out; no graph IR on content failure | Whole-tree atomic; cross-volume; concurrent readers |
| RAG | Staging then publish; discard staging on graph failure | Cross-volume atomic; cross-OS bit-identity |
| HTML | Temp via Zig 0.16 Atomic API; same-dir replace; temp cleanup on failure | Universal multi-FS atomicity; default CLI mode |

---

## 10. Test inventory (high level)

| Suite | Root / step |
|-------|-------------|
| CLI + pipeline + diag (via main) | `zig build test` |
| Scanner, parser, graph, page, fixtures | dedicated modules |
| Aside tokenizer + render | `src/aside.zig` |
| RAG export | `src/rag.zig` |
| Apex + assemble + compile | m8/m9 modules |
| Hardening integration | `src/hardening_test.zig` |
| Fuzz | `src/fuzz.zig` |
| Hostile Apex | `zig build test-apex-hostile` |
| Sanitizer smoke | `zig build test-apex-sanitize` (opt-in) |

Approx. **938** unit/integration tests in the default `zig build test` aggregate
on the audit host.

---

## 11. Open risks and deferred work

### Open risks

1. Apex stub markdown fidelity vs CommonMark expectations.
2. Publication atomicity across volumes/OSes not proven beyond Linux+macOS CI unit tests.
3. Process RSS not measured; only Whiteboard `queryCapacity` after `free_all`.
4. Dual frontmatter helper (`frontmatter.zig` vs `parser.zig`) still exists for
   legacy harness-style callers — product path uses `parser.zig`.

### Intentionally deferred (as of m10 audit — historical)

At audit time these were deferred. **Several landed later on the opt-in HTML
path** (P2 fingerprints/incremental; P3.1 `--jobs`; P3.2 `--watch`; P3.3
multi-target). Do not treat this list as current truth — see `STATUS.md`.

Still accurate non-goals / residual gaps after post-P3 work:

- Default CLI HTML `dist/` product mode (bare `boris` remains IR-first)
- CommonMark-complete Apex (stub remains minimal)
- `:::` authoring (export-only today)
- Nested asides / multi-component registry / MDX
- mmap
- Full YAML frontmatter

---

## 12. Terminology

One system: **Aside**, admonition, component. **Broside** is unregistered and
hard-errors. Load / Roll / Ignite / Reset are teaching names only (not CLI/IR
field names).
