# Cloudflare Worker host example

[#301](https://github.com/drawmeanelephant/boris/issues/301) **M7**. This is
**host glue**, the same category as `editor/ui`. It is not a second Boris, not
a `publication.target`, and not on the product `zig build` graph.

The Worker owns HTTP, request validation, limits, and R2. The Wasm module owns
parse, graph, render, and evidence.

## What it does

`POST /compile` accepts a JSON source bundle, instantiates
`boris-embed-small.wasm` with **WASI trap stubs**, compiles through the
documented [embed ABI](/docs/contracts/embedding.md), and on success uploads
artifacts to the `ARTIFACTS` R2 binding.

Failed validation returns diagnostics and **does not** upload to R2. It cannot
emit successful publication claims.

Trusted authors only. Raw HTML policy is unchanged. Generated pages are not
safe to serve as application UI.

## Limits

These sit below current Worker caps (128 MiB isolate, 3 MiB gzip Free / 10 MiB
Paid, Paid CPU 30 s default / 5 min max, 1 s startup, no Wasm threads).

| Bound | Host limit |
|---|---:|
| Source files | 128 |
| Per-file bytes | 256 KiB |
| Total source bytes | 2 MiB |
| Output files | 256 |
| Total output bytes | 8 MiB |
| CPU hint | 25 s |
| Isolate memory target | 96 MiB |
| Module | ReleaseSmall (`boris-embed-small.wasm`) |

ReleaseSmall after M6 is about **937 KiB** uncompressed / **331 KiB** gzip-9.
That fits Workers Free. Use Paid only if you later switch to ReleaseSafe.

Instantiation happens **once at isolate startup** (module-scope `await`, inside
the 1 s startup budget on Free and Paid), and the instance is reused for every
request — the compile ABI is stateless per call. Per-request CPU is therefore
just the compile execution itself, which is what the Free 10 ms budget must
fit.

Rejected before compile: empty/absolute/`..` paths, backslash traversal,
duplicate canonical paths (`index.md` vs `./index.md`), over-limit counts or
sizes.

## Request

```json
{
  "html": true,
  "evidence": true,
  "layout_path": "layouts/main.html",
  "r2_prefix": "optional/prefix",
  "files": [
    { "path": "index.md", "bytes": "<base64>" },
    { "path": "layouts/main.html", "bytes": "<base64>" }
  ]
}
```

`GET /health` returns the same limits without compiling.

## Response

HTTP 200 on a successful compile, 422 on validation-failed compile, 400 on
host rejection, 500 on ABI/host failure.

The JSON body carries `ok`, `status`, `diagnostics`, an artifact **manifest**
(path, media type, byte count, sha256, optional `r2_key`), an `evidence`
summary, and `r2` keys when upload ran. Artifact **bytes** stay out of the
HTTP body so the response is not a second copy of the package.

## Local smoke (no Cloudflare credentials)

```bash
zig build
node hosts/cloudflare-worker/test.mjs
```

That instantiates the same module, compiles the valid fixture (uploads to an
in-memory R2 stand-in), and compiles the poisoned parent fixture (diagnostics,
no R2, no claims). Default CI does not have a Cloudflare account; this is the
recorded local smoke.

## Deploy

1. `zig build`
2. `sh hosts/cloudflare-worker/copy-wasm.sh`
3. Create an R2 bucket named `boris-embed-artifacts` (or change
   `wrangler.toml`).
4. `npx wrangler@4 deploy` from `hosts/cloudflare-worker/`

Wrangler is optional operator tooling. It is not a product build dependency.

Do **not** enable Cloudflare's experimental WASI filesystem. The module lists
`wasi_snapshot_preview1` imports because Zig 0.16 `std.Io` cannot target
`wasm32-freestanding`; the host must trap them. A stub call is an ABI failure.

## Measured costs

| Item | Recorded |
|---|---|
| Module (ReleaseSmall) | 937.3 KiB / 330.8 KiB gzip-9 (M6 snapshot) |
| Local valid smoke | `test.mjs` printed 15 ms on 2026-08-16 (developer machine; not a gate) |
| Live warm CPU (9-artifact compile + R2 upload) | 4 ms — under the Free 10 ms budget (measured 2026-08-16, ORD/IAD) |
| Live compile-only CPU | 1 ms |
| Live cold CPU (incl. module instantiation) | 39 ms — charged to the 1 s isolate **startup** budget, not per-request |
| Live Worker wall (parallel R2 uploads) | ~1.2–1.4 s (account-level R2 write latency; see note below) |
| Max tested source bundle | the two-file fixtures in `fixtures/` |

The upload wall is dominated by **account-level R2 write latency**: ~0.6–1.1 s
per put (13 B–8 KB objects), measured identically from the Worker binding and
the direct admin API, and unchanged after recreating the bucket with an
`enam` location hint. It is not worker code and not bucket routing. The
evidence is assembled as a ready-to-paste [Cloudflare support
ticket](cloudflare-support-ticket.md).

## Non-goals

- `"cloudflare"` in `publication.target`
- Untrusted multi-tenant authoring
- GitHub webhook / container runner ([#300](https://github.com/drawmeanelephant/boris/issues/300))
- Browser playground or editor-in-Wasm
