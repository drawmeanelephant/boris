# Embedding: freestanding compiler host seam

**Status:** normative for the M0 render spike; later cards extend this file  
**Issue:** [#301](https://github.com/drawmeanelephant/boris/issues/301)  
**Related:** [oliver-renderer.md](oliver-renderer.md)

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
