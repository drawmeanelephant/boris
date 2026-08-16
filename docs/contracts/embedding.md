# Embedding: freestanding compiler host seam

**Status:** normative for the M0 render spike, M3 `compileBundle`, M6 evidence, and M7 host example  
**Issue:** [#301](https://github.com/drawmeanelephant/boris/issues/301)  
**Related:** [oliver-renderer.md](oliver-renderer.md), [source-provider.md](source-provider.md), [artifact-sink.md](artifact-sink.md), [diagnostics.md](diagnostics.md), [json-ir-and-manifest.md](json-ir-and-manifest.md), [publication-artifacts.md](publication-artifacts.md)

This contract is **not** a publication target. Wasm is an embedding
profile of the same compiler. It does not add a `publication.target`
name.

---

## M0 — Oliver render, `wasm32-freestanding`

`src/render.zig` plus the pinned `oliver` module compile for
`wasm32-freestanding` / `abi = none`. A thin export wrapper
(`src/render_wasm.zig`) exposes one render operation. Native CLI
behavior is unchanged.

### Build steps

| Step | What |
|---|---|
| `zig build check-render-freestanding` | Compile-only object, same shape as the ATProto freestanding gates |
| `zig build` | Installs `zig-out/bin/boris-render.wasm` (ReleaseSafe) and `boris-render-small.wasm` (ReleaseSmall) |
| `zig build test-render-wasm` | Import scan, size bound, native-vs-Wasm HTML golden |
| `zig build test-render` | Existing render goldens **plus** the wasm gate |

### Export ABI (spike only)

This is not the product `compileBundle` ABI (M5). Pointers are offsets
into exported linear memory.

| Export | Meaning |
|---|---|
| `boris_alloc(len) -> ptr` | Host-owned input buffer; `0` on OOM |
| `boris_free(ptr, len)` | Free a `boris_alloc` buffer |
| `boris_render(in_ptr, in_len) -> status` | `0` success; negative is a `RenderError` |
| `boris_result_ptr() -> ptr` | HTML from the last successful render |
| `boris_result_len() -> len` | HTML byte length |
| `boris_result_free()` | Drop the last result |

`boris_render` status: `-1` OutOfMemory, `-2` InputTooLarge,
`-3` WriteFailed, `-4` NoSpaceLeft, `-5` RawHtmlNotXmlWellFormed,
`-6` null input pointer with nonzero length.

Panic traps. It is not a successful empty render.

### Import rule

The instantiable module must have **no imports**. No `wasi_*`, `fd_*`,
clock, env, or thread symbols. The test parses the import section and
fails closed if any import is present.

### Golden

`# Alpha\n` through `render.render` (native) and through the wasm
module must both equal `<h1 id="alpha">Alpha</h1>\n` — the same pin
`src/compile.zig` already uses.

The invoke host for the golden is `scripts/render-wasm-invoke.mjs`.
That script is test-host glue, not product compiler code. Cloudflare
Worker invoke remains M7.

### Measured module size (2026-08-16, Zig 0.16.0, Oliver pin in `build.zig.zon`)

| Artifact | Uncompressed | gzip -9 |
|---|---:|---:|
| `boris-render.wasm` (ReleaseSafe) | 1 425.7 KiB | 466.0 KiB |
| `boris-render-small.wasm` (ReleaseSmall) | 209.3 KiB | 78.2 KiB |

Workers Free allows 3 MiB gzip; Paid allows 10 MiB. Isolate memory is
128 MiB. The render-only module fits. These numbers are a snapshot, not
a promise that a later full `compileBundle` module will.

The automated gate requires ReleaseSmall &lt; 2 MiB and ReleaseSafe &lt;
4 MiB uncompressed so a sudden size regression fails CI.

---

## M3 — `compileBundle` (native, IR only)

`src/embed.zig` is the product function the Wasm ABI will later export.
It is files-in, diagnostics-and-IR-out. It is **not** a
`publication.target`.

```zig
pub fn compileBundle(
    io: Io,
    gpa: std.mem.Allocator,
    files: []const SourceFile,
    config: CompileConfig,
) !Compilation;
```

`io` is required by the shared pipeline type. The memory source provider
and memory artifact sink do not scan a host directory or write an output
tree. `CompileConfig` is closed: first cut is Markdown IR only
(`input_format`).

`Compilation` carries:

- structured diagnostics with the existing
  [diagnostics.md](diagnostics.md) fields
- the IR artifact set (`manifest.json`, `graph.json`, `completion.json`,
  `build-report.json`) when validation succeeds
- `build-report.json` only when validation fails — no graph-dependent IR,
  same rule as `pipeline.run`

Native CLI still calls `pipeline.compile` / `pipeline.run` through the
filesystem adapters. `compileBundle` is an additional entry, not a second
parser or graph.

---

## M4 — HTML through the sink

`CompileConfig.html = true` adds Oliver HTML after a successful IR
compile. Layout bytes come from the source bundle (`layout_path`, default
`layouts/main.html`). Pages are rendered sequentially (`jobs` stays 1)
through the same `renderPageSlots` / assemble splice as the CLI, then
emitted to the artifact sink.

Failed graph/content validation still emits no HTML. Incremental cache,
`--jobs`, sitemap, and search stay native-CLI. Evidence is M6.

---

## M5 — Wasm ABI around `compileBundle`

`src/embed_wasm.zig` exports a small C ABI. The product module is
`zig-out/bin/boris-embed.wasm` (ReleaseSafe) and `boris-embed-small.wasm`
(ReleaseSmall).

Zig 0.16 `std.Io` cannot compile for `wasm32-freestanding` (PATH_MAX,
posix.AT, Threaded). The product target is therefore **`wasm32-wasi`**.
The module lists `wasi_snapshot_preview1` imports because the standard
library is linked. The memory compile path must not call them. Hosts
instantiate with **trap stubs**. A stub being called is an ABI failure.

### Exports

| Export | Meaning |
|---|---|
| `boris_version` / `boris_version_len` | Compiler id, IR schema, embed profile |
| `boris_alloc` / `boris_free` | Host-owned linear-memory buffers |
| `boris_compile(req_ptr, req_len) -> handle` | `1` completed compile; `0` ABI failure |
| `boris_last_status` | `0` ok, `1` validation failed, negative ABI error |
| `boris_result_status(h)` | Same as last status for handle `1` |
| `boris_result_manifest_{ptr,len}(h)` | JSON manifest (no artifact bytes) |
| `boris_result_artifact_{count,ptr,len}(h,i)` | Artifact bytes in linear memory |
| `boris_result_free(h)` | Drop the live result |

One live result handle (`1`) at a time. Hosts must free before the next
compile.

### Request JSON

Bulk source bytes are **not** in JSON. The request names files already
copied into wasm memory with `boris_alloc`:

```json
{"html":false,"evidence":false,"layout_path":"layouts/main.html","files":[{"path":"index.md","ptr":4096,"len":80}]}
```

### Status codes

| Code | Meaning |
|---:|---|
| 0 | Compile succeeded |
| 1 | Compile finished; validation failed (diagnostics + build-report only) |
| -1 | Out of memory |
| -2 | Invalid request JSON |
| -3 | File pointer/length invalid |
| -4 | Unexpected compile error |
| -5 | Bad result handle |

Panic traps. It is not a successful empty compile.

### Measured module size (2026-08-16, Zig 0.16.0)

| Artifact | Uncompressed | gzip -9 |
|---|---:|---:|
| `boris-embed.wasm` (ReleaseSafe) | 5 448 KiB | 1 583 KiB |
| `boris-embed-small.wasm` (ReleaseSmall) | 660 KiB | 245 KiB |

Workers Free allows 3 MiB gzip. ReleaseSmall fits with room. The
automated gate requires ReleaseSmall &lt; 8 MiB and ReleaseSafe &lt; 16 MiB
uncompressed.

---

## M6 — Evidence and poisoned-corpus parity

`CompileConfig.evidence = true` (Wasm request `evidence: true`) emits the
target-local evidence chain into the same memory sink after a successful
HTML compile:

- `_boris/proof/artifacts.json`
- `_boris/proof/checks.json`
- `_boris/proof/claims.json`
- `_boris/proof/touches.json`

The inventory covers HTML pages, theme assets, and content-local assets
already in the sink. Rendered search, sitemap, RSS, llms, IR, and Proof
Pack presentation are not in this first embed inventory. The rendered-search
check is therefore `not-applicable` and the search claim is `not-verified`.
That is an honest limitation, not a verified search claim.

Evidence is **not** a `publication.target`. It describes the in-memory
artifact set for target name `default`. Failed graph or content validation
emits no evidence files and therefore no successful claims.

Checks, claims, and touches are derived from sink bytes with the same
parsers and writers as the native HTML target. They do not open a host
directory. Memory adapters must not call WASI.

### Parity

| Path | What must match |
|---|---|
| Native `compileBundle` vs Wasm `compileBundle` | Byte-identical IR, HTML, and evidence artifacts |
| Native filesystem compile vs `compileBundle` | Diagnostic `code`, `sourcePath`, `line`, `column`, `severity`, `remediation` on the seeded poisoned corpus |
| Failed validation | No `_boris/proof/*` artifacts; no verified claims |

Poisoned coverage includes missing parents, parent cycles, self-parent,
unknown frontmatter, invalid status, duplicate ids, missing includes,
missing wiki-link targets, and invalid UTF-8.

### Module metadata

`boris_version` and the result manifest name profile
`embed-ir+html+evidence`. The manifest lists:

| Field | Meaning |
|---|---|
| `features` | `markdown`, `closed-frontmatter`, `graph`, `includes`, `wiki`, `html`, `ir`, `evidence` |
| `unsupported` | `threads`, `watch`, `jobs`, `live-deploy`, `textile`, `cooklang`, `untrusted-multi-tenant`, `proof-pack`, `wasi-filesystem` |
| `limits` | `isolate_memory_mib` 128; uncompressed gate `release_small_max_mib` 8, `release_safe_max_mib` 16 |

Native CLI extras (search, sitemap, Proof Pack, live deploy adapters) stay
out of this profile. Cloudflare Worker host limits are M7.

### Measured module size after evidence (2026-08-16, Zig 0.16.0)

Linking the evidence chain grows the product module. These are snapshots,
not a new size promise.

| Artifact | Uncompressed | gzip -9 |
|---|---:|---:|
| `boris-embed.wasm` (ReleaseSafe) | 7 351.7 KiB | 2 080.5 KiB |
| `boris-embed-small.wasm` (ReleaseSmall) | 937.3 KiB | 330.8 KiB |

ReleaseSmall still fits Workers Free (3 MiB gzip). The automated gate is
unchanged: ReleaseSmall &lt; 8 MiB and ReleaseSafe &lt; 16 MiB uncompressed.

Representative native `compileBundle` of the one-page HTML+evidence fixture
in `src/embed.zig` is the max tested source bundle for this card. The Wasm
parity test uses the same fixture. Peak isolate memory is bounded by the
128 MiB Worker cap; this card does not claim a measured peak below that.

---

## M7 — Cloudflare Worker host example

[`hosts/cloudflare-worker/`](../../hosts/cloudflare-worker/) is official host
glue. It is **not** a `publication.target` and is not on the product
`zig build` graph. TypeScript/JavaScript here is the same category as
`editor/ui`: transport, limits, and persistence. It does not parse Markdown.

The host:

- instantiates `boris-embed-small.wasm` with **trap stubs** for every
  `wasi_snapshot_preview1` import
- validates and canonically orders the incoming file list (same relative-path
  rules as `identity.canonicalize`: no absolute, no `..`, no empty/`.`
  segments, duplicates after `./` folding are rejected)
- enforces source-count, per-file, total-source, output-count, and
  output-byte limits **below** current Worker caps
- uploads successful artifacts to the `ARTIFACTS` R2 binding
- returns structured HTTP: `ok`, `status`, `diagnostics`, artifact
  manifest (sizes + sha256, not payload bytes), and an evidence summary
- does not upload on validation failure; failed compiles cannot report
  successful claims

| Host limit | Value |
|---|---:|
| Source files | 128 |
| Per-file | 256 KiB |
| Total source | 2 MiB |
| Output files | 256 |
| Total output | 8 MiB |
| CPU hint | 25 s |
| Isolate memory target | 96 MiB |

Worker caps these sit under: 128 MiB isolate, 3 / 10 MiB gzip Worker,
Paid CPU 30 s default / 5 min max, 1 s startup, no Wasm threads.

Local smoke: `node hosts/cloudflare-worker/test.mjs` after `zig build`.
That does **not** require Cloudflare credentials. A live Worker/R2 invoke
is an operator step (`wrangler deploy`) and is not a default CI gate.

This card does not close [#301](https://github.com/drawmeanelephant/boris/issues/301).
Remaining: recorded live Cloudflare invocation, measured isolate peak,
RAG/context in the first embed profile.
